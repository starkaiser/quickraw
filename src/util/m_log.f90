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
!   Console logging. Errors are always printed; progress messages only when
!   QuickRAW runs with -v / --verbose. Every line is tagged with the thread or
!   coarray image that wrote it ([gui] or [worker N]).
!
! WRITTEN BY :
!   Sorin Cătălin Păștiță, October 2026
!
! ==================================================================================================

module m_log

    use, intrinsic :: iso_fortran_env, only: output_unit, error_unit

    implicit none (type, external)

    private

    logical, save :: verbose = .false.
    character(len=16), save :: tag = '[gui]'
    !$omp threadprivate(tag)

    public :: log_set_verbose, log_is_verbose, log_set_tag, log_message, log_failure

contains

    subroutine log_set_verbose(flag)
        logical, intent(in) :: flag
        verbose = flag
    end subroutine log_set_verbose

    logical function log_is_verbose()
        log_is_verbose = verbose
    end function log_is_verbose

    !> Name printed in front of this thread's / image's messages, e.g. '[worker 2]'.
    subroutine log_set_tag(text)
        character(len=*), intent(in) :: text
        tag = text
    end subroutine log_set_tag

    subroutine log_message(message)
        character(len=*), intent(in) :: message
        if (.not. verbose) return
        write(output_unit, '(a,1x,a)') trim(tag), trim(message)
        flush(output_unit)
    end subroutine log_message

    subroutine log_failure(message)
        character(len=*), intent(in) :: message
        write(error_unit, '(a,1x,a)') trim(tag), trim(message)
        flush(error_unit)
    end subroutine log_failure

end module m_log
