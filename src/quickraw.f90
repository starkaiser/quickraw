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
!   Main program. The GUI (m_app) runs on the main thread / coarray image 1;
!   previews are decoded in the background by m_workers, which is either
!
!     m_workers_threads.f90   OpenMP threads, one process  (default, releases)
!     m_workers_coarray.f90   coarray images                (make BACKEND=coarray)
!
!       ./quickraw [-v] [photo.CR2 | folder]
!       cafrun -n 4 ./quickraw [-v] [photo.CR2 | folder]     (coarray build)
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

program quickraw

    use :: m_app, only: app_configure, app_main, app_exit_status
    use :: m_workers, only: workers_run, workers_is_primary
    use :: m_platform, only: argument_count, argument
    use :: m_config, only: APP_NAME, APP_VERSION, APP_BACKEND
    use :: m_log, only: log_set_verbose, log_is_verbose
    use :: raylib, only: set_trace_log_level, LOG_WARNING, LOG_ERROR

    implicit none (type, external)

    character(len=:), allocatable :: start_path
    logical :: show_usage, show_version

    call parse_arguments(start_path, show_usage, show_version)
    if (show_usage .or. show_version) then
        if (workers_is_primary()) then
            if (show_usage) then
                call print_usage()
            else
                print '(a)', APP_NAME//' '//APP_VERSION//' ('//APP_BACKEND//' backend)'
            end if
        end if
        stop
    end if

    ! raylib logs from every thread / image; keep it to errors unless -v was given.
    call set_trace_log_level(merge(LOG_WARNING, LOG_ERROR, log_is_verbose()))
    call app_configure(start_path)
    call workers_run(app_main)
    if (workers_is_primary() .and. app_exit_status() /= 0) error stop 1

contains

    subroutine parse_arguments(path, usage, version)
        character(len=:), allocatable, intent(out) :: path
        logical, intent(out) :: usage, version
        character(len=:), allocatable :: arg
        integer :: i

        path = ''
        usage = .false.
        version = .false.
        do i = 1, argument_count()
            arg = argument(i)
            if (len(arg) == 0) cycle
            select case (arg)
            case ('-v', '--verbose')
                call log_set_verbose(.true.)
            case ('-h', '--help', '/?')
                usage = .true.
            case ('--version')
                version = .true.
            case default
                ! macOS adds -psn_... when an app is started from Finder on old systems
                if (len(arg) >= 4) then
                    if (arg(1:4) == '-psn') cycle
                end if
                path = arg
            end select
        end do
    end subroutine parse_arguments

    subroutine print_usage()
        print '(a)', APP_NAME//' '//APP_VERSION//' - fast Canon RAW (CR2/CR3) viewer and sorter for Siril'
        print '(a)', ''
        print '(a)', 'Usage:  quickraw [-v] [photo.CR2 | folder]'
        print '(a)', '        cafrun -n 4 ./quickraw [-v] [photo.CR2 | folder]    (coarray build)'
        print '(a)', ''
        print '(a)', '  photo.CR2   open this photo and browse its folder'
        print '(a)', '  folder      browse the photos in this folder'
        print '(a)', '              (nothing: start screen - drop a photo or press O)'
        print '(a)', '  -v          verbose log of decoding and cache activity'
        print '(a)', '  --version   print the version'
        print '(a)', ''
        print '(a)', 'QUICKRAW_WORKERS=n sets the number of decode threads (thread build).'
        print '(a)', 'Press ? in the window for keyboard shortcuts.'
    end subroutine print_usage

end program quickraw
