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
!   What a decode job is, independent of how it is executed. Both worker
!   backends (coarray images in m_workers_coarray.f90, OpenMP threads in
!   m_workers_threads.f90) run process_job() and exchange these types.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, November 2026
!
! ==================================================================================================

module m_jobs

    use, intrinsic :: iso_c_binding, only: c_char
    use, intrinsic :: iso_fortran_env, only: int64, real64
    use :: m_preview, only: photo_info_t, read_embedded_jpeg, decode_preview, compute_histogram
    use :: m_strings, only: str, PATH_LENGTH
    use :: m_log, only: log_message

    implicit none (type, external)

    private

    integer, parameter, public :: JOB_OK        = 0
    integer, parameter, public :: JOB_NO_JPEG   = 1   !< LibRaw could not open / find a preview
    integer, parameter, public :: JOB_DECODE    = 2   !< JPEG decode failed
    integer, parameter, public :: JOB_TOO_LARGE = 3
    integer, parameter, public :: JOB_CANCELLED = 4

    !> Longest preview side the workers may produce; the GUI picks the value
    !> per job from the monitor size (see m_cache).
    integer, parameter, public :: MAX_PREVIEW_SIDE = 3072
    integer, parameter, public :: MIN_PREVIEW_SIDE = 1024
    integer, parameter, public :: MAX_PIXEL_BYTES  = MAX_PREVIEW_SIDE * MAX_PREVIEW_SIDE * 3

    !> Plain data only (no allocatables) so both types can live in coarrays.
    type, public :: job_request_t
        character(len=PATH_LENGTH) :: path = ''
        integer :: job_id   = 0
        integer :: max_side = 0
    end type job_request_t

    type, public :: job_result_t
        integer :: job_id = 0
        integer :: code   = JOB_NO_JPEG
        integer :: width  = 0
        integer :: height = 0
        integer :: nbytes = 0
        real    :: elapsed_ms = 0.0
        type(photo_info_t) :: info
    end type job_result_t

    abstract interface
        !> Backend hook: has the GUI cancelled this job meanwhile?
        logical function cancel_query(worker, job_id)
            integer, intent(in) :: worker, job_id
        end function cancel_query

        !> The GUI entry point a backend runs on its main thread / image 1.
        subroutine gui_entry()
        end subroutine gui_entry
    end interface

    public :: cancel_query, gui_entry, process_job

contains

    !> Decode one photo. Stops early (JOB_CANCELLED) between stages if asked.
    subroutine process_job(worker, job, res, pixels, cancelled)
        integer, intent(in) :: worker
        type(job_request_t), intent(in) :: job
        type(job_result_t), intent(out) :: res
        character(kind=c_char), allocatable, intent(out) :: pixels(:)
        procedure(cancel_query) :: cancelled
        character(kind=c_char), allocatable :: jpeg(:)
        integer(int64) :: t0, t1, rate
        logical :: ok

        call system_clock(t0, rate)
        res = job_result_t()
        res%job_id = job%job_id

        call read_embedded_jpeg(trim(job%path), jpeg, res%info)
        if (.not. allocated(jpeg)) then
            res%code = JOB_NO_JPEG
        else if (cancelled(worker, job%job_id)) then
            res%code = JOB_CANCELLED
        else
            call decode_preview(jpeg, job%max_side, pixels, res%width, res%height, ok)
            if (.not. ok) then
                res%code = JOB_DECODE
            else if (size(pixels) > MAX_PIXEL_BYTES) then
                res%code = JOB_TOO_LARGE
            else if (cancelled(worker, job%job_id)) then
                res%code = JOB_CANCELLED
            else
                call compute_histogram(pixels, res%info)
                res%code = JOB_OK
                res%nbytes = size(pixels)
            end if
        end if
        if (res%code /= JOB_OK) then
            res%width = 0
            res%height = 0
            if (allocated(pixels)) deallocate(pixels)
        end if

        call system_clock(t1)
        res%elapsed_ms = real(real(t1 - t0, real64) * 1000.0_real64 / real(max(rate, 1_int64), real64))
        call log_message('job '//str(job%job_id)//' done in '//str(nint(res%elapsed_ms))// &
            ' ms (code '//str(res%code)//', '//str(res%width)//'x'//str(res%height)//'): '// &
            trim(job%path))
    end subroutine process_job

end module m_jobs
