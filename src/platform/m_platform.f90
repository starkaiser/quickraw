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
!   Fortran interface to qr_platform.c, the only OS-specific code. Wrappers
!   take and return ordinary Fortran strings (UTF-8 on every platform).
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, November 2026
!
! ==================================================================================================

module m_platform

    use, intrinsic :: iso_c_binding, only: c_char, c_int, c_ptr, c_null_char, c_long_long, &
                                           c_associated, c_null_ptr, c_size_t, c_f_pointer

    implicit none (type, external)

    private

    integer, parameter, public :: OS_LINUX = 1, OS_MACOS = 2, OS_WINDOWS = 3

    integer, parameter, public :: RENAME_OK      = 0
    integer, parameter, public :: RENAME_EXISTS  = 1
    integer, parameter, public :: RENAME_NO_SRC  = 2
    integer, parameter, public :: RENAME_FAILED  = 3

    integer, parameter :: NAME_LEN = 1024
    integer, parameter :: LONG_PATH = 8192

    public :: os, path_exists, is_directory, make_directory, rename_no_replace, sleep_ms
    public :: local_time_text, argument_count, argument, open_file_dialog
    public :: dir_handle_t, dir_open, dir_next, dir_close
    public :: qr_libraw_open, qr_free, qr_asset, string_from_c_ptr

    type :: dir_handle_t
        type(c_ptr) :: ptr = c_null_ptr
    end type dir_handle_t

    interface
        pure function qr_platform() bind(C, name="qr_platform") result(id)
            import :: c_int
            integer(c_int) :: id
        end function qr_platform

        subroutine qr_free(p) bind(C, name="qr_free")
            import :: c_ptr
            type(c_ptr), value :: p
        end subroutine qr_free

        subroutine qr_sleep_ms(ms) bind(C, name="qr_sleep_ms")
            import :: c_int
            integer(c_int), value :: ms
        end subroutine qr_sleep_ms

        function qr_format_time(epoch, out, out_len) bind(C, name="qr_format_time") result(n)
            import :: c_long_long, c_char, c_int
            integer(c_long_long), value :: epoch
            character(kind=c_char), intent(out) :: out(*)
            integer(c_int), value :: out_len
            integer(c_int) :: n
        end function qr_format_time

        function qr_exists(path) bind(C, name="qr_exists") result(flag)
            import :: c_char, c_int
            character(kind=c_char), intent(in) :: path(*)
            integer(c_int) :: flag
        end function qr_exists

        function qr_is_dir(path) bind(C, name="qr_is_dir") result(flag)
            import :: c_char, c_int
            character(kind=c_char), intent(in) :: path(*)
            integer(c_int) :: flag
        end function qr_is_dir

        function qr_mkdir(path) bind(C, name="qr_mkdir") result(status)
            import :: c_char, c_int
            character(kind=c_char), intent(in) :: path(*)
            integer(c_int) :: status
        end function qr_mkdir

        function qr_rename_noreplace(from, to) bind(C, name="qr_rename_noreplace") result(status)
            import :: c_char, c_int
            character(kind=c_char), intent(in) :: from(*), to(*)
            integer(c_int) :: status
        end function qr_rename_noreplace

        function qr_dir_open(path) bind(C, name="qr_dir_open") result(handle)
            import :: c_char, c_ptr
            character(kind=c_char), intent(in) :: path(*)
            type(c_ptr) :: handle
        end function qr_dir_open

        function qr_dir_next(handle, name, name_len, is_dir) bind(C, name="qr_dir_next") result(found)
            import :: c_ptr, c_char, c_int
            type(c_ptr), value :: handle
            character(kind=c_char), intent(out) :: name(*)
            integer(c_int), value :: name_len
            integer(c_int), intent(out) :: is_dir
            integer(c_int) :: found
        end function qr_dir_next

        subroutine qr_dir_close(handle) bind(C, name="qr_dir_close")
            import :: c_ptr
            type(c_ptr), value :: handle
        end subroutine qr_dir_close

        function qr_argument_count() bind(C, name="qr_argument_count") result(n)
            import :: c_int
            integer(c_int) :: n
        end function qr_argument_count

        function qr_argument(i, out, out_len) bind(C, name="qr_argument") result(n)
            import :: c_int, c_char
            integer(c_int), value :: i, out_len
            character(kind=c_char), intent(out) :: out(*)
            integer(c_int) :: n
        end function qr_argument

        function qr_open_file_dialog(out, out_len) bind(C, name="qr_open_file_dialog") result(n)
            import :: c_char, c_int
            character(kind=c_char), intent(out) :: out(*)
            integer(c_int), value :: out_len
            integer(c_int) :: n
        end function qr_open_file_dialog

        !> libraw_open_file() that accepts UTF-8 paths on Windows too.
        function qr_libraw_open(raw, path, owned) bind(C, name="qr_libraw_open") result(status)
            import :: c_ptr, c_char, c_int
            type(c_ptr), value :: raw
            character(kind=c_char), intent(in) :: path(*)
            type(c_ptr), intent(out) :: owned
            integer(c_int) :: status
        end function qr_libraw_open

        pure function c_strlen(str) bind(C, name="strlen") result(n)
            import :: c_ptr, c_size_t
            type(c_ptr), value :: str
            integer(c_size_t) :: n
        end function c_strlen

        !> Embedded file: 1 regular font, 2 semibold font, 3 window icon (PNG).
        function qr_asset(id, size) bind(C, name="qr_asset") result(data)
            import :: c_int, c_ptr
            integer(c_int), value :: id
            integer(c_int), intent(out) :: size
            type(c_ptr) :: data
        end function qr_asset
    end interface

contains

    pure integer function os()
        os = int(qr_platform())
    end function os

    logical function path_exists(path)
        character(len=*), intent(in) :: path
        path_exists = qr_exists(c_str(path)) /= 0
    end function path_exists

    logical function is_directory(path)
        character(len=*), intent(in) :: path
        is_directory = qr_is_dir(c_str(path)) /= 0
    end function is_directory

    !> Create a folder; .true. if it exists afterwards.
    logical function make_directory(path)
        character(len=*), intent(in) :: path
        make_directory = qr_mkdir(c_str(path)) == 0
    end function make_directory

    !> Rename without ever overwriting. Returns one of the RENAME_* codes.
    integer function rename_no_replace(from, to) result(status)
        character(len=*), intent(in) :: from, to
        status = int(qr_rename_noreplace(c_str(from), c_str(to)))
    end function rename_no_replace

    subroutine sleep_ms(ms)
        integer, intent(in) :: ms
        call qr_sleep_ms(int(ms, c_int))
    end subroutine sleep_ms

    function local_time_text(epoch) result(text)
        integer(c_long_long), intent(in) :: epoch
        character(len=:), allocatable :: text
        character(kind=c_char) :: buffer(64)
        integer(c_int) :: n
        n = qr_format_time(epoch, buffer, int(size(buffer), c_int))
        text = chars_to_string(buffer, int(n))
    end function local_time_text

    function dir_open(path) result(handle)
        character(len=*), intent(in) :: path
        type(dir_handle_t) :: handle
        handle%ptr = qr_dir_open(c_str(path))
    end function dir_open

    !> Next folder entry. Returns .false. at the end (or if the folder could not be opened).
    logical function dir_next(handle, name, is_dir) result(found)
        type(dir_handle_t), intent(in) :: handle
        character(len=:), allocatable, intent(out) :: name
        logical, intent(out) :: is_dir
        character(kind=c_char) :: buffer(NAME_LEN)
        integer(c_int) :: flag
        integer :: n

        found = .false.
        is_dir = .false.
        name = ''
        if (.not. c_associated(handle%ptr)) return
        if (qr_dir_next(handle%ptr, buffer, int(NAME_LEN, c_int), flag) == 0) return
        n = 0
        do while (n < NAME_LEN)
            if (buffer(n + 1) == c_null_char) exit
            n = n + 1
        end do
        name = chars_to_string(buffer, n)
        is_dir = flag /= 0
        found = .true.
    end function dir_next

    subroutine dir_close(handle)
        type(dir_handle_t), intent(inout) :: handle
        if (c_associated(handle%ptr)) call qr_dir_close(handle%ptr)
        handle%ptr = c_null_ptr
    end subroutine dir_close

    !> Number of command-line arguments (UTF-8 aware on Windows).
    integer function argument_count()
        argument_count = int(qr_argument_count())
        if (argument_count < 0) argument_count = command_argument_count()
    end function argument_count

    !> Command-line argument i (1-based) as UTF-8.
    function argument(i) result(text)
        integer, intent(in) :: i
        character(len=:), allocatable :: text
        character(kind=c_char) :: buffer(LONG_PATH)
        character(len=LONG_PATH) :: fortran_arg
        integer(c_int) :: n
        n = qr_argument(int(i, c_int), buffer, int(LONG_PATH, c_int))
        if (n >= 0) then
            text = chars_to_string(buffer, int(n))
        else
            call get_command_argument(i, fortran_arg)
            text = trim(fortran_arg)
        end if
    end function argument

    !> Native "open" dialog. status: 1 chosen, 0 cancelled, -1 no dialog available.
    subroutine open_file_dialog(path, status)
        character(len=:), allocatable, intent(out) :: path
        integer, intent(out) :: status
        character(kind=c_char) :: buffer(LONG_PATH)
        integer(c_int) :: n
        n = qr_open_file_dialog(buffer, int(LONG_PATH, c_int))
        path = ''
        if (n < 0) then
            status = -1
        else if (n == 0) then
            status = 0
        else
            path = chars_to_string(buffer, int(n))
            status = 1
        end if
    end subroutine open_file_dialog

    !> Copy a null-terminated C string (e.g. from raylib) into a Fortran string.
    function string_from_c_ptr(ptr) result(text)
        type(c_ptr), intent(in) :: ptr
        character(len=:), allocatable :: text
        character(kind=c_char), pointer :: chars(:)
        integer :: n
        text = ''
        if (.not. c_associated(ptr)) return
        n = int(c_strlen(ptr))
        if (n <= 0) return
        call c_f_pointer(ptr, chars, [n])
        text = chars_to_string(chars, n)
    end function string_from_c_ptr

    ! ----------------------------------------------------------------------------------------------

    pure function c_str(value) result(c_value)
        character(len=*), intent(in) :: value
        character(kind=c_char) :: c_value(len(value) + 1)
        integer :: k
        do k = 1, len(value)
            c_value(k) = value(k:k)
        end do
        c_value(len(value) + 1) = c_null_char
    end function c_str

    pure function chars_to_string(chars, n) result(text)
        character(kind=c_char), intent(in) :: chars(:)
        integer, intent(in) :: n
        character(len=:), allocatable :: text
        integer :: k
        allocate(character(len=max(0, min(n, size(chars)))) :: text)
        do k = 1, len(text)
            text(k:k) = chars(k)
        end do
    end function chars_to_string

end module m_platform
