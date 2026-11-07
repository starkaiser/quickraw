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
!   The GUI application running on coarray image 1: window, input handling,
!   frame layout and every on-screen element (top info bar, viewport, bottom
!   sorting bar, histogram, toasts, help overlay).
!
!   Frame order is chosen for latency:
!     input -> cache update -> upload current texture -> draw -> present
!     -> upload one neighbour texture
!   so a photo that is already cached appears in the same frame as the key press.
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_app

    use, intrinsic :: iso_c_binding, only: c_int, c_float, c_bool, c_double, c_char, c_ptr, &
                                           c_associated, c_f_pointer
    use :: raylib
    use :: raylib_util, only: f_c_str
    use :: m_theme
    use :: m_widgets
    use :: m_viewer, only: viewer_t
    use :: m_cache, only: image_cache_t, CACHE_SIZE, WINDOW_OFFSETS, SLOT_EMPTY, SLOT_QUEUED, &
                          SLOT_DECODING, SLOT_RECEIVING, SLOT_UPLOAD, SLOT_READY, SLOT_FAILED
    use :: m_photo_list, only: photo_list_t
    use :: m_sorting
    use :: m_preview, only: photo_info_t, HIST_BINS
    use :: m_jobs, only: JOB_NO_JPEG, JOB_DECODE, JOB_TOO_LARGE
    use :: m_workers, only: worker_count
    use :: m_strings
    use :: m_platform, only: os, OS_LINUX, OS_MACOS, path_exists, open_file_dialog, qr_asset, &
                             string_from_c_ptr
    use :: m_config, only: APP_NAME, APP_VERSION, APP_BACKEND
    use :: m_log, only: log_message, log_failure

    implicit none (type, external)

    private

    public :: app_configure, app_main, app_exit_status

    real(c_double), parameter :: FLASH_SECONDS   = 0.45d0
    real(c_double), parameter :: SPINNER_DELAY   = 0.08d0
    real(c_double), parameter :: DOUBLE_CLICK    = 0.30d0

    type :: toast_t
        character(len=:), allocatable :: title, detail, hint
        type(color_type) :: color
        real(c_double) :: start = -100.0d0
        real(c_double) :: duration = 2.2d0
    end type toast_t

    ! ---- application state -----------------------------------------------------------------------
    type(photo_list_t),  save :: list
    type(image_cache_t), save :: cache
    type(sorter_t),      save :: sorter
    type(viewer_t),      save :: viewer
    type(toast_t),       save :: toast

    character(len=:), allocatable, save :: shown_path    !< photo whose texture was last displayed
    character(len=:), allocatable, save :: titled_path   !< photo named in the window title
    type(rectangle_type), save :: viewport
    type(rectangle_type), save :: category_button(CATEGORY_COUNT), undo_button, help_button

    real(c_double), save :: now = 0.0d0, nav_time = 0.0d0, flash_time = -100.0d0
    real(c_double), save :: last_click = -100.0d0
    integer, save :: flash_category = 0
    integer(c_int), save :: cursor = MOUSE_CURSOR_DEFAULT
    logical, save :: running = .true., dragging = .false., hovering = .false.
    logical, save :: show_help = .false., show_histogram = .false., show_chrome = .true.
    logical, save :: idle = .false.     !< sleeping in EndDrawing() until the next input event
    integer(c_int), save :: frame_keys(32)   !< every key press queued since the last frame
    integer, save :: frame_key_count = 0

    character(len=:), allocatable, save :: start_path   !< from the command line ('' = welcome screen)
    integer, save :: exit_status = 0
    logical, save :: folder_open = .false.             !< .false. while the welcome screen shows
    type(texture2d_type), save :: logo                 !< app icon for the welcome screen
    type(rectangle_type), save :: open_button
    character(len=:), allocatable, save :: undo_label  !< 'Ctrl Z', or 'Cmd Z' on macOS

contains

    !> Photo or folder to open at start-up ('' shows the welcome screen).
    subroutine app_configure(path)
        character(len=*), intent(in) :: path
        start_path = trim(path)
    end subroutine app_configure

    integer function app_exit_status()
        app_exit_status = exit_status
    end function app_exit_status

    !> The GUI. Run by m_workers on the main thread (thread backend) or image 1.
    subroutine app_main()
        integer(c_int) :: monitor, mw, mh, ww, wh, flags
        type(vector2_type) :: dpi
        real :: scale

        exit_status = 0
        if (.not. allocated(start_path)) start_path = ''
        if (len(start_path) > 0 .and. .not. path_exists(start_path)) then
            call log_failure('no such file or folder: '//start_path)
            exit_status = 1
            return
        end if
        undo_label = merge('Cmd Z ', 'Ctrl Z', os() == OS_MACOS)
        undo_label = trim(undo_label)

        flags = ior(ior(FLAG_WINDOW_RESIZABLE, FLAG_VSYNC_HINT), FLAG_MSAA_4X_HINT)
        ! Retina / 150-200% displays: draw in logical pixels, render at full resolution.
        if (os() /= OS_LINUX) flags = ior(flags, FLAG_WINDOW_HIGHDPI)
        call set_config_flags(flags)
        call init_window(1400_c_int, 900_c_int, f_c_str(APP_NAME))
        call set_window_min_size(960_c_int, 560_c_int)
        call set_exit_key(KEY_NULL)          ! Esc is handled by the app (closes help first)

        dpi = get_window_scale_dpi()
        scale = max(1.0, real(dpi%x))
        monitor = get_current_monitor()
        mw = get_monitor_width(monitor)
        mh = get_monitor_height(monitor)
        if (mw > 0 .and. mh > 0) then
            ww = min(1600_c_int, int(0.88 * mw, c_int))
            wh = min(1040_c_int, int(0.88 * mh, c_int))
            call set_window_size(ww, wh)
            call set_window_position((mw - ww) / 2, (mh - wh) / 2)
            ! macOS reports monitor sizes in points; decode previews for real pixels.
            if (os() == OS_MACOS) then
                call cache%set_preview_side(nint(max(mw, mh) * scale))
            else
                call cache%set_preview_side(int(max(mw, mh)))
            end if
        end if
        call set_target_fps(max(60_c_int, get_monitor_refresh_rate(monitor)))
        call theme_init(scale)
        call load_logo()
        call log_message(APP_NAME//' '//APP_VERSION//' ('//APP_BACKEND//' backend), preview size '// &
                         str(cache%max_side)//' px')

        shown_path = ''
        titled_path = '-'
        if (len(start_path) > 0) call open_location(start_path)

        do while (running)
            if (window_should_close()) exit
            now = get_time()
            call update_layout()
            call handle_input()
            call cache%update(list)
            call cache%upload_current(list)
            call sync_view()

            call begin_drawing()
            call draw_frame()
            call end_drawing()

            call cache%upload_neighbour(list)
            call update_idle_mode()
        end do
        if (idle) call disable_event_waiting()

        call cache%clear()
        if (logo%id /= 0) call unload_texture(logo)
        call theme_release()
        call close_window()
        call list%release()
    end subroutine app_main

    !> Open a RAW file (its folder is browsed) or a folder. Used for the command
    !> line, the Open dialog and drag & drop.
    subroutine open_location(path)
        character(len=*), intent(in) :: path
        integer :: n
        if (.not. path_exists(path)) then
            call show_toast('Not found', path_basename(path), '', C_ERROR, 3.0d0)
            return
        end if
        call cache%clear()
        n = list%open(path)
        call sorter%init(list%dir)
        folder_open = .true.
        shown_path = ''
        titled_path = '-'
        nav_time = now
        call viewer%fit_to_area()
        call log_message('opened '//list%dir//' with '//str(n)//' RAW photos')
    end subroutine open_location

    !> Show the native "open" dialog.
    subroutine ask_for_photo()
        character(len=:), allocatable :: path
        integer :: status
        call open_file_dialog(path, status)
        if (status == 1) then
            call open_location(path)
        else if (status < 0) then
            call show_toast('No file dialog available', 'drag a photo or folder onto the window', &
                            '', C_TEXT_DIM, 4.0d0)
        end if
        nav_time = get_time()
    end subroutine ask_for_photo

    !> Window icon (Linux/Windows title bar and taskbar) and the welcome-screen logo.
    subroutine load_logo()
        type(c_ptr) :: data
        character(kind=c_char), pointer :: bytes(:)
        integer(c_int) :: nbytes
        type(image_type) :: icon
        data = qr_asset(3_c_int, nbytes)
        if (.not. c_associated(data) .or. nbytes <= 0) return
        call c_f_pointer(data, bytes, [nbytes])
        icon = load_image_from_memory(f_c_str('.png'), bytes(1), nbytes)
        if (.not. c_associated(icon%data)) return
        if (os() /= OS_MACOS) call set_window_icon(icon)    ! macOS uses the .app bundle icon
        logo = load_texture_from_image(icon)
        call set_texture_filter(logo, TEXTURE_FILTER_BILINEAR)
        call unload_image(icon)
    end subroutine load_logo

    ! ============================================================================================
    ! Layout and state
    ! ============================================================================================

    !> When all five photos are decoded and nothing is animating, let raylib
    !> block in EndDrawing() until the next key/mouse/window event: ~0% CPU
    !> while you look at a photo. Any event wakes it up for normal frames.
    subroutine update_idle_mode()
        logical :: settled
        settled = cache%is_settled(list) .and. .not. dragging &
                  .and. now - toast%start > toast%duration &
                  .and. now - flash_time > 2.0d0 * FLASH_SECONDS
        if (settled .neqv. idle) then
            if (settled) then
                call enable_event_waiting()
            else
                call disable_event_waiting()
            end if
            idle = settled
        end if
    end subroutine update_idle_mode

    subroutine update_layout()
        real :: sw, sh
        sw = real(get_screen_width())
        sh = real(get_screen_height())
        if (show_chrome) then
            viewport = rect(0.0, real(TOP_BAR_H), sw, sh - real(TOP_BAR_H + BOTTOM_BAR_H))
        else
            viewport = rect(0.0, 0.0, sw, sh)
        end if
        call viewer%set_area(viewport)
    end subroutine update_layout

    !> Decide what is displayed: refit when a new photo becomes visible, retitle the window.
    subroutine sync_view()
        character(len=:), allocatable :: current
        integer :: s

        current = list%current_path()
        s = cache%find(current)
        if (s > 0) then
            if (cache%slots(s)%state == SLOT_READY .and. current /= shown_path) then
                call viewer%show(int(cache%slots(s)%texture%width), int(cache%slots(s)%texture%height))
                shown_path = current
            end if
        end if

        if (current /= titled_path) then
            if (len(current) > 0) then
                call set_window_title(f_c_str(list%current_name()//'  '//U_ENDASH//'  '//APP_NAME))
            else
                call set_window_title(f_c_str(APP_NAME))
            end if
            titled_path = current
        end if
    end subroutine sync_view

    ! ============================================================================================
    ! Input
    ! ============================================================================================

    subroutine handle_input()
        real(c_float) :: wheel
        type(vector2_type) :: mouse, delta
        logical :: ctrl, shift, ctrl_seen, shift_seen
        integer :: c, k

        mouse = get_mouse_position()
        if (is_file_dropped()) then
            call open_dropped()
            return
        end if

        ! ---- keys, strictly in the order they were pressed ----
        ! raylib queues every press since the last frame. Handling them in order
        ! matters after a slow frame: "L then Right" must sort the photo that was
        ! on screen, not the next one.
        call collect_key_presses()
        ctrl_seen = .false.
        shift_seen = .false.
        do k = 1, frame_key_count
            ! Ctrl, or Cmd (the "super" key): Mac users press Cmd Z / Cmd O.
            ctrl = ctrl_seen .or. is_key_down(KEY_LEFT_CONTROL) .or. is_key_down(KEY_RIGHT_CONTROL) &
                   .or. is_key_down(KEY_LEFT_SUPER) .or. is_key_down(KEY_RIGHT_SUPER)
            shift = shift_seen .or. is_key_down(KEY_LEFT_SHIFT) .or. is_key_down(KEY_RIGHT_SHIFT)
            select case (frame_keys(k))
            case (KEY_LEFT_CONTROL, KEY_RIGHT_CONTROL, KEY_LEFT_SUPER, KEY_RIGHT_SUPER)
                ctrl_seen = .true.
            case (KEY_LEFT_SHIFT, KEY_RIGHT_SHIFT)
                shift_seen = .true.
            case (KEY_O)
                call ask_for_photo()
                return                       ! the dialog took a while: start a fresh frame
            case default
                call handle_key(frame_keys(k), ctrl, shift)
            end select
            if (.not. running) return
        end do

        ! ---- held keys auto-repeat (browsing and zoom) ----
        if (is_key_pressed_repeat(KEY_RIGHT) .or. is_key_pressed_repeat(KEY_PAGE_DOWN)) then
            call handle_key(KEY_RIGHT, .false., .false.)
        else if (is_key_pressed_repeat(KEY_LEFT) .or. is_key_pressed_repeat(KEY_PAGE_UP)) then
            call handle_key(KEY_LEFT, .false., .false.)
        end if
        if (is_key_pressed_repeat(KEY_EQUAL) .or. is_key_pressed_repeat(KEY_KP_ADD)) &
            call handle_key(KEY_EQUAL, .false., .false.)
        if (is_key_pressed_repeat(KEY_MINUS) .or. is_key_pressed_repeat(KEY_KP_SUBTRACT)) &
            call handle_key(KEY_MINUS, .false., .false.)

        ! ---- mouse wheel: zoom at the cursor ----
        wheel = get_mouse_wheel_move()
        if (wheel /= 0.0 .and. mouse_in(viewport)) &
            call viewer%zoom_at(1.18 ** real(wheel), real(mouse%x), real(mouse%y))

        ! ---- mouse: buttons, double-click, drag to pan ----
        if (is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) then
            if (show_chrome .and. mouse%y >= viewport%y + viewport%height) then
                do c = 1, CATEGORY_COUNT
                    if (mouse_in(category_button(c))) call sort_current(c)
                end do
                if (mouse_in(undo_button)) call undo_last_move()
                if (mouse_in(help_button)) show_help = .not. show_help
            else if (show_help) then
                show_help = .false.
            else if (list%is_empty() .and. mouse_in(open_button)) then
                call ask_for_photo()
                return
            else if (mouse_in(viewport)) then
                if (now - last_click < DOUBLE_CLICK) then
                    call toggle_zoom(real(mouse%x), real(mouse%y))
                    last_click = -100.0d0
                else
                    last_click = now
                end if
                dragging = .true.
            end if
        end if
        if (.not. is_mouse_button_down(MOUSE_BUTTON_LEFT)) dragging = .false.
        if (dragging) then
            delta = get_mouse_delta()
            if (delta%x /= 0.0 .or. delta%y /= 0.0) call viewer%pan(real(delta%x), real(delta%y))
        end if
    end subroutine handle_input

    !> One key press. `ctrl` means Ctrl or Cmd was held.
    subroutine handle_key(key, ctrl, shift)
        integer(c_int), intent(in) :: key
        logical, intent(in) :: ctrl, shift

        select case (key)
        ! ---- application ----
        case (KEY_ESCAPE)
            if (show_help) then
                show_help = .false.
            else
                running = .false.
            end if
        case (KEY_F1)
            show_help = .not. show_help
        case (KEY_SLASH)
            if (shift) show_help = .not. show_help
        case (KEY_TAB)
            show_chrome = .not. show_chrome
        case (KEY_H)
            show_histogram = .not. show_histogram
        case (KEY_F11)
            call toggle_borderless_windowed()

        ! ---- browsing ----
        case (KEY_RIGHT, KEY_PAGE_DOWN)
            call list%next()
            call navigated()
        case (KEY_LEFT, KEY_PAGE_UP)
            call list%previous()
            call navigated()
        case (KEY_HOME)
            call list%first()
            call navigated()
        case (KEY_END)
            call list%last()
            call navigated()

        ! ---- sorting for Siril ----
        case (KEY_L)
            if (.not. ctrl) call sort_current(CAT_LIGHTS)
        case (KEY_D)
            if (.not. ctrl) call sort_current(CAT_DARKS)
        case (KEY_F)
            if (.not. ctrl) call sort_current(CAT_FLATS)
        case (KEY_B)
            if (.not. ctrl) call sort_current(CAT_BIASES)
        case (KEY_DELETE)
            call sort_current(CAT_DELETE)
        case (KEY_BACKSPACE)
            ! Mac keyboards: the key labelled "delete" is Backspace.
            if (os() == OS_MACOS) call sort_current(CAT_DELETE)
        case (KEY_U)
            call undo_last_move()
        case (KEY_Z)
            if (ctrl) then
                call undo_last_move()
            else
                call toggle_zoom(centre_x(), centre_y())
            end if

        ! ---- zoom ----
        case (KEY_ZERO, KEY_KP_0)
            call viewer%fit_to_area()
        case (KEY_ONE, KEY_KP_1)
            call viewer%actual_size(centre_x(), centre_y())
        case (KEY_EQUAL, KEY_KP_ADD)
            call viewer%zoom_at(1.25, centre_x(), centre_y())
        case (KEY_MINUS, KEY_KP_SUBTRACT)
            call viewer%zoom_at(0.8, centre_x(), centre_y())
        end select
    end subroutine handle_key

    !> raylib's queue of key presses since the last frame, in order. It also keeps
    !> taps that were pressed *and* released within one slow frame.
    subroutine collect_key_presses()
        integer(c_int) :: key
        frame_key_count = 0
        do
            key = get_key_pressed()
            if (key == 0) exit
            if (frame_key_count < size(frame_keys)) then
                frame_key_count = frame_key_count + 1
                frame_keys(frame_key_count) = key
            end if
        end do
    end subroutine collect_key_presses


    !> Key went down this frame, or is auto-repeating while held.
    !> Open the first file or folder dropped on the window.
    subroutine open_dropped()
        type(file_path_list_type) :: files
        type(c_ptr), pointer :: paths(:)
        character(len=:), allocatable :: path
        files = load_dropped_files()
        path = ''
        if (files%count > 0 .and. c_associated(files%paths)) then
            call c_f_pointer(files%paths, paths, [int(files%count)])
            path = string_from_c_ptr(paths(1))
        end if
        call unload_dropped_files(files)
        if (len(path) > 0) call open_location(path)
    end subroutine open_dropped

    real function centre_x()
        centre_x = viewport%x + 0.5 * viewport%width
    end function centre_x

    real function centre_y()
        centre_y = viewport%y + 0.5 * viewport%height
    end function centre_y

    subroutine toggle_zoom(px, py)
        real, intent(in) :: px, py
        if (viewer%fit) then
            call viewer%actual_size(px, py)
        else
            call viewer%fit_to_area()
        end if
    end subroutine toggle_zoom

    subroutine navigated()
        nav_time = now
        if (list%wrapped) then
            if (list%current == 1) then
                call show_toast('Back to the first photo', '', '', C_ACCENT, 1.4d0)
            else
                call show_toast('Jumped to the last photo', '', '', C_ACCENT, 1.4d0)
            end if
        end if
    end subroutine navigated

    ! ============================================================================================
    ! Sorting actions
    ! ============================================================================================

    subroutine sort_current(category)
        integer, intent(in) :: category
        character(len=:), allocatable :: path, name, moved_to
        integer :: status

        if (list%is_empty()) return
        path = list%current_path()
        name = list%current_name()
        call sorter%move(path, category, moved_to, status)
        if (status /= MOVE_OK) then
            call show_toast('Could not move '//name, move_status_text(status), '', C_ERROR, 4.0d0)
            call log_failure('move failed ('//move_status_text(status)//'): '//path)
            return
        end if

        call cache%forget(path)
        call list%remove_current()
        nav_time = now
        flash_time = now
        flash_category = category
        call show_toast(trim(CATEGORY_LABEL(category)), path_basename(moved_to), &
                        undo_label//' to undo', C_CATEGORY(category), 2.0d0)
        call log_message('moved '//path//' -> '//moved_to)
    end subroutine sort_current

    subroutine undo_last_move()
        type(move_record_t) :: record
        integer :: status
        call sorter%undo(record, status)
        if (status == MOVE_NOTHING_TO_UNDO) then
            call show_toast('Nothing to undo', '', '', C_TEXT_DIM, 1.4d0)
            return
        else if (status /= MOVE_OK) then
            call show_toast('Undo failed', move_status_text(status), '', C_ERROR, 4.0d0)
            return
        end if
        if (path_dirname(record%from_path) == list%dir) then
            call list%insert_sorted(path_basename(record%from_path))
        end if
        nav_time = now
        call show_toast('Restored', path_basename(record%from_path), &
                        'from '//trim(CATEGORY_FOLDER(record%category))//'/', C_ACCENT, 2.0d0)
        call log_message('undo: '//record%to_path//' -> '//record%from_path)
    end subroutine undo_last_move

    subroutine show_toast(title, detail, hint, color, duration)
        character(len=*), intent(in) :: title, detail, hint
        type(color_type), intent(in) :: color
        real(c_double), intent(in) :: duration
        toast%title = title
        toast%detail = detail
        toast%hint = hint
        toast%color = color
        toast%start = now
        toast%duration = duration
    end subroutine show_toast

    ! ============================================================================================
    ! Drawing
    ! ============================================================================================

    subroutine draw_frame()
        hovering = .false.
        open_button = rect(0.0, 0.0, 0.0, 0.0)
        call clear_background(C_BACKGROUND)
        call fill_rect(viewport, C_VIEWPORT)
        call draw_photo()
        call draw_flash()
        if (show_chrome) then
            call draw_top_bar()
            call draw_bottom_bar()
        end if
        if (show_histogram) call draw_histogram()
        call draw_toast()
        if (show_help) call draw_help()
        call update_cursor()
    end subroutine draw_frame

    subroutine draw_photo()
        character(len=:), allocatable :: current
        integer :: s, previous
        real :: cx, cy

        cx = centre_x()
        cy = centre_y()
        if (list%is_empty()) then
            call draw_empty_state(cx, cy)
            return
        end if
        if (worker_count() < 1) then
            call draw_message(cx, cy, 'Decoding needs coarray worker images', &
                'Start QuickRAW with:  cafrun -n 4 ./quickraw <photo or folder>', C_ERROR)
            return
        end if

        current = list%current_path()
        s = cache%find(current)
        if (s > 0) then
            if (cache%slots(s)%state == SLOT_READY) then
                call viewer%draw(cache%slots(s)%texture, WHITE)
                return
            end if
        end if

        ! Not decoded yet: keep the previous photo faintly in place to avoid a black flash.
        previous = cache%find(shown_path)
        if (previous > 0) then
            if (cache%slots(previous)%state == SLOT_READY) &
                call viewer%draw(cache%slots(previous)%texture, with_alpha(WHITE, 0.22))
        end if

        if (s > 0) then
            if (cache%slots(s)%state == SLOT_FAILED) then
                call draw_message(cx, cy, 'No preview for '//list%current_name(), &
                                  failure_text(cache%slots(s)%fail_code), C_ERROR)
                return
            end if
        end if
        if (now - nav_time > SPINNER_DELAY) then
            call draw_spinner(cx, cy - 14.0, 18.0, now, C_ACCENT)
            call draw_label_centered(F_BODY, 'Loading '//list%current_name()//U_ELLIPSIS, &
                                     cx, cy + 26.0, C_TEXT_DIM)
        end if
    end subroutine draw_photo

    function failure_text(code) result(text)
        integer, intent(in) :: code
        character(len=:), allocatable :: text
        select case (code)
        case (JOB_NO_JPEG);   text = 'LibRaw could not read an embedded JPEG preview from this file.'
        case (JOB_DECODE);    text = 'The embedded JPEG preview could not be decoded.'
        case (JOB_TOO_LARGE); text = 'The preview is larger than the transfer buffer.'
        case default;         text = 'The GPU texture could not be created.'
        end select
    end function failure_text

    subroutine draw_message(cx, cy, title, detail, color)
        real, intent(in) :: cx, cy
        character(len=*), intent(in) :: title, detail
        type(color_type), intent(in) :: color
        call draw_dot(cx, cy - 40.0, 5.0, color, .true.)
        call draw_label_centered(F_TITLE, title, cx, cy - 12.0, C_TEXT)
        call draw_label_centered(F_BODY, detail, cx, cy + 16.0, C_TEXT_DIM)
    end subroutine draw_message

    subroutine draw_empty_state(cx, cy)
        real, intent(in) :: cx, cy
        character(len=:), allocatable :: title
        real :: w

        if (.not. folder_open) then
            call draw_welcome(cx, cy)
            return
        end if
        if (sum(sorter%counts) > 0) then
            title = 'All photos in this folder are sorted'
        else
            title = 'No CR2 or CR3 photos in this folder'
        end if
        call draw_label_centered(F_HUGE, title, cx, cy - 30.0, C_TEXT)
        call draw_label_centered(F_BODY, shorten_middle(list%dir, 90), cx, cy + 6.0, C_TEXT_FAINT)
        if (sorter%can_undo()) then
            w = keycap_width(undo_label) + 8.0 + text_width(F_BODY, 'undo the last move')
            call draw_keycap(undo_label, cx - 0.5 * w, cy + 46.0)
            call draw_label(F_BODY, 'undo the last move', cx - 0.5 * w + keycap_width(undo_label) + 8.0, &
                            cy + 46.0 - 0.5 * text_height(F_BODY), C_TEXT_DIM)
        else
            call draw_open_button(cx, cy + 50.0)
        end if
    end subroutine draw_empty_state

    !> Start screen when QuickRAW is launched without a photo (double-click on the app).
    subroutine draw_welcome(cx, cy)
        real, intent(in) :: cx, cy
        real, parameter :: LOGO_SIZE = 72.0
        if (logo%id /= 0) then
            call draw_texture_pro(logo, rect(0.0, 0.0, real(logo%width), real(logo%height)), &
                                  rect(cx - 0.5 * LOGO_SIZE, cy - 150.0, LOGO_SIZE, LOGO_SIZE), &
                                  vector2_type(0.0, 0.0), 0.0_c_float, WHITE)
        end if
        call draw_label_centered(F_HUGE, APP_NAME, cx, cy - 46.0, C_TEXT)
        call draw_label_centered(F_BODY, 'Drop a RAW photo or a folder here', cx, cy - 12.0, C_TEXT_DIM)
        call draw_open_button(cx, cy + 34.0)
        call draw_label_centered(F_SMALL, 'Sort your frames into lights, darks, flats and biases for Siril', &
                                 cx, cy + 86.0, C_TEXT_FAINT)
    end subroutine draw_welcome

    !> "[O] Open a photo..." button centred on (cx, cy).
    subroutine draw_open_button(cx, cy)
        real, intent(in) :: cx, cy
        character(len=*), parameter :: LABEL = 'Open a photo'
        real :: w
        w = 14.0 + keycap_width('O') + 10.0 + text_width(F_BODY, LABEL//U_ELLIPSIS) + 16.0
        open_button = rect(cx - 0.5 * w, cy - 19.0, w, 38.0)
        if (mouse_in(open_button)) then
            call draw_panel(open_button, C_HOVER, 9.0, C_KEYCAP_LINE)
            hovering = .true.
        else
            call draw_panel(open_button, C_BAR, 9.0, C_PANEL_LINE)
        end if
        call draw_keycap('O', open_button%x + 14.0, cy, C_ACCENT)
        call draw_label(F_BODY, LABEL//U_ELLIPSIS, open_button%x + 24.0 + keycap_width('O'), &
                        cy - 0.5 * text_height(F_BODY), C_TEXT)
    end subroutine draw_open_button

    subroutine draw_flash()
        real :: t, inset
        if (flash_category < 1) return
        t = real((now - flash_time) / FLASH_SECONDS)
        if (t < 0.0 .or. t >= 1.0) return
        inset = 2.0
        call draw_rectangle_lines_ex(rect(viewport%x + inset, viewport%y + inset, &
                                          viewport%width - 2.0*inset, viewport%height - 2.0*inset), &
                                     4.0_c_float, with_alpha(C_CATEGORY(flash_category), (1.0 - t)**2))
    end subroutine draw_flash

    ! ---- top bar: file name, position, folder, shooting data ------------------------------------

    subroutine draw_top_bar()
        real :: sw, x, cy, right_w, avail
        character(len=:), allocatable :: name, counter, folder
        type(photo_info_t) :: info
        logical :: have_info, failed
        integer :: s, n

        sw = real(get_screen_width())
        cy = 0.5 * real(TOP_BAR_H)
        call fill_rect(rect(0.0, 0.0, sw, real(TOP_BAR_H)), C_BAR)
        call fill_rect(rect(0.0, real(TOP_BAR_H) - 1.0, sw, 1.0), C_BAR_LINE)

        have_info = .false.
        failed = .false.
        s = cache%find(list%current_path())
        if (s > 0) then
            info = cache%slots(s)%info
            have_info = info%valid
            failed = cache%slots(s)%state == SLOT_FAILED
        end if
        right_w = draw_exif(info, have_info, failed, sw - real(PAD), cy)

        x = real(PAD)
        if (list%is_empty()) then
            call draw_label(F_TITLE, APP_NAME, x, cy - 0.5 * text_height(F_TITLE), C_TEXT)
            return
        end if
        name = list%current_name()
        counter = str(list%current)//' / '//str(list%count)
        call draw_label(F_TITLE, name, x, cy - 0.5 * text_height(F_TITLE), C_TEXT)
        x = x + text_width(F_TITLE, name) + 12.0
        call draw_label(F_BODY, counter, x, cy - 0.5 * text_height(F_BODY), C_TEXT_DIM)
        x = x + text_width(F_BODY, counter) + 18.0

        avail = sw - real(PAD) - right_w - 24.0 - x
        if (avail > 60.0) then
            n = len(list%dir)
            folder = list%dir
            do while (text_width(F_SMALL, folder) > avail .and. n > 10)
                n = n - 6
                folder = shorten_middle(list%dir, n)
            end do
            if (text_width(F_SMALL, folder) <= avail) &
                call draw_label(F_SMALL, folder, x, cy - 0.5 * text_height(F_SMALL), C_TEXT_FAINT)
        end if
    end subroutine draw_top_bar

    !> Draw the shooting data right-aligned at x_right; returns the width used.
    real function draw_exif(info, have_info, failed, x_right, cy) result(width)
        type(photo_info_t), intent(in) :: info
        logical, intent(in) :: have_info, failed
        real, intent(in) :: x_right, cy
        type(string_t) :: parts(6)
        logical :: strong(6)
        real, parameter :: GAP = 25.0       ! space between fields, a faint dot in the middle
        character(len=:), allocatable :: status_text
        real :: x
        integer :: k

        width = 0.0
        if (list%is_empty()) return
        if (.not. have_info) then
            if (failed) then
                status_text = 'No metadata'
            else
                status_text = 'Reading metadata'//U_ELLIPSIS
            end if
            width = text_width(F_BODY, status_text)
            call draw_label(F_BODY, status_text, x_right - width, cy - 0.5 * text_height(F_BODY), &
                            C_TEXT_FAINT)
            return
        end if

        parts(1)%s = format_shutter(info%shutter);   strong(1) = .true.
        parts(2)%s = format_iso(info%iso);           strong(2) = .true.
        parts(3)%s = format_aperture(info%aperture); strong(3) = .false.
        parts(4)%s = format_focal(info%focal);       strong(4) = .false.
        parts(5)%s = trim(info%model);               strong(5) = .false.
        parts(6)%s = format_timestamp(info%timestamp); strong(6) = .false.

        do k = 1, size(parts)
            if (len(parts(k)%s) == 0) cycle
            if (width > 0.0) width = width + GAP
            width = width + text_width(merge(F_STRONG, F_BODY, strong(k)), parts(k)%s)
        end do

        x = x_right - width
        do k = 1, size(parts)
            if (len(parts(k)%s) == 0) cycle
            if (x > x_right - width) then
                call draw_dot(x + 0.5 * GAP, cy, 1.5, C_TEXT_FAINT, .true.)
                x = x + GAP
            end if
            if (strong(k)) then
                call draw_label(F_STRONG, parts(k)%s, x, cy - 0.5 * text_height(F_STRONG), C_TEXT)
                x = x + text_width(F_STRONG, parts(k)%s)
            else
                call draw_label(F_BODY, parts(k)%s, x, cy - 0.5 * text_height(F_BODY), C_TEXT_DIM)
                x = x + text_width(F_BODY, parts(k)%s)
            end if
        end do
    end function draw_exif

    ! ---- bottom bar: sorting buttons, undo, cache, zoom, help -----------------------------------

    subroutine draw_bottom_bar()
        integer, parameter :: ORDER(CATEGORY_COUNT) = [CAT_LIGHTS, CAT_DARKS, CAT_FLATS, CAT_BIASES, CAT_DELETE]
        real :: sw, sh, top, cy, x, w, label_w, count_w, glow
        character(len=:), allocatable :: label, count_text
        type(rectangle_type) :: r
        integer :: k, c
        logical :: enabled

        sw = real(get_screen_width())
        sh = real(get_screen_height())
        top = sh - real(BOTTOM_BAR_H)
        cy = top + 0.5 * real(BOTTOM_BAR_H)
        call fill_rect(rect(0.0, top, sw, real(BOTTOM_BAR_H)), C_BAR)
        call fill_rect(rect(0.0, top, sw, 1.0), C_BAR_LINE)
        enabled = .not. list%is_empty()

        x = real(PAD) - 6.0
        do k = 1, CATEGORY_COUNT
            c = ORDER(k)
            if (c == CAT_DELETE) x = x + 14.0
            label = trim(CATEGORY_LABEL(c))
            count_text = str(sorter%counts(c))
            label_w = text_width(F_BODY, label)
            count_w = text_width(F_SMALL, count_text)
            w = 8.0 + keycap_width(trim(CATEGORY_KEY(c))) + 8.0 + label_w + 7.0 + count_w + 10.0
            r = rect(x, cy - 17.0, w, 34.0)
            category_button(c) = r

            glow = 0.0
            if (flash_category == c) glow = max(0.0, 1.0 - real((now - flash_time) / (2.0d0 * FLASH_SECONDS)))
            if (glow > 0.0) then
                call draw_panel(r, with_alpha(C_CATEGORY(c), 0.25 * glow), 7.0)
            else if (enabled .and. mouse_in(r)) then
                call draw_panel(r, C_HOVER, 7.0)
                hovering = .true.
            end if

            call draw_keycap(trim(CATEGORY_KEY(c)), x + 8.0, cy, C_CATEGORY(c))
            call draw_label(F_BODY, label, x + 16.0 + keycap_width(trim(CATEGORY_KEY(c))), &
                            cy - 0.5 * text_height(F_BODY), merge(C_TEXT, C_TEXT_FAINT, enabled))
            call draw_label(F_SMALL, count_text, x + w - 10.0 - count_w, &
                            cy - 0.5 * text_height(F_SMALL) + 1.0, C_TEXT_FAINT)
            x = x + w + 4.0
        end do

        ! right-hand side, laid out from the right edge
        x = sw - real(PAD)
        w = keycap_width('?')
        help_button = rect(x - w - 6.0, cy - 17.0, w + 12.0, 34.0)
        if (mouse_in(help_button)) then
            call draw_panel(help_button, C_HOVER, 7.0)
            hovering = .true.
        end if
        call draw_keycap('?', x - w, cy)
        x = x - w - 22.0

        label = zoom_text()
        w = max(text_width(F_BODY, '100%'), text_width(F_BODY, label))
        call draw_label(F_BODY, label, x - w, cy - 0.5 * text_height(F_BODY), C_TEXT_DIM)
        x = x - w - 22.0

        x = draw_cache_dots(x, cy) - 22.0

        label = 'Undo'
        w = keycap_width(undo_label) + 8.0 + text_width(F_BODY, label)
        undo_button = rect(x - w - 8.0, cy - 17.0, w + 16.0, 34.0)
        if (sorter%can_undo() .and. mouse_in(undo_button)) then
            call draw_panel(undo_button, C_HOVER, 7.0)
            hovering = .true.
        end if
        call draw_keycap(undo_label, x - w, cy, merge(C_TEXT, C_TEXT_FAINT, sorter%can_undo()))
        call draw_label(F_BODY, label, x - text_width(F_BODY, label), cy - 0.5 * text_height(F_BODY), &
                        merge(C_TEXT_DIM, C_TEXT_FAINT, sorter%can_undo()))
    end subroutine draw_bottom_bar

    function zoom_text() result(text)
        character(len=:), allocatable :: text
        if (list%is_empty() .or. viewer%image_w <= 0) then
            text = ''
        else if (viewer%fit) then
            text = 'Fit'
        else
            text = str(nint(100.0 * viewer%zoom))//'%'
        end if
    end function zoom_text

    !> Five dots for the cache window (-2 .. +2); returns the left edge.
    real function draw_cache_dots(x_right, cy) result(x_left)
        real, intent(in) :: x_right, cy
        real, parameter :: STEP = 13.0
        type(color_type) :: color
        integer :: k, state
        real :: x, pulse
        logical :: filled

        x_left = x_right - STEP * real(CACHE_SIZE - 1) - 10.0
        if (list%is_empty()) return
        pulse = 0.45 + 0.4 * real(sin(now * 7.0d0))
        do k = 1, CACHE_SIZE
            x = x_left + 5.0 + STEP * real(k - 1)
            state = cache%state_of(list%offset_path(WINDOW_OFFSETS(k)))
            filled = .true.
            select case (state)
            case (SLOT_READY)
                color = C_TEXT_DIM
            case (SLOT_RECEIVING, SLOT_UPLOAD)
                color = C_ACCENT
            case (SLOT_DECODING)
                color = with_alpha(C_ACCENT, pulse)
            case (SLOT_FAILED)
                color = C_ERROR
            case (SLOT_QUEUED)
                color = with_alpha(C_TEXT_FAINT, 0.8)
            case default
                color = C_TEXT_FAINT
                filled = .false.
            end select
            if (WINDOW_OFFSETS(k) == 0) then
                call draw_dot(x, cy, 7.0, with_alpha(color, 0.35), .false.)
                call draw_dot(x, cy, 4.0, color, filled)
            else
                call draw_dot(x, cy, 3.0, color, filled)
            end if
        end do
    end function draw_cache_dots

    ! ---- overlays -----------------------------------------------------------------------------

    subroutine draw_toast()
        real :: t, alpha, w, h, x, y, title_w, detail_w, hint_w
        if (.not. allocated(toast%title)) return
        t = real(now - toast%start)
        if (t < 0.0 .or. t > toast%duration) return
        alpha = min(1.0, t / 0.08, real(toast%duration - t) / 0.35)

        title_w  = text_width(F_STRONG, toast%title)
        detail_w = text_width(F_BODY, toast%detail)
        hint_w   = text_width(F_SMALL, toast%hint)
        w = 22.0 + 12.0 + title_w + 22.0
        if (detail_w > 0.0) w = w + 12.0 + detail_w
        if (hint_w > 0.0) w = w + 18.0 + hint_w
        h = 40.0
        x = real(nint(centre_x() - 0.5 * w))
        y = viewport%y + viewport%height - h - 22.0

        call draw_panel(rect(x, y, w, h), with_alpha(C_PANEL, alpha), 0.5 * h, &
                        with_alpha(C_PANEL_LINE, alpha))
        x = x + 22.0
        call draw_dot(x, y + 0.5 * h, 4.5, with_alpha(toast%color, alpha), .true.)
        x = x + 12.0
        call draw_label(F_STRONG, toast%title, x, y + 0.5 * (h - text_height(F_STRONG)), &
                        with_alpha(toast%color, alpha))
        x = x + title_w
        if (detail_w > 0.0) then
            x = x + 12.0
            call draw_label(F_BODY, toast%detail, x, y + 0.5 * (h - text_height(F_BODY)), &
                            with_alpha(C_TEXT, alpha))
            x = x + detail_w
        end if
        if (hint_w > 0.0) then
            x = x + 18.0
            call draw_label(F_SMALL, toast%hint, x, y + 0.5 * (h - text_height(F_SMALL)), &
                            with_alpha(C_TEXT_FAINT, alpha))
        end if
    end subroutine draw_toast

    subroutine draw_histogram()
        real, parameter :: W = 300.0, H = 172.0
        type(photo_info_t) :: info
        type(color_type) :: channel_color(3), clip_color
        real :: x0, y0, pw, ph, px, py, bin_w, v, prev_x, prev_y, cur_x, cur_y
        integer :: s, i, ch
        character(len=:), allocatable :: clip
        logical :: valid

        px = viewport%x + viewport%width - W - real(PAD)
        py = viewport%y + viewport%height - H - real(PAD)
        call draw_panel(rect(px, py, W, H), C_PANEL, real(RADIUS), C_PANEL_LINE)
        call draw_label(F_STRONG, 'Histogram', px + 14.0, py + 12.0, C_TEXT)

        valid = .false.
        s = cache%find(list%current_path())
        if (s > 0) then
            info = cache%slots(s)%info
            valid = info%valid .and. info%hist_peak > 0
        end if
        if (.not. valid) then
            call draw_label_centered(F_SMALL, 'Waiting for the preview'//U_ELLIPSIS, &
                                     px + 0.5 * W, py + 0.5 * H + 10.0, C_TEXT_FAINT)
            return
        end if

        clip = 'Clipped '//str_real(info%clipped_highlights, 1)//'%'
        clip_color = C_TEXT_FAINT
        if (info%clipped_highlights >= 0.5) clip_color = C_ERROR
        call draw_label(F_SMALL, clip, px + W - 14.0 - text_width(F_SMALL, clip), py + 14.0, clip_color)

        x0 = px + 14.0
        y0 = py + 40.0
        pw = W - 28.0
        ph = H - 56.0
        bin_w = pw / real(HIST_BINS)
        call fill_rect(rect(x0, y0 + ph, pw, 1.0), C_PANEL_LINE)

        do i = 0, HIST_BINS - 1      ! luminance as a filled area
            v = bar(info%histogram(i, 4), info%hist_peak) * ph
            if (v > 0.0) call fill_rect(rect(x0 + bin_w * real(i), y0 + ph - v, bin_w + 0.6, v), C_HIST_L)
        end do

        channel_color = [C_HIST_R, C_HIST_G, C_HIST_B]
        do ch = 1, 3                 ! R, G, B as curves
            prev_x = x0
            prev_y = y0 + ph - bar(info%histogram(0, ch), info%hist_peak) * ph
            do i = 1, HIST_BINS - 1
                cur_x = x0 + bin_w * (real(i) + 0.5)
                cur_y = y0 + ph - bar(info%histogram(i, ch), info%hist_peak) * ph
                call draw_line_ex(vector2_type(prev_x, prev_y), vector2_type(cur_x, cur_y), &
                                  1.4_c_float, channel_color(ch))
                prev_x = cur_x
                prev_y = cur_y
            end do
        end do
    end subroutine draw_histogram

    !> Square-root scale: faint tails stay visible without hiding the main peak.
    pure real function bar(count, peak)
        integer, intent(in) :: count, peak
        bar = min(1.0, sqrt(real(count) / real(max(1, peak))))
    end function bar

    subroutine draw_help()
        real, parameter :: W = 700.0, H = 500.0, ROW_H = 27.0
        real :: sw, sh, px, py, x, y, col2
        integer :: c

        sw = real(get_screen_width())
        sh = real(get_screen_height())
        call fill_rect(rect(0.0, 0.0, sw, sh), rgb(0, 150))
        px = real(nint(0.5 * (sw - W)))
        py = real(nint(0.5 * (sh - H)))
        call draw_panel(rect(px, py, W, H), C_PANEL, 12.0, C_PANEL_LINE)

        call draw_label(F_HUGE, APP_NAME, px + 28.0, py + 24.0, C_TEXT)
        call draw_label(F_BODY, 'v'//APP_VERSION//'   '//U_MIDDOT//'   keyboard shortcuts', &
                        px + 36.0 + text_width(F_HUGE, APP_NAME), py + 30.0, C_TEXT_FAINT)

        ! left column: browsing and view
        x = px + 28.0
        y = py + 82.0
        call section('Browse', x, y)
        call row([string_t(U_LEFT), string_t(U_RIGHT)], 'Previous / next photo (hold to scroll)', x, y)
        call row([string_t('Home'), string_t('End')], 'First / last photo', x, y)
        call row([string_t('O')], 'Open a photo, or drop one here', x, y)
        y = y + 10.0
        call section('View', x, y)
        call row([string_t('Z')], 'Toggle fit / 100%  (or double-click)', x, y)
        call row([string_t('0'), string_t('1')], 'Fit to window / 100%', x, y)
        call row([string_t('+'), string_t('-')], 'Zoom in / out  (or mouse wheel)', x, y)
        call row([string_t('Drag')], 'Pan when zoomed in', x, y)
        call row([string_t('H')], 'Histogram', x, y)
        call row([string_t('Tab')], 'Hide / show the bars', x, y)
        call row([string_t('F11')], 'Full screen', x, y)

        ! right column: sorting
        col2 = px + 0.5 * W + 18.0
        x = col2
        y = py + 82.0
        call section('Sort for Siril', x, y)
        do c = 1, CATEGORY_COUNT
            call row([string_t(trim(CATEGORY_KEY(c)))], &
                     'Move to  '//trim(CATEGORY_FOLDER(c))//'/', x, y, C_CATEGORY(c))
        end do
        call row([string_t(undo_label), string_t('U')], 'Undo the last move', x, y)
        y = y + 10.0
        call draw_label(F_SMALL, 'Folders are created next to the photos.', x, y, C_TEXT_FAINT)
        call draw_label(F_SMALL, 'Existing files are never overwritten.', x, y + 18.0, C_TEXT_FAINT)

        call draw_label_centered(F_SMALL, 'Esc, ? or a click closes this panel', &
                                 px + 0.5 * W, py + H - 24.0, C_TEXT_FAINT)

    contains

        subroutine section(title, sx, sy)
            character(len=*), intent(in) :: title
            real, intent(in) :: sx
            real, intent(inout) :: sy
            call draw_label(F_STRONG, title, sx, sy, C_TEXT_DIM)
            sy = sy + 28.0
        end subroutine section

        subroutine row(keys, text, rx, ry, tint)
            type(string_t), intent(in) :: keys(:)
            character(len=*), intent(in) :: text
            real, intent(in) :: rx
            real, intent(inout) :: ry
            type(color_type), intent(in), optional :: tint
            real :: kx
            integer :: k
            kx = rx
            do k = 1, size(keys)
                if (present(tint)) then
                    call draw_keycap(keys(k)%s, kx, ry + 9.0, tint)
                else
                    call draw_keycap(keys(k)%s, kx, ry + 9.0)
                end if
                kx = kx + keycap_width(keys(k)%s) + 4.0
            end do
            call draw_label(F_BODY, text, rx + 96.0, ry + 9.0 - 0.5 * text_height(F_BODY), C_TEXT)
            ry = ry + ROW_H
        end subroutine row

    end subroutine draw_help

    subroutine update_cursor()
        integer(c_int) :: wanted
        wanted = MOUSE_CURSOR_DEFAULT
        if (hovering) wanted = MOUSE_CURSOR_POINTING_HAND
        if (dragging .and. .not. viewer%fit) wanted = MOUSE_CURSOR_RESIZE_ALL
        if (wanted /= cursor) then
            call set_mouse_cursor(wanted)
            cursor = wanted
        end if
    end subroutine update_cursor

end module m_app
