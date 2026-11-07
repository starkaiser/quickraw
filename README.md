# QuickRAW

A small, fast viewer for Canon RAW photos (CR2 / CR3), written in modern Fortran
with [raylib](https://www.raylib.com/). It is built for sorting an
astrophotography session into the folders [Siril](https://siril.org/) expects.

It runs on **GNU/Linux, Windows and macOS**. Previews are decoded in the
background, and the two photos on either side of the current one are always
ready, so stepping through a session is instant.

## Download and run

| System | Package | How to start |
|---|---|---|
| Windows 10/11 x64 | `QuickRAW-<version>-windows-x64.exe` | double-click; one file, nothing to install |
| Linux x86_64 | `QuickRAW-<version>-x86_64.AppImage` | `chmod +x` it, then double-click or run it |
| macOS (Apple Silicon / Intel) | `QuickRAW-<version>-macos-<arch>.dmg` | open, drag QuickRAW to Applications |

Open photos by dropping a photo or a folder on the window, by pressing **O**,
or from the command line:

```
quickraw IMG_0001.CR2        # this photo, browse its folder
quickraw /path/to/session    # a folder
quickraw -v ...              # log decoding and cache activity
```

The macOS app is ad-hoc signed, not notarized. The first time, right-click it
and choose **Open**. On macOS 15 you may instead need *System Settings → Privacy
& Security → Open Anyway*. The app needs the macOS version it was built on, or
a newer one.

## Keys

| Key | Action |
|---|---|
| ← / → | previous / next photo (hold to scroll) |
| Home / End | first / last photo |
| O | open a photo (or drop one on the window) |
| **L** | move to `lights/` |
| **D** | move to `darks/` |
| **F** | move to `flats/` |
| **B** | move to `biases/` |
| **Delete** (Mac: delete ⌫) | move to `delete_items/` |
| Ctrl Z (Mac: Cmd Z) or U | undo the last move (up to 256 moves) |
| Z, double-click | toggle fit / 100 % |
| 0 / 1 | fit / 100 % |
| + / − , mouse wheel | zoom (the wheel zooms at the cursor) |
| drag | pan |
| H | histogram |
| Tab | hide / show the bars |
| F11 | full screen |
| ? or F1 | help |
| Esc | close help, or quit |

Keys are handled in the order you press them, even when the computer is busy.
"L, then →" always files the photo that was on screen.

The category buttons in the bottom bar can be clicked too, and each shows how
many photos its folder already holds.

Folders are created next to the photos the first time they are needed. Files
are never overwritten: if a name already exists in the target folder, a suffix
is added (`IMG_0001_1.CR2`). The resulting layout is what Siril's
preprocessing scripts expect as their working directory:

```
session/
  lights/  darks/  flats/  biases/  delete_items/
```

Once you zoom in, the zoom and position stay the same as you step through the
photos, which makes it easy to compare the same stars across frames (tracking,
focus, clouds). Press 0 or Z to go back to fit.

## Build from source

Two worker backends share all the other code:

| | `BACKEND=threads` (default) | `BACKEND=coarray` |
|---|---|---|
| decoders run as | OpenMP threads in one process | coarray images (OpenCoarrays) |
| compiler | gfortran ≥ 12 | `caf` |
| start | `./quickraw ...` | `cafrun -n 4 ./quickraw ...` |
| used for | the release packages | development on Linux |

raylib is compiled from `lib/raylib-6.0` with JPEG support switched on
(raylib's default `config.h` leaves it off). fortran-raylib is compiled from
`lib/fortran-raylib`. Both are built into `build/`, separately for each OS. If
`lib/` is missing them, `packaging/fetch-deps.sh` downloads the pinned versions.

**Linux** (Debian / Ubuntu / Mint):

```
sudo apt install gfortran gcc make pkg-config libraw-dev \
     libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl1-mesa-dev
make -j4                       # thread backend
make -j4 BACKEND=coarray       # coarray backend (needs OpenCoarrays)
```

**macOS** (Homebrew): `brew install gcc libraw pkg-config`, then `make -j4 CC=clang`.

**Windows** ([MSYS2](https://www.msys2.org), *UCRT64* shell):

```
pacman -S make git mingw-w64-ucrt-x86_64-{gcc,gcc-fortran,pkgconf,libraw,lcms2,libjpeg-turbo,zlib}
make -j4
```

Other options: `make help`, `make RELEASE=1`, `make RAYLIB=system` (link an
installed raylib, which must have JPEG support), and `QUICKRAW_WORKERS=n`
(number of decode threads; the default is CPU cores − 1, from 1 to 4).

## Release packages

| Script | Run on | Output in `dist/` |
|---|---|---|
| `packaging/linux/build-appimage.sh` | Linux | `QuickRAW-<version>-x86_64.AppImage` |
| `packaging/windows/build-exe.sh` | Windows, MSYS2 UCRT64 shell | `QuickRAW-<version>-windows-x64.exe` |
| `packaging/macos/build-dmg.sh` | macOS with Homebrew | `QuickRAW-<version>-macos-<arch>.dmg` |

The version comes from the `VERSION` file.

* **Windows:** everything is linked statically (gfortran and OpenMP runtimes,
  LibRaw, raylib, fonts, icon). The script stops if the `.exe` would need any
  DLL that does not ship with Windows.
* **Linux:** linuxdeploy bundles LibRaw and the GCC runtime. Build on the
  oldest distribution you want to support, because the AppImage runs on that
  glibc or a newer one.
* **macOS:** dylibbundler copies the Homebrew libraries into the `.app`. To
  sign and notarize, set `CODESIGN_IDENTITY` and `NOTARY_PROFILE` (see the
  script header).

**GitHub Actions** (`.github/workflows/release.yml`) builds all four packages
on every push. Pushing a tag publishes them on a GitHub Release:

```
echo 1.0.1 > VERSION && git commit -am "QuickRAW 1.0.1" && git tag v1.0.1 && git push --tags
```

`lib/fortran-raylib` is a git clone with its own `.git` folder. Either delete
that folder before committing `lib/`, or leave `lib/` out of the repository;
CI fetches both libraries when they are missing.

## Source layout

```
src/
  quickraw.f90            main program
  platform/
    qr_platform.c         the only OS-specific code (folders, rename, UTF-8 paths, dialogs)
    qr_assets.c           embedded fonts and icon (tools/embed_assets.py)
    m_platform.f90        Fortran interface to qr_platform.c
    m_libraw.f90          LibRaw bindings
  util/
    m_config.F90          name, version, backend
    m_strings.f90         strings, paths, number/EXIF formatting
    m_log.f90             console logging (-v)
  photos/
    m_photo_list.f90      photos in the folder, navigation
    m_sorting.f90         move to lights/darks/flats/biases/delete_items, undo
  loader/
    m_preview.f90         decoding: embedded JPEG, scale, histogram
    m_jobs.f90            a decode job, shared by both backends
    m_workers_threads.f90 backend: OpenMP threads
    m_workers_coarray.f90 backend: coarray images
    m_cache.f90           5-photo look-ahead cache
  gui/
    m_theme.f90           colours, fonts, metrics, HiDPI
    m_widgets.f90         text, panels, key caps, spinner
    m_viewer.f90          fit / zoom / pan
    m_app.f90             window, input, layout, drawing
packaging/                icons, scripts and metadata for the three platforms
assets/fonts/             Inter (SIL Open Font License), subset to Latin
```

### How the cache keeps the UI responsive

* Slots are keyed by path and never moved. Stepping right turns
  `[n-2 .. n+2]` into `[n-1 .. n+3]`, so only one slot gets new work.
* Work runs in priority order: current, +1, −1, +2, −2.
* Workers check for cancellation between decode stages, so scrolling quickly
  past photos does not keep the workers busy with images you have already left.
* Pixels are copied from the workers under a time budget of about 6 ms per
  frame. The current photo's texture is uploaded before the frame is drawn.
  Neighbours are uploaded after it, at most one per frame.
* Previews are scaled to the monitor's long side (1024–3072 px) and get
  mipmaps, so a downscaled view stays smooth.
* When all five photos are ready and nothing is animating, the window sleeps
  until the next input event, so it uses almost no CPU while you look at a photo.
  Idle workers sleep-poll every millisecond instead of spinning.

## License

QuickRAW is BSD 3-Clause licensed (`LICENSE`). Bundled components are listed in
`THIRD_PARTY_LICENSES.md`.
