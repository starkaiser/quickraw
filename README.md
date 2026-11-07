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

## License

QuickRAW is BSD 3-Clause licensed (`LICENSE`). Bundled components are listed in
`THIRD_PARTY_LICENSES.md`.
