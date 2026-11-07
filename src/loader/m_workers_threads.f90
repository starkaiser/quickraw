! BSD 3-Clause License
!
! Copyright (c) 2026, Sorin Cătălin Păștiță
!
! Redistribution and use in source and binary forms, with or without
! modification, are permitted provided that the following conditions are met:
!
! 1. Redistributions of source code must retain the above copyright notice, this
!    list of conditions and the following disclaimer.
!
! 2. Redistributions in binary form must reproduce the above copyright notice,
!    this list of conditions and the following disclaimer in the documentation
!    and/or other materials provided with the distribution.
!
! 3. Neither the name of the copyright holder nor the names of its
!    contributors may be used to endorse or promote products derived from
!    this software without specific prior written permission.
!
! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


! ==================================================================================================
!
! This file is part of QuickRAW - a small and fast program to view Canon RAW photos
!
! PURPOSE :
!   Worker backend 2 of 2: OpenMP threads in one process (make BACKEND=threads,
!   the default and what the release builds use). Thread 0 - the program's
!   main thread, which macOS requires for the window - runs the GUI; threads
!   1..N decode previews.
!
!   Same protocol as the coarray backend, with shared memory instead of
!   remote access: each worker owns one mailbox in `box`. Every field that
!   both sides touch is read and written inside the named critical section
!   (qr_mailbox), which also flushes memory. A worker's pixel buffer is only
!   read by the GUI between "done" and the next request, so it is copied
!   without holding the lock.
!
!   Worker count: $QUICKRAW_WORKERS, else (CPU cores - 1) clamped to 1..4.
!   The public interface is identical to m_workers_coarray.f90.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, November 2026
!
! ==================================================================================================

module m_workers

    use, intrinsic :: iso_c_binding, only: c_char
    use :: omp_lib, only: omp_get_thread_num, omp_get_num_threads, omp_get_num_procs, omp_set_dynamic
    use :: m_jobs
    use :: m_platform, only: sleep_ms
    use :: m_strings, only: str
    use :: m_log, only: log_message, log_set_tag

    implicit none (type, external)

    private

    integer, parameter :: MAX_WORKERS = 16

    type :: mailbox_t
        type(job_request_t) :: request
        type(job_result_t)  :: result
        character(kind=c_char), allocatable :: pixels(:)
        logical :: has_request = .false.
        integer :: done_job    = 0
        integer :: cancel_job  = 0
    end type mailbox_t

    type(mailbox_t), allocatable, save :: box(:)
    logical, save :: stop_all = .false.
    integer, save :: n_workers = 0

    ! ---- GUI-side bookkeeping (thread 0 only) --------------------------------------------------
    integer, allocatable, save :: assigned_job(:)
    logical, allocatable, save :: collected(:)

    public :: workers_run, workers_is_primary, worker_count
    public :: workers_submit, workers_cancel, workers_collect, workers_copy_chunk, workers_release

contains

    !> Run the program: `gui` on the main thread, the decode loop on the others.
    subroutine workers_run(gui)
        procedure(gui_entry) :: gui
        integer :: wanted

        wanted = requested_workers()
        allocate(box(wanted), assigned_job(wanted), collected(wanted))
        assigned_job = 0
        collected = .false.
        stop_all = .false.
        n_workers = wanted

        call omp_set_dynamic(.false.)
        !$omp parallel num_threads(wanted + 1) default(shared)
        if (omp_get_thread_num() == 0) then
            ! The runtime may grant fewer threads than asked for.
            n_workers = min(wanted, omp_get_num_threads() - 1)
            call log_set_tag('[gui]')
            call log_message('thread backend: '//str(n_workers)//' decode worker(s)')
            call gui()
            !$omp critical (qr_mailbox)
            stop_all = .true.
            !$omp end critical (qr_mailbox)
        else
            call log_set_tag('[worker '//str(omp_get_thread_num())//']')
            call worker_main_loop(omp_get_thread_num())
        end if
        !$omp end parallel

        deallocate(box, assigned_job, collected)
    end subroutine workers_run

    logical function workers_is_primary()
        workers_is_primary = .true.
    end function workers_is_primary

    integer function worker_count()
        worker_count = n_workers
    end function worker_count

    integer function workers_submit(path, job_id, max_side) result(worker)
        character(len=*), intent(in) :: path
        integer, intent(in) :: job_id, max_side
        integer :: w

        worker = 0
        do w = 1, n_workers
            if (assigned_job(w) /= 0) cycle
            !$omp critical (qr_mailbox)
            box(w)%request%path = path
            box(w)%request%job_id = job_id
            box(w)%request%max_side = max_side
            box(w)%has_request = .true.
            !$omp end critical (qr_mailbox)
            assigned_job(w) = job_id
            collected(w) = .false.
            worker = w
            call log_message('job '//str(job_id)//' -> worker '//str(w)//': '//trim(path))
            return
        end do
    end function workers_submit

    subroutine workers_cancel(worker, job_id)
        integer, intent(in) :: worker, job_id
        if (worker < 1 .or. worker > n_workers) return
        if (assigned_job(worker) /= job_id .or. collected(worker)) return
        !$omp critical (qr_mailbox)
        box(worker)%cancel_job = job_id
        !$omp end critical (qr_mailbox)
    end subroutine workers_cancel

    logical function workers_collect(worker, res) result(found)
        integer, intent(out) :: worker
        type(job_result_t), intent(out) :: res
        integer :: w

        found = .false.
        worker = 0
        do w = 1, n_workers
            if (assigned_job(w) == 0 .or. collected(w)) cycle
            !$omp critical (qr_mailbox)
            if (box(w)%done_job == assigned_job(w)) then
                res = box(w)%result
                found = .true.
            end if
            !$omp end critical (qr_mailbox)
            if (found) then
                collected(w) = .true.
                worker = w
                return
            end if
        end do
    end function workers_collect

    subroutine workers_copy_chunk(worker, first, bytes)
        integer, intent(in) :: worker, first
        character(kind=c_char), intent(out) :: bytes(:)
        bytes = box(worker)%pixels(first:first + size(bytes) - 1)
    end subroutine workers_copy_chunk

    subroutine workers_release(worker)
        integer, intent(in) :: worker
        if (.not. allocated(assigned_job)) return
        if (worker < 1 .or. worker > n_workers) return
        assigned_job(worker) = 0
        collected(worker) = .false.
    end subroutine workers_release

    ! ============================================================================================

    subroutine worker_main_loop(w)
        integer, intent(in) :: w
        type(job_request_t) :: job
        type(job_result_t) :: res
        character(kind=c_char), allocatable :: pixels(:)
        logical :: got, stop_now

        call log_message('online')
        do
            do
                !$omp critical (qr_mailbox)
                stop_now = stop_all
                got = box(w)%has_request
                if (got) then
                    job = box(w)%request
                    box(w)%has_request = .false.
                end if
                !$omp end critical (qr_mailbox)
                if (stop_now .or. got) exit
                call sleep_ms(1)
            end do
            if (stop_now) exit

            call process_job(w, job, res, pixels, thread_cancelled)

            !$omp critical (qr_mailbox)
            box(w)%result = res
            if (allocated(box(w)%pixels)) deallocate(box(w)%pixels)
            if (allocated(pixels)) call move_alloc(pixels, box(w)%pixels)
            box(w)%done_job = job%job_id
            !$omp end critical (qr_mailbox)
        end do
        call log_message('stopped')
    end subroutine worker_main_loop

    logical function thread_cancelled(worker, job_id) result(flag)
        integer, intent(in) :: worker, job_id
        !$omp critical (qr_mailbox)
        flag = box(worker)%cancel_job == job_id
        !$omp end critical (qr_mailbox)
    end function thread_cancelled

    integer function requested_workers() result(n)
        character(len=32) :: text
        integer :: status, value, ios
        n = max(1, min(4, omp_get_num_procs() - 1))
        call get_environment_variable('QUICKRAW_WORKERS', text, status=status)
        if (status == 0) then
            read(text, *, iostat=ios) value
            if (ios == 0 .and. value >= 1) n = min(value, MAX_WORKERS)
        end if
    end function requested_workers

end module m_workers
