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
!   Five-photo look-ahead cache (GUI image only): previous-2, previous-1,
!   current, next+1, next+2.
!
!   Slots are keyed by path and never shuffled: stepping right turns
!   [n-2 .. n+2] into [n-1 .. n+3], so four slots stay as they are and only
!   the slot of n-2 is recycled for n+3. Each slot moves through
!
!     QUEUED -> DECODING (on a worker) -> RECEIVING (pixels copied in chunks)
!            -> UPLOAD (CPU pixels complete) -> READY (GPU texture)
!
!   Work is always done in priority order: current, +1, -1, +2, -2.
!   Pixel copies run under a per-frame time budget and texture uploads are
!   limited to one neighbour per frame, so the event loop never stalls.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_cache

    use, intrinsic :: iso_c_binding, only: c_char, c_int, c_loc
    use, intrinsic :: iso_fortran_env, only: int64, real64
    use :: raylib, only: texture2d_type, image_type, load_texture_from_image, unload_texture, &
                         gen_texture_mipmaps, set_texture_filter, TEXTURE_FILTER_TRILINEAR, &
                         PIXELFORMAT_UNCOMPRESSED_R8G8B8
    use :: m_jobs, only: job_result_t, JOB_OK, MAX_PIXEL_BYTES, MAX_PREVIEW_SIDE, MIN_PREVIEW_SIDE
    use :: m_workers, only: workers_submit, workers_cancel, workers_collect, &
                            workers_copy_chunk, workers_release, worker_count
    use :: m_preview, only: photo_info_t
    use :: m_photo_list, only: photo_list_t
    use :: m_strings, only: str
    use :: m_log, only: log_message, log_failure

    implicit none (type, external)

    private

    integer, parameter, public :: CACHE_SIZE = 5
    integer, parameter, public :: WINDOW_OFFSETS(CACHE_SIZE)   = [-2, -1, 0, 1, 2]
    integer, parameter         :: PRIORITY_OFFSETS(CACHE_SIZE) = [0, 1, -1, 2, -2]

    integer, parameter, public :: SLOT_EMPTY     = 0
    integer, parameter, public :: SLOT_QUEUED    = 1
    integer, parameter, public :: SLOT_DECODING  = 2
    integer, parameter, public :: SLOT_RECEIVING = 3
    integer, parameter, public :: SLOT_UPLOAD    = 4
    integer, parameter, public :: SLOT_READY     = 5
    integer, parameter, public :: SLOT_FAILED    = 6

    integer, parameter :: CHUNK_BYTES = 1024 * 1024

    type, public :: cache_slot_t
        character(len=:), allocatable :: path
        integer :: state     = SLOT_EMPTY
        integer :: job_id    = 0
        integer :: worker    = 0
        integer :: fail_code = 0
        integer :: width = 0, height = 0
        integer :: nbytes = 0, received = 0
        real    :: decode_ms = 0.0
        character(kind=c_char), allocatable :: pixels(:)
        type(texture2d_type) :: texture
        type(photo_info_t)   :: info
    end type cache_slot_t

    type, public :: image_cache_t
        type(cache_slot_t) :: slots(CACHE_SIZE)
        integer :: next_job = 0
        integer :: max_side = 2048
        real    :: transfer_budget_ms = 6.0
    contains
        procedure :: set_preview_side => cache_set_preview_side
        procedure :: update           => cache_update
        procedure :: upload_current   => cache_upload_current
        procedure :: upload_neighbour => cache_upload_neighbour
        procedure :: find             => cache_find
        procedure :: state_of         => cache_state_of
        procedure :: is_settled       => cache_is_settled
        procedure :: forget           => cache_forget
        procedure :: clear            => cache_clear
    end type image_cache_t

contains

    !> Previews are decoded so their long side matches the screen (clamped).
    subroutine cache_set_preview_side(self, screen_long_side)
        class(image_cache_t), intent(inout) :: self
        integer, intent(in) :: screen_long_side
        self%max_side = max(MIN_PREVIEW_SIDE, min(MAX_PREVIEW_SIDE, screen_long_side))
    end subroutine cache_set_preview_side

    !> Once per frame: collect finished jobs, slide the window, start new jobs,
    !> copy pixels within the time budget.
    subroutine cache_update(self, list)
        class(image_cache_t), intent(inout) :: self
        type(photo_list_t), intent(in) :: list
        call collect_results(self)
        call slide_window(self, list)
        call dispatch_jobs(self, list)
        call transfer_pixels(self, list)
    end subroutine cache_update

    !> Upload the current photo's texture if its pixels are complete.
    !> Called before drawing so a freshly decoded photo shows this frame.
    subroutine cache_upload_current(self, list)
        class(image_cache_t), intent(inout) :: self
        type(photo_list_t), intent(in) :: list
        integer :: s
        if (list%is_empty()) return
        s = self%find(list%current_path())
        if (s > 0) then
            if (self%slots(s)%state == SLOT_UPLOAD) call make_texture(self%slots(s))
        end if
    end subroutine cache_upload_current

    !> Upload at most one neighbour texture (called after the frame is presented).
    subroutine cache_upload_neighbour(self, list)
        class(image_cache_t), intent(inout) :: self
        type(photo_list_t), intent(in) :: list
        integer :: k, s
        if (list%is_empty()) return
        do k = 2, CACHE_SIZE
            s = self%find(list%offset_path(PRIORITY_OFFSETS(k)))
            if (s == 0) cycle
            if (self%slots(s)%state == SLOT_UPLOAD) then
                call make_texture(self%slots(s))
                return
            end if
        end do
    end subroutine cache_upload_neighbour

    integer function cache_find(self, path) result(found)
        class(image_cache_t), intent(in) :: self
        character(len=*), intent(in) :: path
        integer :: s
        found = 0
        if (len(path) == 0) return
        do s = 1, CACHE_SIZE
            if (self%slots(s)%state == SLOT_EMPTY) cycle
            if (self%slots(s)%path == path) then
                found = s
                return
            end if
        end do
    end function cache_find

    integer function cache_state_of(self, path) result(state)
        class(image_cache_t), intent(in) :: self
        character(len=*), intent(in) :: path
        integer :: s
        state = SLOT_EMPTY
        s = self%find(path)
        if (s > 0) state = self%slots(s)%state
    end function cache_state_of

    !> True when every photo of the window is either displayed-ready or failed,
    !> i.e. nothing will change until the user does something.
    logical function cache_is_settled(self, list) result(settled)
        class(image_cache_t), intent(in) :: self
        type(photo_list_t), intent(in) :: list
        integer :: k, state
        settled = .true.
        if (list%is_empty() .or. worker_count() < 1) return
        do k = 1, CACHE_SIZE
            state = self%state_of(list%offset_path(WINDOW_OFFSETS(k)))
            if (state /= SLOT_READY .and. state /= SLOT_FAILED) then
                settled = .false.
                return
            end if
        end do
    end function cache_is_settled

    !> Drop a photo from the cache (e.g. after it was moved to another folder).
    subroutine cache_forget(self, path)
        class(image_cache_t), intent(inout) :: self
        character(len=*), intent(in) :: path
        integer :: s
        s = self%find(path)
        if (s > 0) call evict(self%slots(s))
    end subroutine cache_forget

    !> Release every slot. Workers must still be running (outstanding jobs are cancelled).
    subroutine cache_clear(self)
        class(image_cache_t), intent(inout) :: self
        integer :: s
        do s = 1, CACHE_SIZE
            call evict(self%slots(s))
        end do
    end subroutine cache_clear

    ! ----------------------------------------------------------------------------------------------

    subroutine collect_results(self)
        type(image_cache_t), intent(inout) :: self
        type(job_result_t) :: res
        integer :: worker, s, stat

        do while (workers_collect(worker, res))
            s = slot_of_job(self, res%job_id)
            if (s == 0) then
                ! Photo already left the window (or was moved): discard.
                call workers_release(worker)
                cycle
            end if
            associate (slot => self%slots(s))
                slot%info = res%info
                slot%decode_ms = res%elapsed_ms
                if (res%code == JOB_OK .and. res%nbytes > 0 .and. res%nbytes <= MAX_PIXEL_BYTES) then
                    allocate(slot%pixels(res%nbytes), stat=stat)
                    if (stat == 0) then
                        slot%width = res%width
                        slot%height = res%height
                        slot%nbytes = res%nbytes
                        slot%received = 0
                        slot%worker = worker
                        slot%state = SLOT_RECEIVING
                        cycle
                    end if
                    call log_failure('out of memory for '//slot%path)
                end if
                slot%state = SLOT_FAILED
                slot%fail_code = res%code
                slot%worker = 0
                call workers_release(worker)
                call log_failure('could not decode preview ('//str(res%code)//'): '//slot%path)
            end associate
        end do
    end subroutine collect_results

    subroutine slide_window(self, list)
        type(image_cache_t), intent(inout) :: self
        type(photo_list_t), intent(in) :: list
        type :: path_holder_t
            character(len=:), allocatable :: p
        end type path_holder_t
        type(path_holder_t) :: wanted(CACHE_SIZE)
        integer :: k, s
        logical :: keep

        do k = 1, CACHE_SIZE
            wanted(k)%p = list%offset_path(WINDOW_OFFSETS(k))
        end do

        do s = 1, CACHE_SIZE
            if (self%slots(s)%state == SLOT_EMPTY) cycle
            keep = .false.
            do k = 1, CACHE_SIZE
                if (self%slots(s)%path == wanted(k)%p) keep = .true.
            end do
            if (.not. keep) call evict(self%slots(s))
        end do

        do k = 1, CACHE_SIZE
            if (len(wanted(k)%p) == 0) cycle
            if (self%find(wanted(k)%p) /= 0) cycle   ! cached, or a duplicate in tiny folders
            s = empty_slot(self)
            if (s == 0) exit
            self%next_job = self%next_job + 1
            self%slots(s)%path = wanted(k)%p
            self%slots(s)%state = SLOT_QUEUED
            self%slots(s)%job_id = self%next_job
            self%slots(s)%worker = 0
            self%slots(s)%fail_code = 0
            self%slots(s)%info = photo_info_t()
        end do
    end subroutine slide_window

    subroutine dispatch_jobs(self, list)
        type(image_cache_t), intent(inout) :: self
        type(photo_list_t), intent(in) :: list
        integer :: k, s, worker
        if (worker_count() < 1 .or. list%is_empty()) return
        do k = 1, CACHE_SIZE
            s = self%find(list%offset_path(PRIORITY_OFFSETS(k)))
            if (s == 0) cycle
            if (self%slots(s)%state /= SLOT_QUEUED) cycle
            worker = workers_submit(self%slots(s)%path, self%slots(s)%job_id, self%max_side)
            if (worker == 0) return            ! all workers busy; try next frame
            self%slots(s)%worker = worker
            self%slots(s)%state = SLOT_DECODING
        end do
    end subroutine dispatch_jobs

    subroutine transfer_pixels(self, list)
        type(image_cache_t), intent(inout) :: self
        type(photo_list_t), intent(in) :: list
        integer :: k, s, first, n
        integer(int64) :: t0, t, rate
        real(real64) :: budget_ticks

        if (list%is_empty()) return
        call system_clock(t0, rate)
        budget_ticks = real(self%transfer_budget_ms, real64) * real(rate, real64) / 1000.0_real64

        do k = 1, CACHE_SIZE
            s = self%find(list%offset_path(PRIORITY_OFFSETS(k)))
            if (s == 0) cycle
            associate (slot => self%slots(s))
                do while (slot%state == SLOT_RECEIVING)
                    first = slot%received + 1
                    n = min(CHUNK_BYTES, slot%nbytes - slot%received)
                    call workers_copy_chunk(slot%worker, first, slot%pixels(first:first + n - 1))
                    slot%received = slot%received + n
                    if (slot%received >= slot%nbytes) then
                        call workers_release(slot%worker)
                        slot%worker = 0
                        slot%state = SLOT_UPLOAD
                    end if
                    call system_clock(t)
                    if (real(t - t0, real64) > budget_ticks) return
                end do
            end associate
        end do
    end subroutine transfer_pixels

    subroutine make_texture(slot)
        type(cache_slot_t), intent(inout), target :: slot
        type(image_type) :: view
        type(texture2d_type) :: texture

        ! Borrowed view of Fortran-owned pixels: never UnloadImage() it.
        view%data = c_loc(slot%pixels(1))
        view%width = int(slot%width, c_int)
        view%height = int(slot%height, c_int)
        view%mipmaps = 1_c_int
        view%format = PIXELFORMAT_UNCOMPRESSED_R8G8B8
        texture = load_texture_from_image(view)
        deallocate(slot%pixels)

        if (texture%id == 0) then
            slot%state = SLOT_FAILED
            call log_failure('texture upload failed: '//slot%path)
            return
        end if
        ! Mipmaps + trilinear filtering keep the downscaled view free of aliasing.
        call gen_texture_mipmaps(texture)
        call set_texture_filter(texture, TEXTURE_FILTER_TRILINEAR)
        slot%texture = texture
        slot%state = SLOT_READY
        call log_message('ready: '//slot%path//' ('//str(slot%width)//'x'//str(slot%height)//')')
    end subroutine make_texture

    subroutine evict(slot)
        type(cache_slot_t), intent(inout) :: slot
        select case (slot%state)
        case (SLOT_DECODING)
            call workers_cancel(slot%worker, slot%job_id)   ! result is discarded on arrival
        case (SLOT_RECEIVING)
            call workers_release(slot%worker)
        end select
        if (slot%texture%id /= 0) call unload_texture(slot%texture)
        slot%texture = texture2d_type()
        if (allocated(slot%pixels)) deallocate(slot%pixels)
        slot%state = SLOT_EMPTY
        slot%job_id = 0
        slot%worker = 0
        slot%nbytes = 0
        slot%received = 0
        slot%path = ''
    end subroutine evict

    integer function slot_of_job(self, job_id) result(found)
        type(image_cache_t), intent(in) :: self
        integer, intent(in) :: job_id
        integer :: s
        found = 0
        do s = 1, CACHE_SIZE
            if (self%slots(s)%state == SLOT_DECODING .and. self%slots(s)%job_id == job_id) then
                found = s
                return
            end if
        end do
    end function slot_of_job

    integer function empty_slot(self) result(found)
        type(image_cache_t), intent(in) :: self
        integer :: s
        found = 0
        do s = 1, CACHE_SIZE
            if (self%slots(s)%state == SLOT_EMPTY) then
                found = s
                return
            end if
        end do
    end function empty_slot

end module m_cache
