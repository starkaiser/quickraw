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
!   Sorting photos into sub-folders for Siril:
!
!       Delete  -> delete_items/      L -> lights/      D -> darks/
!       F       -> flats/             B -> biases/
!
!   Folders are created next to the photos on first use. Files are moved with
!   a no-replace rename (see qr_platform.c), so nothing is ever overwritten: a
!   numeric suffix is added on name clashes. Every move is recorded so it can
!   be undone.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_sorting

    use :: m_platform, only: make_directory, platform_rename => rename_no_replace, &
                             RENAME_OK, RENAME_EXISTS, RENAME_NO_SRC
    use :: m_strings, only: path_join, path_basename, path_dirname, path_stem, &
                            path_extension, str, PATH_LENGTH
    use :: m_photo_list, only: count_raw_files

    implicit none (type, external)

    private

    integer, parameter, public :: CATEGORY_COUNT = 5
    integer, parameter, public :: CAT_LIGHTS = 1
    integer, parameter, public :: CAT_DARKS  = 2
    integer, parameter, public :: CAT_FLATS  = 3
    integer, parameter, public :: CAT_BIASES = 4
    integer, parameter, public :: CAT_DELETE = 5

    character(len=12), parameter, public :: CATEGORY_FOLDER(CATEGORY_COUNT) = &
        [character(len=12) :: 'lights', 'darks', 'flats', 'biases', 'delete_items']
    character(len=8), parameter, public :: CATEGORY_LABEL(CATEGORY_COUNT) = &
        [character(len=8) :: 'Lights', 'Darks', 'Flats', 'Biases', 'Delete']
    character(len=3), parameter, public :: CATEGORY_KEY(CATEGORY_COUNT) = &
        [character(len=3) :: 'L', 'D', 'F', 'B', 'Del']

    integer, parameter, public :: MOVE_OK             = 0
    integer, parameter, public :: MOVE_NO_SOURCE      = 1
    integer, parameter, public :: MOVE_MKDIR_FAILED   = 2
    integer, parameter, public :: MOVE_PATH_TOO_LONG  = 3
    integer, parameter, public :: MOVE_RENAME_FAILED  = 4
    integer, parameter, public :: MOVE_TARGET_EXISTS  = 5
    integer, parameter, public :: MOVE_NOTHING_TO_UNDO = 6

    integer, parameter :: UNDO_DEPTH = 256

    type, public :: move_record_t
        character(len=:), allocatable :: from_path   !< original location
        character(len=:), allocatable :: to_path     !< where it was moved
        integer :: category = 0
    end type move_record_t

    type, public :: sorter_t
        integer :: counts(CATEGORY_COUNT) = 0       !< RAW files currently in each folder
        type(move_record_t) :: history(UNDO_DEPTH)  !< ring buffer of moves
        integer :: head = 0                         !< last written history slot
        integer :: depth = 0                        !< number of undoable moves
    contains
        procedure :: init    => sorter_init
        procedure :: move    => sorter_move
        procedure :: undo    => sorter_undo
        procedure :: can_undo => sorter_can_undo
    end type sorter_t

    public :: move_status_text

contains

    !> Count the photos already sorted into each sub-folder of `dir`.
    subroutine sorter_init(self, dir)
        class(sorter_t), intent(inout) :: self
        character(len=*), intent(in) :: dir
        integer :: c
        do c = 1, CATEGORY_COUNT
            self%counts(c) = count_raw_files(path_join(dir, trim(CATEGORY_FOLDER(c))))
        end do
        self%head = 0
        self%depth = 0
    end subroutine sorter_init

    !> Move `path` into its category folder. On success `moved_to` is the new path.
    subroutine sorter_move(self, path, category, moved_to, status)
        class(sorter_t), intent(inout) :: self
        character(len=*), intent(in) :: path
        integer, intent(in) :: category
        character(len=:), allocatable, intent(out) :: moved_to
        integer, intent(out) :: status
        character(len=:), allocatable :: target_dir, name, candidate
        integer :: attempt

        moved_to = ''
        candidate = ''
        status = MOVE_NO_SOURCE
        if (len_trim(path) == 0 .or. category < 1 .or. category > CATEGORY_COUNT) return

        target_dir = path_join(path_dirname(path), trim(CATEGORY_FOLDER(category)))
        if (.not. ensure_directory(target_dir)) then
            status = MOVE_MKDIR_FAILED
            return
        end if

        name = path_basename(path)
        do attempt = 0, 9999
            if (attempt == 0) then
                candidate = path_join(target_dir, name)
            else
                candidate = path_join(target_dir, path_stem(name)//'_'//str(attempt)//path_extension(name))
            end if
            if (len(candidate) >= PATH_LENGTH) then
                status = MOVE_PATH_TOO_LONG
                return
            end if
            status = rename_no_replace(path, candidate)
            if (status == MOVE_OK) then
                moved_to = candidate
                self%counts(category) = self%counts(category) + 1
                call push_history(self, path, candidate, category)
                return
            end if
            if (status /= MOVE_TARGET_EXISTS) return
        end do
    end subroutine sorter_move

    !> Move the most recently sorted photo back. `record` describes what was undone.
    subroutine sorter_undo(self, record, status)
        class(sorter_t), intent(inout) :: self
        type(move_record_t), intent(out) :: record
        integer, intent(out) :: status

        status = MOVE_NOTHING_TO_UNDO
        if (self%depth <= 0) return
        record = self%history(self%head)
        status = rename_no_replace(record%to_path, record%from_path)
        if (status /= MOVE_OK) return

        self%counts(record%category) = max(0, self%counts(record%category) - 1)
        self%head = self%head - 1
        if (self%head < 1) self%head = UNDO_DEPTH
        self%depth = self%depth - 1
    end subroutine sorter_undo

    pure logical function sorter_can_undo(self)
        class(sorter_t), intent(in) :: self
        sorter_can_undo = self%depth > 0
    end function sorter_can_undo

    function move_status_text(status) result(text)
        integer, intent(in) :: status
        character(len=:), allocatable :: text
        select case (status)
        case (MOVE_OK);              text = 'OK'
        case (MOVE_NO_SOURCE);       text = 'no photo selected'
        case (MOVE_MKDIR_FAILED);    text = 'cannot create the destination folder'
        case (MOVE_PATH_TOO_LONG);   text = 'destination path is too long'
        case (MOVE_RENAME_FAILED);   text = 'filesystem or permission error'
        case (MOVE_TARGET_EXISTS);   text = 'a file with that name already exists'
        case (MOVE_NOTHING_TO_UNDO); text = 'nothing to undo'
        case default;                text = 'unknown error'
        end select
    end function move_status_text

    ! ----------------------------------------------------------------------------------------------

    subroutine push_history(self, from_path, to_path, category)
        type(sorter_t), intent(inout) :: self
        character(len=*), intent(in) :: from_path, to_path
        integer, intent(in) :: category
        self%head = mod(self%head, UNDO_DEPTH) + 1
        self%history(self%head)%from_path = from_path
        self%history(self%head)%to_path = to_path
        self%history(self%head)%category = category
        self%depth = min(UNDO_DEPTH, self%depth + 1)
    end subroutine push_history

    logical function ensure_directory(dir)
        character(len=*), intent(in) :: dir
        ensure_directory = make_directory(dir)
    end function ensure_directory

    !> Rename that never overwrites (renameat2 / renamex_np / MoveFileExW).
    integer function rename_no_replace(from_path, to_path) result(status)
        character(len=*), intent(in) :: from_path, to_path
        select case (platform_rename(from_path, to_path))
        case (RENAME_OK);     status = MOVE_OK
        case (RENAME_EXISTS); status = MOVE_TARGET_EXISTS
        case (RENAME_NO_SRC); status = MOVE_NO_SOURCE
        case default;         status = MOVE_RENAME_FAILED
        end select
    end function rename_no_replace

end module m_sorting
