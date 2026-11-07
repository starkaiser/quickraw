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
!   Look and feel: colour palette, category colours, layout metrics and fonts.
!
!   The Inter fonts are compiled into the program (qr_assets.c), so a release
!   needs no files next to it. They are rasterised at the exact pixel size used
!   times the display scale (2 on a Retina / 200% screen), so text maps 1:1 to
!   screen pixels and stays crisp. raylib's built-in font is the last resort.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_theme

    use, intrinsic :: iso_c_binding, only: c_int, c_char, c_ptr, c_associated, c_f_pointer
    use :: raylib, only: color_type, font_type, load_font_from_memory, unload_font, &
                         get_font_default, c_unsigned_char
    use :: raylib_util, only: f_c_str
    use :: m_platform, only: qr_asset
    use :: m_sorting, only: CATEGORY_COUNT, CAT_LIGHTS, CAT_DARKS, CAT_FLATS, CAT_BIASES, CAT_DELETE
    use :: m_log, only: log_message

    implicit none (type, external)

    private

    ! ---- layout (pixels) -----------------------------------------------------------------------
    integer, parameter, public :: TOP_BAR_H    = 46
    integer, parameter, public :: BOTTOM_BAR_H = 52
    integer, parameter, public :: PAD          = 14
    integer, parameter, public :: RADIUS       = 8

    ! ---- palette -------------------------------------------------------------------------------
    type(color_type), public, protected :: C_BACKGROUND, C_VIEWPORT, C_BAR, C_BAR_LINE
    type(color_type), public, protected :: C_PANEL, C_PANEL_LINE, C_HOVER, C_KEYCAP, C_KEYCAP_LINE
    type(color_type), public, protected :: C_TEXT, C_TEXT_DIM, C_TEXT_FAINT, C_ACCENT, C_ERROR
    type(color_type), public, protected :: C_HIST_R, C_HIST_G, C_HIST_B, C_HIST_L
    type(color_type), public, protected :: C_CATEGORY(CATEGORY_COUNT)

    ! ---- fonts ---------------------------------------------------------------------------------
    type(font_type), public, protected :: F_SMALL    !< 13 px regular
    type(font_type), public, protected :: F_BODY     !< 15 px regular
    type(font_type), public, protected :: F_STRONG   !< 15 px semibold
    type(font_type), public, protected :: F_TITLE    !< 17 px semibold
    type(font_type), public, protected :: F_HUGE     !< 24 px semibold
    !> Display scale (1 normally, 2 on Retina). Fonts are rasterised this much larger.
    real, public, protected :: UI_SCALE = 1.0

    ! ---- UTF-8 glyphs used in labels -----------------------------------------------------------
    character(len=*), parameter, public :: U_MIDDOT = char(194)//char(183)
    character(len=*), parameter, public :: U_TIMES  = char(195)//char(151)
    character(len=*), parameter, public :: U_LEFT   = char(226)//char(134)//char(144)
    character(len=*), parameter, public :: U_RIGHT  = char(226)//char(134)//char(146)
    character(len=*), parameter, public :: U_ELLIPSIS = char(226)//char(128)//char(166)
    character(len=*), parameter, public :: U_ENDASH = char(226)//char(128)//char(147)

    integer(c_int), save :: codepoints(110)

    public :: theme_init, theme_release, rgb, with_alpha, mix

contains

    pure function rgb(hex, alpha) result(c)
        integer, intent(in) :: hex
        integer, intent(in), optional :: alpha
        type(color_type) :: c
        integer :: a
        a = 255
        if (present(alpha)) a = alpha
        c = color_type(to_byte(ishft(hex, -16)), to_byte(ishft(hex, -8)), to_byte(hex), to_byte(a))
    end function rgb

    !> Same colour with opacity multiplied by `alpha` (0..1).
    pure function with_alpha(c, alpha) result(out)
        type(color_type), intent(in) :: c
        real, intent(in) :: alpha
        type(color_type) :: out
        out = c
        out%a = to_byte(nint(real(from_byte(c%a)) * max(0.0, min(1.0, alpha))))
    end function with_alpha

    !> Linear blend a -> b, t in 0..1.
    pure function mix(a, b, t) result(out)
        type(color_type), intent(in) :: a, b
        real, intent(in) :: t
        type(color_type) :: out
        real :: u
        u = max(0.0, min(1.0, t))
        out%r = to_byte(nint(from_byte(a%r) + (from_byte(b%r) - from_byte(a%r)) * u))
        out%g = to_byte(nint(from_byte(a%g) + (from_byte(b%g) - from_byte(a%g)) * u))
        out%b = to_byte(nint(from_byte(a%b) + (from_byte(b%b) - from_byte(a%b)) * u))
        out%a = to_byte(nint(from_byte(a%a) + (from_byte(b%a) - from_byte(a%a)) * u))
    end function mix

    !> Call once after the window (and its GL context) exists.
    !> `scale` is the display scale factor (GetWindowScaleDPI).
    subroutine theme_init(scale)
        real, intent(in) :: scale

        C_BACKGROUND  = rgb(int(z'0B0C0E'))
        C_VIEWPORT    = rgb(int(z'0E0F12'))
        C_BAR         = rgb(int(z'16181C'))
        C_BAR_LINE    = rgb(int(z'25282E'))
        C_PANEL       = rgb(int(z'1B1E23'), 246)
        C_PANEL_LINE  = rgb(int(z'2E323A'))
        C_HOVER       = rgb(int(z'262A31'))
        C_KEYCAP      = rgb(int(z'2A2E35'))
        C_KEYCAP_LINE = rgb(int(z'3A3F48'))
        C_TEXT        = rgb(int(z'E8EAED'))
        C_TEXT_DIM    = rgb(int(z'A2A8B0'))
        C_TEXT_FAINT  = rgb(int(z'646A73'))
        C_ACCENT      = rgb(int(z'7AA7FF'))
        C_ERROR       = rgb(int(z'FF6B6B'))
        C_HIST_R      = rgb(int(z'FF5A5A'), 210)
        C_HIST_G      = rgb(int(z'5AD67A'), 210)
        C_HIST_B      = rgb(int(z'5A8CFF'), 210)
        C_HIST_L      = rgb(int(z'C8CCD2'), 70)

        C_CATEGORY(CAT_LIGHTS) = rgb(int(z'F7C548'))   ! warm amber
        C_CATEGORY(CAT_DARKS)  = rgb(int(z'9B87F5'))   ! violet
        C_CATEGORY(CAT_FLATS)  = rgb(int(z'4CC9F0'))   ! sky
        C_CATEGORY(CAT_BIASES) = rgb(int(z'5ED39A'))   ! mint
        C_CATEGORY(CAT_DELETE) = rgb(int(z'FF6B6B'))   ! red

        UI_SCALE = max(1.0, min(4.0, scale))
        call fill_codepoints()
        F_SMALL  = load_embedded(1, 13)
        F_BODY   = load_embedded(1, 15)
        F_STRONG = load_embedded(2, 15)
        F_TITLE  = load_embedded(2, 17)
        F_HUGE   = load_embedded(2, 24)
        call log_message('UI fonts: embedded Inter, display scale '// &
                         trim(adjustl(scale_text(UI_SCALE))))
    end subroutine theme_init

    subroutine theme_release()
        call release(F_SMALL)
        call release(F_BODY)
        call release(F_STRONG)
        call release(F_TITLE)
        call release(F_HUGE)
    contains
        subroutine release(font)
            type(font_type), intent(inout) :: font
            if (custom_font(font)) call unload_font(font)
            font = font_type()
        end subroutine release
    end subroutine theme_release

    !> Fonts loaded by theme_init are larger than raylib's 10 px built-in one.
    pure logical function custom_font(font)
        type(font_type), intent(in) :: font
        custom_font = font%base_size > 12
    end function custom_font

    ! ----------------------------------------------------------------------------------------------

    !> Rasterise embedded font `asset` (1 regular, 2 semibold) for `px` logical pixels.
    function load_embedded(asset, px) result(font)
        integer, intent(in) :: asset, px
        type(font_type) :: font
        type(c_ptr) :: data
        character(kind=c_char), pointer :: bytes(:)
        integer(c_int) :: nbytes

        data = qr_asset(int(asset, c_int), nbytes)
        if (.not. c_associated(data) .or. nbytes <= 0) then
            font = get_font_default()
            return
        end if
        call c_f_pointer(data, bytes, [nbytes])
        font = load_font_from_memory(f_c_str('.ttf'), bytes(1), nbytes, &
                                     int(nint(px * UI_SCALE), c_int), codepoints, &
                                     int(size(codepoints), c_int))
        if (font%glyph_count <= 0) font = get_font_default()
    end function load_embedded

    subroutine fill_codepoints()
        integer :: i, n
        n = 0
        do i = 32, 126
            n = n + 1
            codepoints(n) = int(i, c_int)
        end do
        ! middle dot, multiplication sign, degree, arrows, ellipsis, dashes, bullet
        codepoints(n+1:) = int([183, 215, 176, 8592, 8593, 8594, 8595, 8230, 8211, 8212, 8226, &
                                169, 177, 181, 8722], c_int)
    end subroutine fill_codepoints

    function scale_text(value) result(text)
        real, intent(in) :: value
        character(len=16) :: text
        write(text, '(f0.2)') value
    end function scale_text

    elemental function to_byte(value) result(b)
        integer, intent(in) :: value
        integer(c_unsigned_char) :: b
        integer :: v
        v = iand(value, 255)
        if (v > 127) v = v - 256
        b = int(v, kind(C_TEXT%r))
    end function to_byte

    elemental function from_byte(b) result(value)
        integer(c_unsigned_char), intent(in) :: b
        real :: value
        integer :: v
        v = int(b)
        if (v < 0) v = v + 256
        value = real(v)
    end function from_byte

end module m_theme
