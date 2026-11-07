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
!   Image placement inside the viewport: fit-to-window, 1:1, zoom anchored at
!   the mouse cursor, panning, and keeping the image on screen.
!
!   While "fit" is on, the image refits whenever the window or photo changes.
!   Once the user zooms, the zoom and pan are kept when stepping to the next
!   photo, which makes it easy to compare the same stars across frames.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_viewer

    use, intrinsic :: iso_c_binding, only: c_float
    use :: raylib, only: texture2d_type, rectangle_type, vector2_type, color_type, draw_texture_pro
    use :: m_widgets, only: rect

    implicit none (type, external)

    private

    real, parameter :: MIN_ZOOM = 0.02, MAX_ZOOM = 32.0

    type, public :: viewer_t
        type(rectangle_type) :: area            !< viewport in screen pixels
        real    :: zoom = 1.0                   !< screen pixels per texture pixel
        real    :: x = 0.0, y = 0.0             !< screen position of the image's top-left corner
        integer :: image_w = 0, image_h = 0
        logical :: fit = .true.
    contains
        procedure :: set_area    => viewer_set_area
        procedure :: show        => viewer_show
        procedure :: fit_to_area => viewer_fit_to_area
        procedure :: actual_size => viewer_actual_size
        procedure :: zoom_at     => viewer_zoom_at
        procedure :: pan         => viewer_pan
        procedure :: draw        => viewer_draw
        procedure :: fit_zoom    => viewer_fit_zoom
    end type viewer_t

contains

    subroutine viewer_set_area(self, area)
        class(viewer_t), intent(inout) :: self
        type(rectangle_type), intent(in) :: area
        real :: cx, cy
        logical :: changed
        changed = area%x /= self%area%x .or. area%y /= self%area%y .or. &
                  area%width /= self%area%width .or. area%height /= self%area%height
        if (.not. changed) return
        ! Keep the point that was in the middle of the old viewport in the middle.
        cx = self%area%x + 0.5 * self%area%width
        cy = self%area%y + 0.5 * self%area%height
        self%x = self%x + (area%x + 0.5 * area%width - cx)
        self%y = self%y + (area%y + 0.5 * area%height - cy)
        self%area = area
        if (self%fit) then
            call self%fit_to_area()
        else
            call clamp(self)
        end if
    end subroutine viewer_set_area

    !> A new photo is displayed. Keep zoom/pan for same-sized photos unless fitting.
    subroutine viewer_show(self, width, height)
        class(viewer_t), intent(inout) :: self
        integer, intent(in) :: width, height
        logical :: same_size
        same_size = width == self%image_w .and. height == self%image_h
        self%image_w = width
        self%image_h = height
        if (self%fit .or. .not. same_size) then
            call self%fit_to_area()
        else
            call clamp(self)
        end if
    end subroutine viewer_show

    real function viewer_fit_zoom(self) result(z)
        class(viewer_t), intent(in) :: self
        z = 1.0
        if (self%image_w <= 0 .or. self%image_h <= 0) return
        z = min(self%area%width / real(self%image_w), self%area%height / real(self%image_h))
        z = max(MIN_ZOOM, z)
    end function viewer_fit_zoom

    subroutine viewer_fit_to_area(self)
        class(viewer_t), intent(inout) :: self
        self%fit = .true.
        if (self%image_w <= 0 .or. self%image_h <= 0) return
        self%zoom = self%fit_zoom()
        self%x = real(nint(self%area%x + 0.5 * (self%area%width - self%image_w * self%zoom)))
        self%y = real(nint(self%area%y + 0.5 * (self%area%height - self%image_h * self%zoom)))
    end subroutine viewer_fit_to_area

    !> One texture pixel per screen pixel, keeping the point under (px, py) fixed.
    subroutine viewer_actual_size(self, px, py)
        class(viewer_t), intent(inout) :: self
        real, intent(in) :: px, py
        call self%zoom_at(1.0 / self%zoom, px, py)
        self%x = real(nint(self%x))
        self%y = real(nint(self%y))
    end subroutine viewer_actual_size

    !> Multiply the zoom by `factor`, keeping the image point under (px, py) fixed.
    subroutine viewer_zoom_at(self, factor, px, py)
        class(viewer_t), intent(inout) :: self
        real, intent(in) :: factor, px, py
        real :: new_zoom, ix, iy
        if (self%image_w <= 0) return
        new_zoom = max(MIN_ZOOM, min(MAX_ZOOM, self%zoom * factor))
        ix = (px - self%x) / self%zoom
        iy = (py - self%y) / self%zoom
        self%zoom = new_zoom
        self%x = px - ix * new_zoom
        self%y = py - iy * new_zoom
        self%fit = .false.
        ! Zooming out past "fit" snaps back to fit: no tiny floating image.
        if (factor < 1.0 .and. new_zoom <= self%fit_zoom() * 1.0001) then
            call self%fit_to_area()
        else
            call clamp(self)
        end if
    end subroutine viewer_zoom_at

    subroutine viewer_pan(self, dx, dy)
        class(viewer_t), intent(inout) :: self
        real, intent(in) :: dx, dy
        if (self%fit) return            ! a fitted image has nothing to pan
        self%x = self%x + dx
        self%y = self%y + dy
        call clamp(self)
    end subroutine viewer_pan

    subroutine viewer_draw(self, texture, tint)
        class(viewer_t), intent(in) :: self
        type(texture2d_type), intent(in) :: texture
        type(color_type), intent(in) :: tint
        type(rectangle_type) :: source, dest
        if (texture%id == 0) return
        source = rect(0.0, 0.0, real(texture%width), real(texture%height))
        dest = rect(self%x, self%y, real(texture%width) * self%zoom, real(texture%height) * self%zoom)
        call draw_texture_pro(texture, source, dest, vector2_type(0.0, 0.0), 0.0_c_float, tint)
    end subroutine viewer_draw

    !> Centre an image smaller than the viewport; otherwise do not let its edges
    !> come inside the viewport.
    subroutine clamp(self)
        type(viewer_t), intent(inout) :: self
        real :: w, h
        w = self%image_w * self%zoom
        h = self%image_h * self%zoom
        if (w <= self%area%width) then
            self%x = self%area%x + 0.5 * (self%area%width - w)
        else
            self%x = min(self%area%x, max(self%area%x + self%area%width - w, self%x))
        end if
        if (h <= self%area%height) then
            self%y = self%area%y + 0.5 * (self%area%height - h)
        else
            self%y = min(self%area%y, max(self%area%y + self%area%height - h, self%y))
        end if
    end subroutine clamp

end module m_viewer
