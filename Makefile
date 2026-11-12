# BSD 3-Clause License
#
# Copyright (c) 2026, Sorin Cătălin Păștiță
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# ==================================================================================================
#
# This file is part of QuickRAW - a small and fast program to view Canon RAW photos
#
# PURPOSE :
#   Build QuickRAW on GNU/Linux, FreeBSD (with gmake), macOS and Windows (MSYS2 UCRT64 / MINGW64).
#
#     make                      thread backend (default; what the releases use)
#     make BACKEND=coarray      coarray backend, built with caf, run with cafrun
#     make RELEASE=1            release build (Windows: one static .exe, no console)
#
#   raylib is compiled from lib/raylib-6.0 with JPEG support switched on
#   (raylib's default config.h leaves it off). RAYLIB=system uses -lraylib.
#
#   Packaging (AppImage / .exe / .dmg) lives in packaging/, see README.md.
#
# WRITTEN BY :
#   Sorin Cătălin Păștiță, October 2026
#
# ==================================================================================================

# GNU Make 3.81 compatible (the version macOS ships).
VERSION := $(strip $(shell cat VERSION 2>/dev/null))
comma   := ,
VERSION_NUM := $(subst .,$(comma),$(VERSION)),0

# ---- platform ------------------------------------------------------------------------------------

UNAME_S ?= $(shell uname -s 2>/dev/null)

ifeq ($(OS),Windows_NT)
    PLATFORM := windows
    EXE      := .exe
else ifeq ($(UNAME_S),Darwin)
    PLATFORM := macos
    EXE      :=
else ifeq ($(UNAME_S),FreeBSD)
    PLATFORM := freebsd
    EXE      :=
else
    PLATFORM := linux
    EXE      :=
endif

# ---- options -------------------------------------------------------------------------------------

BACKEND ?= threads
RELEASE ?= 0
RAYLIB  ?= vendored

ifeq ($(filter $(BACKEND),threads coarray),)
    $(error BACKEND must be "threads" or "coarray")
endif

ifeq ($(origin GFORTRAN),undefined)
    ifeq ($(PLATFORM),freebsd)
        # FreeBSD's gcc packages install versioned names (gfortran14, gfortran13, ...).
        GFORTRAN := $(firstword $(foreach f,gfortran gfortran16 gfortran15 gfortran14 gfortran13 \
                        gfortran12,$(if $(shell command -v $(f) 2>/dev/null),$(f))) gfortran)
    else
        GFORTRAN := gfortran
    endif
endif
CC       ?= cc
CAF      ?= caf
CAFRUN   ?= cafrun
WINDRES  ?= windres
PKG_CONFIG ?= pkg-config

ifeq ($(BACKEND),coarray)
    FC          := $(CAF)
    BACKEND_FLAGS :=
else
    FC          := $(GFORTRAN)
    BACKEND_FLAGS := -fopenmp
endif

IMAGE  ?= ./test/IMG_1800.CR2
IMAGES ?= 4

BUILD_DIR := build/$(PLATFORM)-$(BACKEND)
TARGET    := quickraw$(EXE)

# ---- flags ---------------------------------------------------------------------------------------

# Ordinary assignment so GNU Make's empty built-in FFLAGS does not win.
# Command-line overrides still work:  make FFLAGS="-O0 -g -fcheck=all"
FFLAGS = -O2 -std=f2018 -Wall -Wextra -Wno-compare-reals -Wno-function-elimination \
         -ffree-line-length-none
CFLAGS = -O2 -Wall -Wextra
CPPDEFS = -DQR_VERSION='"$(VERSION)"' -DQR_BACKEND='"$(BACKEND)"'
LDFLAGS ?=

# ---- fortran-raylib ------------------------------------------------------------------------------

# Compiled into build/ per platform, so .mod files from another compiler or OS
# that may sit in lib/fortran-raylib are never picked up.
FRAYLIB_DIR     ?= ./lib/fortran-raylib
FRAYLIB_BUILD   := build/fortran-raylib-$(PLATFORM)
FRAYLIB_MOD_DIR ?= $(FRAYLIB_BUILD)
FRAYLIB_LIB     ?= $(FRAYLIB_BUILD)/libfortran-raylib.a

# ---- raylib --------------------------------------------------------------------------------------

RAYLIB_SRC ?= ./lib/raylib-6.0/src
ifeq ($(RAYLIB),system)
    RAYLIB_LIB  :=
    RAYLIB_LINK ?= -lraylib
else
    RAYLIB_LIB  ?= build/raylib-$(PLATFORM)/libraylib.a
    RAYLIB_LINK ?= $(RAYLIB_LIB)
endif

ifeq ($(PLATFORM),windows)
    SYSTEM_LIBS := -lopengl32 -lgdi32 -lwinmm -lcomdlg32 -lshell32 -lole32 -luuid -lws2_32
else ifeq ($(PLATFORM),macos)
    SYSTEM_LIBS := -framework OpenGL -framework Cocoa -framework IOKit -framework CoreAudio \
                   -framework CoreVideo -framework AudioToolbox
else ifeq ($(PLATFORM),freebsd)
    # As raylib's own FreeBSD build: GLFW loads the X11 libraries at run time.
    SYSTEM_LIBS := -L/usr/local/lib -lGL -lpthread -lm
else
    SYSTEM_LIBS := -lGL -lm -lpthread -ldl -lrt -lX11
endif

# ---- LibRaw --------------------------------------------------------------------------------------

# LibRaw is C++: link its runtime explicitly. On macOS and FreeBSD the shared
# libraw already brings libc++, and adding GCC's libstdc++ would load a second one.
ifeq ($(filter $(PLATFORM),macos freebsd),)
    CXX_RUNTIME := -lstdc++
else
    CXX_RUNTIME :=
endif

# FreeBSD: find GCC's own libgfortran / libgomp / libgcc_s at run time
# (/usr/local/lib/gccNN), not the base system's libgcc_s.
ifeq ($(PLATFORM),freebsd)
    PLATFORM_LDFLAGS := -Wl,-rpath,$(dir $(shell $(GFORTRAN) -print-file-name=libgfortran.so 2>/dev/null))
else
    PLATFORM_LDFLAGS :=
endif
ifeq ($(RELEASE)-$(PLATFORM),1-windows)
    # MSYS2's libraw.pc omits zlib, which LibRaw's DNG decoder needs (uncompress)
    # when linking statically, so -lz is added after LibRaw's own libraries.
    LIBRAW_LIBS ?= $(shell $(PKG_CONFIG) --static --libs libraw 2>/dev/null || echo -lraw) -lz $(CXX_RUNTIME)
    RELEASE_LDFLAGS := -static -mwindows
else
    LIBRAW_LIBS ?= $(shell $(PKG_CONFIG) --libs libraw 2>/dev/null || echo -lraw) $(CXX_RUNTIME)
    RELEASE_LDFLAGS :=
endif

# ==================================================================================================
# Sources
#
#   src/platform  qr_platform.c (all OS-specific code), embedded assets, bindings
#   src/util      configuration, strings/paths, logging
#   src/photos    folder listing, sorting into Siril folders (+ undo)
#   src/loader    preview decoding, jobs, worker backends, 5-photo cache
#   src/gui       theme, widgets, image viewer, application
#   src/quickraw.f90  main program
# ==================================================================================================

# Old single-folder sources left in src/ are ignored: the subfolders come first.
vpath %.f90 src/platform src/util src/photos src/loader src/gui src
vpath %.F90 src/util
vpath %.c   src/platform

F_MODULES := m_platform m_libraw m_config m_strings m_log \
             m_photo_list m_sorting \
             m_preview m_jobs m_workers m_cache \
             m_theme m_widgets m_viewer m_app

OBJECTS := $(addprefix $(BUILD_DIR)/,$(addsuffix .o,$(F_MODULES) quickraw qr_platform qr_assets))
ifeq ($(PLATFORM),windows)
    OBJECTS += $(BUILD_DIR)/quickraw_res.o
endif

.PHONY: all clean distclean help run raylib

all: $(TARGET)

# ==================================================================================================
# Help
# ==================================================================================================

help:
	@echo "QuickRAW $(VERSION) - build ($(PLATFORM))"
	@echo ""
	@echo "  make                         thread backend (default)"
	@echo "  make BACKEND=coarray         coarray backend (caf / cafrun)"
	@echo "  make RELEASE=1               release build (Windows: static exe, no console)"
	@echo "  make RAYLIB=system           link a system-wide raylib (needs JPEG support)"
	@echo "  make -j4                     parallel build"
	@echo "  (FreeBSD: use gmake instead of make)"
	@echo ""
	@echo "Run:"
	@echo "  ./quickraw [photo.CR2 | folder]"
	@echo "  cafrun -n 4 ./quickraw [photo.CR2 | folder]     (BACKEND=coarray)"
	@echo "  make run IMAGE=/path/to/photo.CR2 [IMAGES=4]"
	@echo ""
	@echo "Packages:"
	@echo "  packaging/linux/build-appimage.sh     QuickRAW-$(VERSION)-x86_64.AppImage"
	@echo "  packaging/macos/build-dmg.sh          QuickRAW-$(VERSION)-macos-<arch>.dmg"
	@echo "  packaging/windows/build-exe.sh        QuickRAW-$(VERSION)-windows-x64.exe (MSYS2)"
	@echo ""
	@echo "  make clean / make distclean (also removes the raylib build)"

# ==================================================================================================
# Third-party libraries
# ==================================================================================================

FRAYLIB_SRC := raylib_util.f90 raylib.F90 raylib_camera.f90 raylib_math.f90 raylib_gl.f90

build/fortran-raylib-$(PLATFORM)/libfortran-raylib.a:
	@test -f "$(FRAYLIB_DIR)/src/raylib.F90" || \
	    { echo "Missing $(FRAYLIB_DIR): run packaging/fetch-deps.sh"; exit 2; }
	mkdir -p "$(FRAYLIB_BUILD)"
	for f in $(FRAYLIB_SRC); do \
	    $(GFORTRAN) -O2 -std=f2018 -J"$(FRAYLIB_BUILD)" -c "$(FRAYLIB_DIR)/src/$$f" \
	        -o "$(FRAYLIB_BUILD)/$${f%.*}.o" || exit 1; \
	done
	ar rcs $@ $(addprefix $(FRAYLIB_BUILD)/,raylib_util.o raylib.o raylib_camera.o raylib_math.o raylib_gl.o)

RAYLIB_BUILD := build/raylib-$(PLATFORM)

raylib: $(RAYLIB_LIB)

# Build a private copy so prebuilt objects in lib/raylib-6.0/src (without JPEG) are never reused.
build/raylib-$(PLATFORM)/libraylib.a:
	@test -f "$(RAYLIB_SRC)/raylib.h" || { echo "Missing $(RAYLIB_SRC): run packaging/fetch-deps.sh"; exit 2; }
	rm -rf "$(RAYLIB_BUILD)/src"
	mkdir -p "$(RAYLIB_BUILD)"
	cp -R "$(RAYLIB_SRC)" "$(RAYLIB_BUILD)/src"
	rm -f "$(RAYLIB_BUILD)"/src/*.o "$(RAYLIB_BUILD)"/src/*.a
	$(MAKE) -C "$(RAYLIB_BUILD)/src" PLATFORM=PLATFORM_DESKTOP PLATFORM_SHELL=sh \
	    RAYLIB_SRC_PATH=. RAYLIB_RELEASE_PATH=.. RAYLIB_LIBTYPE=STATIC \
	    CUSTOM_CFLAGS="-DSUPPORT_FILEFORMAT_JPG=1"

# ==================================================================================================
# QuickRAW
# ==================================================================================================

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR) $(FRAYLIB_BUILD)

$(BUILD_DIR)/%.o: %.f90 | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(BACKEND_FLAGS) -I"$(BUILD_DIR)" -I"$(FRAYLIB_MOD_DIR)" -J"$(BUILD_DIR)" -c $< -o $@

$(BUILD_DIR)/%.o: %.F90 | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(BACKEND_FLAGS) $(CPPDEFS) -I"$(BUILD_DIR)" -J"$(BUILD_DIR)" -c $< -o $@

$(BUILD_DIR)/%.o: %.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

# The worker backend is chosen here: both files define module m_workers.
$(BUILD_DIR)/m_workers.o: src/loader/m_workers_$(BACKEND).f90 | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(BACKEND_FLAGS) -I"$(BUILD_DIR)" -J"$(BUILD_DIR)" -c $< -o $@

$(BUILD_DIR)/qr_version.h: VERSION | $(BUILD_DIR)
	printf '#define QR_VERSION_STR "%s"\n#define QR_VERSION_NUM %s\n' "$(VERSION)" "$(VERSION_NUM)" > $@

$(BUILD_DIR)/quickraw_res.o: packaging/windows/quickraw.rc packaging/windows/quickraw.exe.manifest \
                             packaging/icons/quickraw.ico $(BUILD_DIR)/qr_version.h
	$(WINDRES) -I $(BUILD_DIR) -I packaging/windows -I packaging/icons $< -O coff -o $@

# Module dependencies (a module must be compiled before the files that USE it)
$(BUILD_DIR)/m_strings.o:    $(BUILD_DIR)/m_platform.o
$(BUILD_DIR)/m_photo_list.o: $(BUILD_DIR)/m_platform.o $(BUILD_DIR)/m_strings.o
$(BUILD_DIR)/m_sorting.o:    $(BUILD_DIR)/m_platform.o $(BUILD_DIR)/m_strings.o $(BUILD_DIR)/m_photo_list.o
$(BUILD_DIR)/m_preview.o:    $(BUILD_DIR)/m_libraw.o $(BUILD_DIR)/m_platform.o $(BUILD_DIR)/m_strings.o \
                             $(FRAYLIB_LIB)
$(BUILD_DIR)/m_jobs.o:       $(BUILD_DIR)/m_preview.o $(BUILD_DIR)/m_strings.o $(BUILD_DIR)/m_log.o
$(BUILD_DIR)/m_workers.o:    $(BUILD_DIR)/m_jobs.o $(BUILD_DIR)/m_platform.o $(BUILD_DIR)/m_strings.o \
                             $(BUILD_DIR)/m_log.o
$(BUILD_DIR)/m_cache.o:      $(BUILD_DIR)/m_jobs.o $(BUILD_DIR)/m_workers.o $(BUILD_DIR)/m_preview.o \
                             $(BUILD_DIR)/m_photo_list.o $(BUILD_DIR)/m_strings.o $(BUILD_DIR)/m_log.o \
                             $(FRAYLIB_LIB)
$(BUILD_DIR)/m_theme.o:      $(BUILD_DIR)/m_platform.o $(BUILD_DIR)/m_sorting.o $(BUILD_DIR)/m_log.o \
                             $(FRAYLIB_LIB)
$(BUILD_DIR)/m_widgets.o:    $(BUILD_DIR)/m_theme.o $(FRAYLIB_LIB)
$(BUILD_DIR)/m_viewer.o:     $(BUILD_DIR)/m_widgets.o $(FRAYLIB_LIB)
$(BUILD_DIR)/m_app.o:        $(BUILD_DIR)/m_theme.o $(BUILD_DIR)/m_widgets.o $(BUILD_DIR)/m_viewer.o \
                             $(BUILD_DIR)/m_cache.o $(BUILD_DIR)/m_photo_list.o \
                             $(BUILD_DIR)/m_sorting.o $(BUILD_DIR)/m_preview.o $(BUILD_DIR)/m_jobs.o \
                             $(BUILD_DIR)/m_workers.o $(BUILD_DIR)/m_strings.o \
                             $(BUILD_DIR)/m_platform.o $(BUILD_DIR)/m_config.o $(BUILD_DIR)/m_log.o \
                             $(FRAYLIB_LIB)
$(BUILD_DIR)/quickraw.o:     $(BUILD_DIR)/m_app.o $(BUILD_DIR)/m_workers.o $(BUILD_DIR)/m_platform.o \
                             $(BUILD_DIR)/m_config.o $(BUILD_DIR)/m_log.o $(FRAYLIB_LIB)
$(BUILD_DIR)/m_config.o:     VERSION

$(TARGET): $(OBJECTS) $(FRAYLIB_LIB) $(RAYLIB_LIB)
	$(FC) $(BACKEND_FLAGS) $(LDFLAGS) $(PLATFORM_LDFLAGS) $(RELEASE_LDFLAGS) -o $@ $(OBJECTS) "$(FRAYLIB_LIB)" \
	    $(RAYLIB_LINK) $(LIBRAW_LIBS) $(SYSTEM_LIBS)

run: $(TARGET)
	@test -e "$(IMAGE)" || { echo "Error: not found: $(IMAGE)"; exit 2; }
ifeq ($(BACKEND),coarray)
	@test "$(IMAGES)" -ge 2 2>/dev/null || { echo "Error: IMAGES must be at least 2."; exit 2; }
	$(CAFRUN) -n $(IMAGES) ./$(TARGET) "$(IMAGE)"
else
	./$(TARGET) "$(IMAGE)"
endif

clean:
	rm -rf build/$(PLATFORM)-threads build/$(PLATFORM)-coarray $(TARGET)

distclean: clean
	rm -rf build dist
