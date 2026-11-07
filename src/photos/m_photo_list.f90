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
!   The list of RAW photos in one folder and the current position in it.
!   Navigation wraps around at both ends. Removing / re-inserting entries is
!   used by the sorting actions (move to lights/darks/... and undo).
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_photo_list

    use :: m_platform, only: is_directory, dir_handle_t, dir_open, dir_next, dir_close
    use :: m_strings, only: string_t, lower_ascii, ends_with_ci, path_join, path_basename, &
                            path_dirname

    implicit none (type, external)

    private

    public :: is_raw_name, count_raw_files

    type, public :: photo_list_t
        character(len=:), allocatable :: dir
        type(string_t), allocatable   :: names(:)
        integer :: count   = 0
        integer :: current = 0
        logical :: wrapped = .false.   !< last next/previous wrapped around
    contains
        procedure :: open          => list_open
        procedure :: is_empty      => list_is_empty
        procedure :: path_at       => list_path_at
        procedure :: current_path  => list_current_path
        procedure :: current_name  => list_current_name
        procedure :: offset_path   => list_offset_path
        procedure :: next          => list_next
        procedure :: previous      => list_previous
        procedure :: first         => list_first
        procedure :: last          => list_last
        procedure :: remove_current => list_remove_current
        procedure :: insert_sorted => list_insert_sorted
        procedure :: release       => list_release
    end type photo_list_t

contains

    pure logical function is_raw_name(name)
        character(len=*), intent(in) :: name
        is_raw_name = ends_with_ci(name, '.cr2') .or. ends_with_ci(name, '.cr3')
    end function is_raw_name


    !> Number of RAW files directly inside `dir` (0 if it does not exist).
    integer function count_raw_files(dir) result(n)
        character(len=*), intent(in) :: dir
        type(string_t), allocatable :: names(:)
        call scan_directory(dir, names, n)
    end function count_raw_files

    !> Open a file (selects it) or a folder (selects the first photo).
    !> Returns the number of photos found.
    integer function list_open(self, path) result(found)
        class(photo_list_t), intent(inout) :: self
        character(len=*), intent(in) :: path
        character(len=:), allocatable :: wanted
        integer :: i

        call self%release()
        found = 0
        if (len_trim(path) == 0) return

        if (is_directory(trim(path))) then
            self%dir = trim(path)
            wanted = ''
        else
            self%dir = path_dirname(trim(path))
            wanted = lower_ascii(path_basename(trim(path)))
        end if

        call scan_directory(self%dir, self%names, self%count)
        if (self%count == 0) return
        if (self%count > 1) call sort_names(self%names(1:self%count))

        self%current = 1
        if (len(wanted) > 0) then
            do i = 1, self%count
                if (lower_ascii(self%names(i)%s) == wanted) then
                    self%current = i
                    exit
                end if
            end do
        end if
        found = self%count
    end function list_open

    pure logical function list_is_empty(self)
        class(photo_list_t), intent(in) :: self
        list_is_empty = self%count <= 0
    end function list_is_empty

    function list_path_at(self, i) result(path)
        class(photo_list_t), intent(in) :: self
        integer, intent(in) :: i
        character(len=:), allocatable :: path
        path = ''
        if (i < 1 .or. i > self%count) return
        path = path_join(self%dir, self%names(i)%s)
    end function list_path_at

    function list_current_path(self) result(path)
        class(photo_list_t), intent(in) :: self
        character(len=:), allocatable :: path
        path = self%path_at(self%current)
    end function list_current_path

    function list_current_name(self) result(name)
        class(photo_list_t), intent(in) :: self
        character(len=:), allocatable :: name
        name = ''
        if (self%current < 1 .or. self%current > self%count) return
        name = self%names(self%current)%s
    end function list_current_name

    !> Path `distance` steps from the current photo, wrapping around. Does not move.
    function list_offset_path(self, distance) result(path)
        class(photo_list_t), intent(in) :: self
        integer, intent(in) :: distance
        character(len=:), allocatable :: path
        path = ''
        if (self%count < 1) return
        path = self%path_at(modulo(self%current - 1 + distance, self%count) + 1)
    end function list_offset_path

    subroutine list_next(self)
        class(photo_list_t), intent(inout) :: self
        if (self%count < 1) return
        self%wrapped = self%current == self%count .and. self%count > 1
        self%current = mod(self%current, self%count) + 1
    end subroutine list_next

    subroutine list_previous(self)
        class(photo_list_t), intent(inout) :: self
        if (self%count < 1) return
        self%wrapped = self%current == 1 .and. self%count > 1
        self%current = self%current - 1
        if (self%current < 1) self%current = self%count
    end subroutine list_previous

    subroutine list_first(self)
        class(photo_list_t), intent(inout) :: self
        self%wrapped = .false.
        if (self%count > 0) self%current = 1
    end subroutine list_first

    subroutine list_last(self)
        class(photo_list_t), intent(inout) :: self
        self%wrapped = .false.
        if (self%count > 0) self%current = self%count
    end subroutine list_last

    !> Drop the current entry; the following photo becomes current.
    subroutine list_remove_current(self)
        class(photo_list_t), intent(inout) :: self
        integer :: i
        if (self%count < 1 .or. self%current < 1 .or. self%current > self%count) return
        do i = self%current, self%count - 1
            call move_alloc(self%names(i+1)%s, self%names(i)%s)
        end do
        if (allocated(self%names(self%count)%s)) deallocate(self%names(self%count)%s)
        self%count = self%count - 1
        if (self%count == 0) then
            self%current = 0
        else if (self%current > self%count) then
            self%current = 1
        end if
    end subroutine list_remove_current

    !> Insert a file name at its sorted position and make it current.
    subroutine list_insert_sorted(self, name)
        class(photo_list_t), intent(inout) :: self
        character(len=*), intent(in) :: name
        type(string_t), allocatable :: grown(:)
        integer :: i, pos
        character(len=:), allocatable :: key

        if (.not. allocated(self%names)) allocate(self%names(16))
        if (self%count == size(self%names)) then
            allocate(grown(max(16, 2*size(self%names))))
            do i = 1, self%count
                call move_alloc(self%names(i)%s, grown(i)%s)
            end do
            call move_alloc(grown, self%names)
        end if

        key = lower_ascii(name)
        pos = self%count + 1
        do i = 1, self%count
            if (key < lower_ascii(self%names(i)%s)) then
                pos = i
                exit
            end if
        end do
        do i = self%count, pos, -1
            call move_alloc(self%names(i)%s, self%names(i+1)%s)
        end do
        self%names(pos)%s = name
        self%count = self%count + 1
        self%current = pos
        self%wrapped = .false.
    end subroutine list_insert_sorted

    subroutine list_release(self)
        class(photo_list_t), intent(inout) :: self
        if (allocated(self%names)) deallocate(self%names)
        self%count = 0
        self%current = 0
        self%wrapped = .false.
    end subroutine list_release

    ! ----------------------------------------------------------------------------------------------

    subroutine scan_directory(dir, names, n)
        character(len=*), intent(in) :: dir
        type(string_t), allocatable, intent(out) :: names(:)
        integer, intent(out) :: n
        type(dir_handle_t) :: handle
        type(string_t), allocatable :: grown(:)
        character(len=:), allocatable :: name
        logical :: is_dir
        integer :: i

        n = 0
        allocate(names(64))
        handle = dir_open(dir)
        do while (dir_next(handle, name, is_dir))
            ! Sub-folders (lights/, darks/ ...) are never listed.
            if (is_dir .or. .not. is_raw_name(name)) cycle
            if (n == size(names)) then
                allocate(grown(2*size(names)))
                do i = 1, n
                    call move_alloc(names(i)%s, grown(i)%s)
                end do
                call move_alloc(grown, names)
            end if
            n = n + 1
            names(n)%s = name
        end do
        call dir_close(handle)
    end subroutine scan_directory

    !> Case-insensitive insertion sort. readdir() output is usually close to
    !> sorted already, which is insertion sort's best case.
    subroutine sort_names(names)
        type(string_t), intent(inout) :: names(:)
        type(string_t), allocatable :: keys(:)
        type(string_t) :: tmp_key, tmp_name
        integer :: i, j

        allocate(keys(size(names)))
        do i = 1, size(names)
            keys(i)%s = lower_ascii(names(i)%s)
        end do
        do i = 2, size(names)
            call move_alloc(keys(i)%s, tmp_key%s)
            call move_alloc(names(i)%s, tmp_name%s)
            j = i - 1
            do while (j >= 1)
                if (keys(j)%s <= tmp_key%s) exit
                call move_alloc(keys(j)%s, keys(j+1)%s)
                call move_alloc(names(j)%s, names(j+1)%s)
                j = j - 1
            end do
            call move_alloc(tmp_key%s, keys(j+1)%s)
            call move_alloc(tmp_name%s, names(j+1)%s)
        end do
    end subroutine sort_names

end module m_photo_list
