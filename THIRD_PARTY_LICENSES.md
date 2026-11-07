# Third-party components

The release packages contain these components. Their licenses travel with the
release; this list is a summary, not legal advice.

| Component | Used for | License |
|---|---|---|
| [raylib](https://www.raylib.com) 6.0 | window, input, OpenGL drawing, JPEG decoding (stb_image) | zlib/libpng |
| [fortran-raylib](https://github.com/interkosmos/fortran-raylib) | Fortran bindings to raylib | ISC |
| [LibRaw](https://www.libraw.org) | reading Canon CR2/CR3 files | LGPL-2.1 or CDDL-1.0 (dual) |
| [Little CMS 2](https://www.littlecms.com) | LibRaw dependency | MIT |
| [libjpeg-turbo](https://libjpeg-turbo.org) | LibRaw dependency | IJG / BSD-3-Clause / zlib |
| [zlib](https://zlib.net) | LibRaw dependency | zlib |
| [Inter](https://rsms.me/inter/) font (subset, embedded) | user interface text | SIL Open Font License 1.1 (`assets/fonts/LICENSE-Inter.txt`) |
| GCC runtime: libgfortran, libgomp, libquadmath | Fortran and OpenMP runtime | GPL-3.0 with the GCC Runtime Library Exception |
| MinGW-w64 runtime (Windows build) | C runtime support | ZPL-2.1 / public domain |

The Windows `.exe` links LibRaw statically, so LibRaw is used there under its
CDDL-1.0 option. The AppImage and the macOS app ship LibRaw as a separate shared
library.
