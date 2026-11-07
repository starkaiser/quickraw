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
!   Immediate-mode drawing helpers built on raylib: text, rounded panels,
!   key caps, buttons with hover state, spinner and hit testing.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_widgets

    use, intrinsic :: iso_c_binding, only: c_float, c_int
    use :: raylib, only: color_type, font_type, rectangle_type, vector2_type, draw_text_ex, &
                         measure_text_ex, draw_rectangle_rounded, draw_rectangle_rounded_lines, &
                         draw_rectangle_rec, draw_ring, draw_circle_v, draw_circle_lines_v, &
                         get_mouse_position
    use :: raylib_util, only: f_c_str
    use :: m_theme

    implicit none (type, external)

    private

    public :: rect, text_width, text_height, draw_label, draw_label_centered
    public :: draw_panel, draw_keycap, keycap_width, draw_spinner, draw_dot
    public :: mouse_in, fill_rect

contains

    pure function rect(x, y, w, h) result(r)
        real, intent(in) :: x, y, w, h
        type(rectangle_type) :: r
        r = rectangle_type(real(x, c_float), real(y, c_float), real(w, c_float), real(h, c_float))
    end function rect

    real function text_width(font, text)
        type(font_type), intent(in) :: font
        character(len=*), intent(in) :: text
        type(vector2_type) :: size
        if (len_trim(text) == 0) then
            text_width = 0.0
            return
        end if
        size = measure_text_ex(font, f_c_str(text), font_px(font), 0.0_c_float)
        text_width = real(size%x)
    end function text_width

    real function text_height(font)
        type(font_type), intent(in) :: font
        text_height = real(font_px(font))
    end function text_height

    !> Text with its top-left corner at (x, y), snapped to whole pixels.
    subroutine draw_label(font, text, x, y, color)
        type(font_type), intent(in) :: font
        character(len=*), intent(in) :: text
        real, intent(in) :: x, y
        type(color_type), intent(in) :: color
        if (len_trim(text) == 0) return
        call draw_text_ex(font, f_c_str(text), vector2_type(real(nint(x), c_float), &
                          real(nint(y), c_float)), font_px(font), 0.0_c_float, color)
    end subroutine draw_label

    !> Text centred on (cx, cy).
    subroutine draw_label_centered(font, text, cx, cy, color)
        type(font_type), intent(in) :: font
        character(len=*), intent(in) :: text
        real, intent(in) :: cx, cy
        type(color_type), intent(in) :: color
        call draw_label(font, text, cx - 0.5 * text_width(font, text), cy - 0.5 * text_height(font), color)
    end subroutine draw_label_centered

    subroutine fill_rect(r, color)
        type(rectangle_type), intent(in) :: r
        type(color_type), intent(in) :: color
        call draw_rectangle_rec(r, color)
    end subroutine fill_rect

    !> Rounded rectangle with a corner radius in pixels and an optional outline.
    subroutine draw_panel(r, fill, radius_px, outline)
        type(rectangle_type), intent(in) :: r
        type(color_type), intent(in) :: fill
        real, intent(in) :: radius_px
        type(color_type), intent(in), optional :: outline
        real(c_float) :: roundness
        if (r%width <= 0.0 .or. r%height <= 0.0) return
        roundness = real(min(1.0, 2.0 * radius_px / max(1.0, min(r%width, r%height))), c_float)
        call draw_rectangle_rounded(r, roundness, 8_c_int, fill)
        if (present(outline)) call draw_rectangle_rounded_lines(r, roundness, 8_c_int, 1.0_c_float, outline)
    end subroutine draw_panel

    real function keycap_width(label)
        character(len=*), intent(in) :: label
        keycap_width = max(22.0, text_width(F_SMALL, label) + 12.0)
    end function keycap_width

    !> A small key-cap ("L", "Del", "Ctrl Z") with its left edge at x, vertically centred on cy.
    subroutine draw_keycap(label, x, cy, tint)
        character(len=*), intent(in) :: label
        real, intent(in) :: x, cy
        type(color_type), intent(in), optional :: tint
        type(rectangle_type) :: r
        type(color_type) :: text_color
        real :: w
        w = keycap_width(label)
        r = rect(x, cy - 11.0, w, 22.0)
        call draw_panel(r, C_KEYCAP, 5.0, C_KEYCAP_LINE)
        text_color = C_TEXT
        if (present(tint)) text_color = tint
        call draw_label_centered(F_SMALL, label, x + 0.5 * w, cy, text_color)
    end subroutine draw_keycap

    !> Indeterminate progress ring; `t` is the time in seconds.
    subroutine draw_spinner(cx, cy, radius_px, t, color)
        real, intent(in) :: cx, cy, radius_px
        real(kind(1.0d0)), intent(in) :: t
        type(color_type), intent(in) :: color
        real(c_float) :: start
        start = real(modulo(t * 360.0d0, 360.0d0), c_float)
        call draw_ring(vector2_type(cx, cy), real(radius_px - 3.0, c_float), real(radius_px, c_float), &
                       0.0_c_float, 360.0_c_float, 48_c_int, with_alpha(color, 0.15))
        call draw_ring(vector2_type(cx, cy), real(radius_px - 3.0, c_float), real(radius_px, c_float), &
                       start, start + 100.0_c_float, 24_c_int, color)
    end subroutine draw_spinner

    subroutine draw_dot(cx, cy, radius_px, color, filled)
        real, intent(in) :: cx, cy, radius_px
        type(color_type), intent(in) :: color
        logical, intent(in) :: filled
        if (filled) then
            call draw_circle_v(vector2_type(cx, cy), real(radius_px, c_float), color)
        else
            call draw_circle_lines_v(vector2_type(cx, cy), real(radius_px, c_float), color)
        end if
    end subroutine draw_dot

    logical function mouse_in(r)
        type(rectangle_type), intent(in) :: r
        type(vector2_type) :: m
        m = get_mouse_position()
        mouse_in = m%x >= r%x .and. m%x < r%x + r%width .and. m%y >= r%y .and. m%y < r%y + r%height
    end function mouse_in

    !> Size to draw a font at, in logical pixels.
    real(c_float) function font_px(font)
        type(font_type), intent(in) :: font
        if (font%base_size > 12) then
            font_px = real(real(font%base_size) / UI_SCALE, c_float)   ! embedded Inter
        else if (font%base_size > 0) then
            font_px = 2.0_c_float * real(font%base_size, c_float)      ! raylib's 10 px font
        else
            font_px = 15.0_c_float
        end if
    end function font_px

end module m_widgets
