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
!   Bindings to the LibRaw C API (libraw.h). Only the calls needed to pull the
!   embedded JPEG preview and a little shooting metadata are bound.
!
!   libraw_iparams_t and libraw_imgother_t are bound as *prefixes* of the real
!   structures: they are only ever read through a pointer returned by LibRaw,
!   so declaring the leading fields is enough and keeps us independent of the
!   trailing fields that change between LibRaw releases.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_libraw

    use, intrinsic :: iso_c_binding, only: c_char, c_int, c_short, c_signed_char, c_ptr, c_float, &
                                           c_int64_t

    implicit none (type, external)

    private

    integer(c_int), parameter, public :: LIBRAW_SUCCESS    = 0_c_int
    integer(c_int), parameter, public :: LIBRAW_IMAGE_JPEG = 1_c_int

    type, bind(C), public :: libraw_processed_image_t
        integer(c_int)         :: image_type
        integer(c_short)       :: height
        integer(c_short)       :: width
        integer(c_short)       :: colors
        integer(c_short)       :: bits
        integer(c_int)         :: data_size
        integer(c_signed_char) :: data(1)
    end type libraw_processed_image_t

    ! Leading fields of libraw_iparams_t.
    type, bind(C), public :: libraw_iparams_prefix_t
        character(kind=c_char) :: guard(4)
        character(kind=c_char) :: make(64)
        character(kind=c_char) :: model(64)
    end type libraw_iparams_prefix_t

    ! Leading fields of libraw_imgother_t.
    type, bind(C), public :: libraw_imgother_prefix_t
        real(c_float)      :: iso_speed
        real(c_float)      :: shutter
        real(c_float)      :: aperture
        real(c_float)      :: focal_len
        integer(c_int64_t) :: timestamp      ! time_t
    end type libraw_imgother_prefix_t

    public :: libraw_init, libraw_open_file, libraw_unpack_thumb
    public :: libraw_dcraw_make_mem_thumb, libraw_dcraw_clear_mem, libraw_close
    public :: libraw_get_iparams, libraw_get_imgother, libraw_get_iwidth, libraw_get_iheight

    interface
        function libraw_init(flags) bind(C, name="libraw_init") result(raw)
            import :: c_int, c_ptr
            integer(c_int), value :: flags
            type(c_ptr) :: raw
        end function libraw_init

        function libraw_open_file(raw, filename) bind(C, name="libraw_open_file") result(status)
            import :: c_char, c_int, c_ptr
            type(c_ptr), value :: raw
            character(kind=c_char), intent(in) :: filename(*)
            integer(c_int) :: status
        end function libraw_open_file

        function libraw_unpack_thumb(raw) bind(C, name="libraw_unpack_thumb") result(status)
            import :: c_int, c_ptr
            type(c_ptr), value :: raw
            integer(c_int) :: status
        end function libraw_unpack_thumb

        function libraw_dcraw_make_mem_thumb(raw, error_code) &
                bind(C, name="libraw_dcraw_make_mem_thumb") result(image)
            import :: c_int, c_ptr
            type(c_ptr), value :: raw
            integer(c_int), intent(out) :: error_code
            type(c_ptr) :: image
        end function libraw_dcraw_make_mem_thumb

        subroutine libraw_dcraw_clear_mem(image) bind(C, name="libraw_dcraw_clear_mem")
            import :: c_ptr
            type(c_ptr), value :: image
        end subroutine libraw_dcraw_clear_mem

        subroutine libraw_close(raw) bind(C, name="libraw_close")
            import :: c_ptr
            type(c_ptr), value :: raw
        end subroutine libraw_close

        function libraw_get_iparams(raw) bind(C, name="libraw_get_iparams") result(params)
            import :: c_ptr
            type(c_ptr), value :: raw
            type(c_ptr) :: params
        end function libraw_get_iparams

        function libraw_get_imgother(raw) bind(C, name="libraw_get_imgother") result(other)
            import :: c_ptr
            type(c_ptr), value :: raw
            type(c_ptr) :: other
        end function libraw_get_imgother

        function libraw_get_iwidth(raw) bind(C, name="libraw_get_iwidth") result(width)
            import :: c_int, c_ptr
            type(c_ptr), value :: raw
            integer(c_int) :: width
        end function libraw_get_iwidth

        function libraw_get_iheight(raw) bind(C, name="libraw_get_iheight") result(height)
            import :: c_int, c_ptr
            type(c_ptr), value :: raw
            integer(c_int) :: height
        end function libraw_get_iheight
    end interface

end module m_libraw
