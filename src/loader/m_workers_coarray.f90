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
!   Worker backend 1 of 2: coarray images (make BACKEND=coarray, run with cafrun).
!   Image 1 runs the GUI; images 2..N decode previews.
!
!   Protocol (one job per worker at a time):
!
!     GUI  : request[w] = job            ; event post(request_event[w])
!     W    : event wait(request_event)   ; decode ...
!     W    : result = ...; transfer_buf = pixels
!            atomic_define(done_job, id) ; event post(completion_event[1])
!     GUI  : event_query/wait(completion_event) -> find w with done_job[w] == id
!            copy result metadata, then pixels in chunks over several frames
!     GUI  : workers_release(w)  -> w may receive the next job
!
!   * The GUI keeps the idle/busy bookkeeping locally, so it never has to poll
!     remote state just to find an idle worker.
!   * Events give the segment ordering: everything a worker wrote before its
!     post is visible once the GUI has consumed that post. The GUI therefore
!     accepts at most as many results as completion events it has consumed.
!   * done_job / cancel_job / stop_flag are atomics because they are read
!     while the other side may be writing them.
!   * A worker checks cancel_job between decode stages and gives up early when
!     the GUI no longer needs the photo (fast scrolling).
!
!   The public interface is identical to m_workers_threads.f90.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_workers

    use, intrinsic :: iso_c_binding, only: c_char
    use, intrinsic :: iso_fortran_env, only: event_type, atomic_int_kind
    use :: m_jobs
    use :: m_platform, only: sleep_ms
    use :: m_strings, only: str
    use :: m_log, only: log_message, log_failure, log_set_tag

    implicit none (type, external)

    private

    ! ---- coarrays ------------------------------------------------------------------------------
    type(job_request_t), save :: request[*]
    type(job_result_t),  save :: result[*]
    integer(atomic_int_kind), save :: done_job[*]
    integer(atomic_int_kind), save :: cancel_job[*]
    integer(atomic_int_kind), save :: stop_flag[*]
    type(event_type), save :: request_event[*]
    type(event_type), save :: completion_event[*]
    character(kind=c_char), allocatable, save :: transfer_buf(:)[:]

    ! ---- GUI-side bookkeeping (image 1 only) ---------------------------------------------------
    integer, allocatable, save :: assigned_job(:)   !< job id per worker, 0 = idle
    logical, allocatable, save :: collected(:)      !< result metadata already taken
    integer, save :: event_credit = 0               !< completion events consumed, not yet matched

    public :: workers_run, workers_is_primary, worker_count
    public :: workers_submit, workers_cancel, workers_collect, workers_copy_chunk, workers_release

contains

    !> Run the program: `gui` on image 1, the decode loop on every other image.
    subroutine workers_run(gui)
        procedure(gui_entry) :: gui
        call workers_init()
        if (this_image() == 1) then
            call log_set_tag('[gui]')
            call gui()
            call workers_shutdown()
        else
            call log_set_tag('[worker '//str(this_image())//']')
            call worker_main_loop()
        end if
        call workers_finalize()
    end subroutine workers_run

    !> Only image 1 prints usage and sets the exit status.
    logical function workers_is_primary()
        workers_is_primary = this_image() == 1
    end function workers_is_primary

    integer function worker_count()
        worker_count = num_images() - 1
    end function worker_count

    !> GUI: hand a job to an idle worker. Returns the worker image, or 0 if all are busy.
    integer function workers_submit(path, job_id, max_side) result(worker)
        character(len=*), intent(in) :: path
        integer, intent(in) :: job_id, max_side
        type(job_request_t) :: job
        integer :: w

        worker = 0
        if (num_images() < 2) return
        do w = 2, num_images()
            if (assigned_job(w) /= 0) cycle
            job%path = path
            job%job_id = job_id
            job%max_side = max_side
            request[w] = job
            assigned_job(w) = job_id
            collected(w) = .false.
            event post(request_event[w])
            worker = w
            call log_message('job '//str(job_id)//' -> worker '//str(w)//': '//trim(path))
            return
        end do
    end function workers_submit

    !> GUI: ask a worker to abandon a job it is still decoding.
    subroutine workers_cancel(worker, job_id)
        integer, intent(in) :: worker, job_id
        if (worker < 2 .or. worker > num_images()) return
        if (assigned_job(worker) /= job_id .or. collected(worker)) return
        call atomic_define(cancel_job[worker], int(job_id, atomic_int_kind))
    end subroutine workers_cancel

    !> GUI: non-blocking. Returns .true. and one finished job if available.
    logical function workers_collect(worker, res) result(found)
        integer, intent(out) :: worker
        type(job_result_t), intent(out) :: res
        integer :: pending, w
        integer(atomic_int_kind) :: done

        found = .false.
        worker = 0
        if (num_images() < 2) return

        call event_query(completion_event, pending)
        if (pending > 0) then
            ! Never blocks: these posts have already arrived.
            event wait (completion_event, until_count=pending)
            event_credit = event_credit + pending
        end if
        if (event_credit <= 0) return

        do w = 2, num_images()
            if (assigned_job(w) == 0 .or. collected(w)) cycle
            call atomic_ref(done, done_job[w])
            if (done /= assigned_job(w)) cycle
            res = result[w]
            collected(w) = .true.
            event_credit = event_credit - 1
            worker = w
            found = .true.
            return
        end do
    end function workers_collect

    !> GUI: copy bytes(first:first+size-1) of a worker's finished preview.
    subroutine workers_copy_chunk(worker, first, bytes)
        integer, intent(in) :: worker, first
        character(kind=c_char), intent(out) :: bytes(:)
        bytes = transfer_buf(first:first + size(bytes) - 1)[worker]
    end subroutine workers_copy_chunk

    !> GUI: the worker's result is no longer needed; it may take a new job.
    subroutine workers_release(worker)
        integer, intent(in) :: worker
        if (.not. allocated(assigned_job)) return
        if (worker < 2 .or. worker > num_images()) return
        assigned_job(worker) = 0
        collected(worker) = .false.
    end subroutine workers_release

    ! ============================================================================================

    !> Collective: every image calls this once at start-up.
    subroutine workers_init()
        integer :: stat
        allocate(transfer_buf(MAX_PIXEL_BYTES)[*], stat=stat)
        if (stat /= 0) then
            call log_failure('cannot allocate the coarray transfer buffer (stat='//str(stat)//')')
            error stop 1
        end if
        call atomic_define(done_job, 0)
        call atomic_define(cancel_job, 0)
        call atomic_define(stop_flag, 0)
        if (this_image() == 1) then
            allocate(assigned_job(num_images()), collected(num_images()))
            assigned_job = 0
            collected = .false.
            event_credit = 0
        end if
        sync all
        if (this_image() == 1) call log_message('coarray backend: '//str(num_images())// &
            ' images, '//str(max(0, num_images() - 1))//' decode worker(s)')
    end subroutine workers_init

    !> Collective: every image calls this once before exiting.
    subroutine workers_finalize()
        integer :: stat
        sync all
        if (allocated(transfer_buf)) deallocate(transfer_buf, stat=stat)
    end subroutine workers_finalize

    !> GUI: tell every worker to exit after its current job.
    subroutine workers_shutdown()
        integer :: w
        do w = 2, num_images()
            call atomic_define(stop_flag[w], 1)
            event post(request_event[w])
        end do
    end subroutine workers_shutdown

    subroutine worker_main_loop()
        type(job_request_t) :: job
        type(job_result_t) :: res
        character(kind=c_char), allocatable :: pixels(:)
        integer(atomic_int_kind) :: stop_now

        call log_message('online')
        do
            call wait_for_request()
            call atomic_ref(stop_now, stop_flag)
            if (stop_now /= 0) exit

            job = request
            call process_job(this_image(), job, res, pixels, coarray_cancelled)
            if (res%code == JOB_OK) transfer_buf(1:res%nbytes) = pixels
            if (allocated(pixels)) deallocate(pixels)

            ! Publish the result, then notify the GUI image.
            result = res
            call atomic_define(done_job, int(job%job_id, atomic_int_kind))
            event post(completion_event[1])
        end do
        call log_message('stopped')
    end subroutine worker_main_loop

    !> Sleep-poll instead of a bare EVENT WAIT: some coarray runtimes spin a full
    !> CPU core inside EVENT WAIT, which would starve the GUI on small machines.
    subroutine wait_for_request()
        integer :: pending
        do
            call event_query(request_event, pending)
            if (pending > 0) exit
            call sleep_ms(1)
        end do
        event wait (request_event)
    end subroutine wait_for_request

    logical function coarray_cancelled(worker, job_id) result(flag)
        integer, intent(in) :: worker, job_id
        integer(atomic_int_kind) :: value
        call atomic_ref(value, cancel_job[worker])     ! worker == this_image()
        flag = value == job_id
    end function coarray_cancelled

end module m_workers
