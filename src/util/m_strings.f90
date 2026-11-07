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
!   Small string and path helpers shared by every other module: C strings,
!   case folding, path splitting/joining, number formatting and the
!   photographic formatters (shutter speed, aperture, ...).
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_strings

    use, intrinsic :: iso_c_binding, only: c_char, c_null_char, c_int64_t, c_long_long
    use :: m_platform, only: os, OS_WINDOWS, local_time_text

    implicit none (type, external)

    private

    integer, parameter, public :: PATH_LENGTH = 4096

    !> Deferred-length string usable as an array element.
    type, public :: string_t
        character(len=:), allocatable :: s
    end type string_t

    public :: to_c_string, from_c_chars
    public :: lower_ascii, ends_with_ci
    public :: path_basename, path_dirname, path_join, path_extension, path_stem
    public :: str, str_real
    public :: format_shutter, format_aperture, format_focal, format_iso, format_timestamp
    public :: shorten_middle, path_separator

contains

    !> Fortran string -> null-terminated C character array.
    pure function to_c_string(value) result(c_value)
        character(len=*), intent(in) :: value
        character(kind=c_char), allocatable :: c_value(:)
        integer :: k, n
        n = len_trim(value)
        allocate(c_value(n + 1))
        do k = 1, n
            c_value(k) = value(k:k)
        end do
        c_value(n + 1) = c_null_char
    end function to_c_string

    !> C character array (null-terminated or not) -> trimmed Fortran string.
    pure function from_c_chars(chars) result(value)
        character(kind=c_char), intent(in) :: chars(:)
        character(len=:), allocatable :: value
        integer :: k, n
        n = 0
        do k = 1, size(chars)
            if (chars(k) == c_null_char) exit
            n = k
        end do
        allocate(character(len=n) :: value)
        do k = 1, n
            value(k:k) = chars(k)
        end do
        value = trim(value)
    end function from_c_chars

    pure function lower_ascii(value) result(lowered)
        character(len=*), intent(in) :: value
        character(len=len(value)) :: lowered
        integer :: i, code
        lowered = value
        do i = 1, len(value)
            code = iachar(value(i:i))
            if (code >= iachar('A') .and. code <= iachar('Z')) lowered(i:i) = achar(code + 32)
        end do
    end function lower_ascii

    pure logical function ends_with_ci(value, suffix)
        character(len=*), intent(in) :: value, suffix
        integer :: n, m
        n = len_trim(value)
        m = len(suffix)
        ends_with_ci = .false.
        if (m > n) return
        ends_with_ci = lower_ascii(value(n-m+1:n)) == lower_ascii(suffix)
    end function ends_with_ci

    !> Native separator for building paths: '\' on Windows, '/' elsewhere.
    pure function path_separator() result(sep)
        character(len=1) :: sep
        if (os() == OS_WINDOWS) then
            sep = achar(92)
        else
            sep = '/'
        end if
    end function path_separator

    !> '/' everywhere, and also '\' on Windows.
    pure logical function is_separator(ch)
        character(len=1), intent(in) :: ch
        is_separator = ch == '/' .or. (ch == achar(92) .and. os() == OS_WINDOWS)
    end function is_separator

    pure integer function last_separator(path) result(pos)
        character(len=*), intent(in) :: path
        integer :: i
        pos = 0
        do i = len(path), 1, -1
            if (is_separator(path(i:i))) then
                pos = i
                return
            end if
        end do
    end function last_separator

    !> Length of the path without trailing separators (keeps a lone root).
    pure integer function trimmed_length(path) result(last)
        character(len=*), intent(in) :: path
        last = len_trim(path)
        do while (last > 1)
            if (.not. is_separator(path(last:last))) exit
            if (last == 3 .and. path(2:2) == ':') exit      ! 'C:\'
            last = last - 1
        end do
    end function trimmed_length

    pure function path_basename(path) result(name)
        character(len=*), intent(in) :: path
        character(len=:), allocatable :: name
        integer :: slash, last
        last = trimmed_length(path)
        slash = last_separator(path(:last))
        name = path(slash+1:last)
    end function path_basename

    pure function path_dirname(path) result(dir)
        character(len=*), intent(in) :: path
        character(len=:), allocatable :: dir
        integer :: slash, last
        last = trimmed_length(path)
        slash = last_separator(path(:last))
        if (slash == 0) then
            dir = '.'
        else if (slash == 1) then
            dir = path(1:1)                                  ! '/'
        else if (slash == 3 .and. path(2:2) == ':') then
            dir = path(1:3)                                  ! 'C:\'
        else
            dir = path(:slash-1)
        end if
    end function path_dirname

    pure function path_join(dir, name) result(path)
        character(len=*), intent(in) :: dir, name
        character(len=:), allocatable :: path
        integer :: n
        n = len_trim(dir)
        if (n == 0) then
            path = trim(name)
        else if (is_separator(dir(n:n))) then
            path = dir(:n)//trim(name)
        else
            path = dir(:n)//path_separator()//trim(name)
        end if
    end function path_join

    !> Extension including the dot ('.CR2'), or '' if none.
    pure function path_extension(name) result(ext)
        character(len=*), intent(in) :: name
        character(len=:), allocatable :: ext
        integer :: dot
        dot = index(trim(name), '.', back=.true.)
        if (dot > 1) then
            ext = name(dot:len_trim(name))
        else
            ext = ''
        end if
    end function path_extension

    pure function path_stem(name) result(stem)
        character(len=*), intent(in) :: name
        character(len=:), allocatable :: stem
        integer :: dot
        dot = index(trim(name), '.', back=.true.)
        if (dot > 1) then
            stem = name(:dot-1)
        else
            stem = trim(name)
        end if
    end function path_stem

    pure function str(value) result(text)
        integer, intent(in) :: value
        character(len=:), allocatable :: text
        character(len=24) :: buffer
        write(buffer, '(i0)') value
        text = trim(buffer)
    end function str

    !> Real -> text with at most `decimals` decimals and trailing zeros removed.
    pure function str_real(value, decimals) result(text)
        real, intent(in) :: value
        integer, intent(in) :: decimals
        character(len=:), allocatable :: text
        character(len=32) :: buffer
        character(len=16) :: fmt
        integer :: n
        write(fmt, '("(f0.",i0,")")') max(0, decimals)
        write(buffer, fmt) value
        text = trim(adjustl(buffer))
        ! gfortran writes 0.5 as '.5' and -0.5 as '-.5' with the f0.d edit descriptor.
        if (len(text) > 0) then
            if (text(1:1) == '.') text = '0'//text
        end if
        if (len(text) > 1) then
            if (text(1:2) == '-.') text = '-0'//text(2:)
        end if
        if (index(text, '.') > 0) then
            n = len(text)
            do while (text(n:n) == '0')
                n = n - 1
            end do
            if (text(n:n) == '.') n = n - 1
            text = text(:n)
        end if
    end function str_real

    !> 0.00025 -> '1/4000 s', 30 -> '30 s', 2.5 -> '2.5 s'.
    pure function format_shutter(seconds) result(text)
        real, intent(in) :: seconds
        character(len=:), allocatable :: text
        if (seconds <= 0.0) then
            text = ''
        else if (seconds >= 0.3) then
            text = str_real(seconds, 1)//' s'
        else
            text = '1/'//str(nint(1.0 / seconds))//' s'
        end if
    end function format_shutter

    pure function format_aperture(f_number) result(text)
        real, intent(in) :: f_number
        character(len=:), allocatable :: text
        if (f_number <= 0.0) then
            text = ''
        else
            text = 'f/'//str_real(f_number, 1)
        end if
    end function format_aperture

    pure function format_focal(mm) result(text)
        real, intent(in) :: mm
        character(len=:), allocatable :: text
        if (mm <= 0.0) then
            text = ''
        else
            text = str(nint(mm))//' mm'
        end if
    end function format_focal

    pure function format_iso(iso) result(text)
        real, intent(in) :: iso
        character(len=:), allocatable :: text
        if (iso <= 0.0) then
            text = ''
        else
            text = 'ISO '//str(nint(iso))
        end if
    end function format_iso

    !> Unix time -> 'YYYY-MM-DD  HH:MM:SS' in local time (the camera clock).
    function format_timestamp(epoch) result(text)
        integer(c_int64_t), intent(in) :: epoch
        character(len=:), allocatable :: text
        text = local_time_text(int(epoch, c_long_long))
    end function format_timestamp

    !> Shorten long text to max_chars by replacing its middle with '...'.
    pure function shorten_middle(text, max_chars) result(short)
        character(len=*), intent(in) :: text
        integer, intent(in) :: max_chars
        character(len=:), allocatable :: short
        integer :: n, head, tail
        n = len_trim(text)
        if (n <= max_chars .or. max_chars < 5) then
            short = text(:n)
            return
        end if
        head = (max_chars - 3) / 2
        tail = max_chars - 3 - head
        short = text(:head)//'...'//text(n-tail+1:n)
    end function shorten_middle

end module m_strings
