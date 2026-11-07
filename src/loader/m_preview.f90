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
!   CPU-only work done by the coarray worker images for one photo:
!
!     1. read_embedded_jpeg  - LibRaw: open the RAW, read shooting metadata and
!                              copy out the embedded full-size JPEG preview
!     2. decode_preview      - raylib/stb: decode the JPEG, downscale so the long
!                              side fits the screen, convert to packed RGB8
!     3. compute_histogram   - 256-bin R, G, B and luminance histogram
!
!   The stages are separate so a worker can abandon a job between them when the
!   GUI cancels it (the user has already scrolled past that photo).
!   No graphics context is needed: texture upload happens on the GUI image.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_preview

    use, intrinsic :: iso_c_binding, only: c_char, c_int, c_ptr, c_associated, &
                                           c_f_pointer, c_loc, c_int64_t
    use, intrinsic :: iso_fortran_env, only: int64, real64
    use :: raylib, only: image_type, load_image_from_memory, image_resize, image_format, &
                         unload_image, PIXELFORMAT_UNCOMPRESSED_R8G8B8
    use :: raylib_util, only: f_c_str
    use :: m_libraw
    use :: m_platform, only: qr_libraw_open, qr_free
    use :: m_strings, only: to_c_string, from_c_chars

    implicit none (type, external)

    private

    integer, parameter, public :: HIST_BINS = 256

    !> Everything the GUI shows about a photo besides its pixels.
    !> Plain data only (no allocatables) so it can live inside a coarray.
    type, public :: photo_info_t
        logical            :: valid = .false.
        character(len=64)  :: make  = ''
        character(len=64)  :: model = ''
        real               :: iso = 0.0, shutter = 0.0, aperture = 0.0, focal = 0.0
        integer(c_int64_t) :: timestamp = 0
        integer            :: sensor_width = 0, sensor_height = 0
        !> histogram(bin, channel), channel 1..3 = R,G,B, 4 = luminance
        integer            :: histogram(0:HIST_BINS-1, 4) = 0
        integer            :: hist_peak = 0          !< max bin over R,G,B
        real               :: clipped_highlights = 0.0   !< % of pixels with a channel at 255
        real               :: clipped_shadows = 0.0      !< % of pixels with luminance 0
    end type photo_info_t

    public :: read_embedded_jpeg, decode_preview, compute_histogram

contains

    !> Stage 1. Returns the JPEG bytes (empty on failure) and fills the metadata.
    subroutine read_embedded_jpeg(path, jpeg, info)
        character(len=*), intent(in) :: path
        character(kind=c_char), allocatable, intent(out) :: jpeg(:)
        type(photo_info_t), intent(inout) :: info

        type(c_ptr) :: raw, thumb_ptr, params_ptr, other_ptr, file_buffer
        type(libraw_processed_image_t), pointer :: thumb
        type(libraw_iparams_prefix_t), pointer :: params
        type(libraw_imgother_prefix_t), pointer :: other
        character(kind=c_char), pointer :: bytes(:)
        integer(c_int) :: rc, thumb_error
        integer :: n

        raw = libraw_init(0_c_int)
        if (.not. c_associated(raw)) return

        rc = qr_libraw_open(raw, to_c_string(path), file_buffer)
        if (rc /= LIBRAW_SUCCESS) then
            call libraw_close(raw)
            if (c_associated(file_buffer)) call qr_free(file_buffer)
            return
        end if

        params_ptr = libraw_get_iparams(raw)
        if (c_associated(params_ptr)) then
            call c_f_pointer(params_ptr, params)
            info%make  = from_c_chars(params%make)
            info%model = from_c_chars(params%model)
        end if
        other_ptr = libraw_get_imgother(raw)
        if (c_associated(other_ptr)) then
            call c_f_pointer(other_ptr, other)
            info%iso       = other%iso_speed
            info%shutter   = other%shutter
            info%aperture  = other%aperture
            info%focal     = other%focal_len
            info%timestamp = other%timestamp
        end if
        info%sensor_width  = int(libraw_get_iwidth(raw))
        info%sensor_height = int(libraw_get_iheight(raw))
        info%valid = .true.

        rc = libraw_unpack_thumb(raw)
        if (rc == LIBRAW_SUCCESS) then
            thumb_ptr = libraw_dcraw_make_mem_thumb(raw, thumb_error)
            if (c_associated(thumb_ptr)) then
                call c_f_pointer(thumb_ptr, thumb)
                if (thumb%image_type == LIBRAW_IMAGE_JPEG .and. thumb%data_size >= 3_c_int) then
                    n = int(thumb%data_size)
                    call c_f_pointer(c_loc(thumb%data(1)), bytes, [n])
                    ! JPEG SOI marker FF D8 FF
                    if (iachar(bytes(1)) == 255 .and. iachar(bytes(2)) == 216 .and. &
                        iachar(bytes(3)) == 255) then
                        allocate(jpeg(n))
                        jpeg = bytes
                    end if
                    nullify(bytes)
                end if
                call libraw_dcraw_clear_mem(thumb_ptr)
            end if
        end if
        call libraw_close(raw)
        if (c_associated(file_buffer)) call qr_free(file_buffer)   ! Windows non-ASCII path fallback
    end subroutine read_embedded_jpeg

    !> Stage 2. Decode, fit the long side into max_side, convert to RGB8.
    subroutine decode_preview(jpeg, max_side, pixels, width, height, ok)
        character(kind=c_char), intent(in), target :: jpeg(:)
        integer, intent(in) :: max_side
        character(kind=c_char), allocatable, intent(out) :: pixels(:)
        integer, intent(out) :: width, height
        logical, intent(out) :: ok

        type(image_type) :: image
        character(kind=c_char), pointer :: decoded(:)
        integer(int64) :: nbytes
        real(real64) :: scale

        ok = .false.
        width = 0
        height = 0
        if (size(jpeg) < 3) return

        image = load_image_from_memory(f_c_str('.jpg'), jpeg(1), int(size(jpeg), c_int))
        if (.not. c_associated(image%data)) return
        if (image%width <= 0 .or. image%height <= 0) then
            call unload_image(image)
            return
        end if

        if (max_side > 0 .and. max(image%width, image%height) > max_side) then
            scale = real(max_side, real64) / real(max(image%width, image%height), real64)
            call image_resize(image, max(1_c_int, nint(image%width * scale, c_int)), &
                                     max(1_c_int, nint(image%height * scale, c_int)))
        end if
        call image_format(image, PIXELFORMAT_UNCOMPRESSED_R8G8B8)
        if (.not. c_associated(image%data) .or. image%width <= 0 .or. image%height <= 0) then
            call unload_image(image)
            return
        end if

        nbytes = int(image%width, int64) * int(image%height, int64) * 3_int64
        if (nbytes > int(huge(0), int64)) then
            call unload_image(image)
            return
        end if
        call c_f_pointer(image%data, decoded, [int(nbytes)])
        allocate(pixels(nbytes))
        pixels = decoded
        nullify(decoded)
        width = int(image%width)
        height = int(image%height)
        call unload_image(image)
        ok = .true.
    end subroutine decode_preview

    !> Stage 3. Histogram of packed RGB8 pixels.
    subroutine compute_histogram(pixels, info)
        character(kind=c_char), intent(in) :: pixels(:)
        type(photo_info_t), intent(inout) :: info
        integer :: i, r, g, b, y, npix, clipped_hi, clipped_lo

        info%histogram = 0
        clipped_hi = 0
        clipped_lo = 0
        npix = size(pixels) / 3
        do i = 0, npix - 1
            r = iachar(pixels(3*i + 1))
            g = iachar(pixels(3*i + 2))
            b = iachar(pixels(3*i + 3))
            ! Rec.709 luma with integer weights (sum = 256)
            y = (54*r + 183*g + 19*b) / 256
            info%histogram(r, 1) = info%histogram(r, 1) + 1
            info%histogram(g, 2) = info%histogram(g, 2) + 1
            info%histogram(b, 3) = info%histogram(b, 3) + 1
            info%histogram(y, 4) = info%histogram(y, 4) + 1
            if (r == 255 .or. g == 255 .or. b == 255) clipped_hi = clipped_hi + 1
            if (y == 0) clipped_lo = clipped_lo + 1
        end do
        ! Ignore the two extreme bins for the vertical scale so clipping spikes
        ! do not flatten the rest of the curve.
        info%hist_peak = max(1, maxval(info%histogram(1:HIST_BINS-2, 1:3)))
        if (npix > 0) then
            info%clipped_highlights = 100.0 * real(clipped_hi) / real(npix)
            info%clipped_shadows    = 100.0 * real(clipped_lo) / real(npix)
        end if
    end subroutine compute_histogram

end module m_preview
