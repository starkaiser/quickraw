/*
 * BSD 3-Clause License
 *
 * Copyright (c) 2026, Sorin Cătălin Păștiță
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products derived from
 *    this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * ==================================================================================================
 *
 * This file is part of QuickRAW - a small and fast program to view Canon RAW photos
 *
 * PURPOSE :
 *   The only operating-system specific code in QuickRAW. Every function has a
 *   plain C signature (UTF-8 char*, int, void*) so the Fortran side binds to it
 *   with BIND(C) and stays identical on GNU/Linux, macOS and Windows.
 *
 *   On Windows all paths are UTF-8 on the Fortran side and converted to UTF-16
 *   here, so folders with non-ASCII names work. LibRaw's char* API uses the
 *   ANSI code page on Windows, so qr_libraw_open() takes care of that too.
 *
 * WRITTEN BY :
 *   Sorin Cătălin Păștiță, November 2026
 *
 * ==================================================================================================
 */

#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#  define _GNU_SOURCE 1
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#  define _DARWIN_C_SOURCE 1
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#  include <commdlg.h>
#  include <shellapi.h>
#else
#  include <dirent.h>
#  include <errno.h>
#  include <fcntl.h>
#  include <sys/stat.h>
#  include <sys/types.h>
#  include <unistd.h>
#  if defined(__linux__)
#    include <sys/syscall.h>
#  endif
#endif

/* Results of qr_rename_noreplace (mirrored in m_platform.f90) */
#define QR_RENAME_OK      0
#define QR_RENAME_EXISTS  1
#define QR_RENAME_NO_SRC  2
#define QR_RENAME_FAILED  3

/* LibRaw C API (declared here so no libraw.h is needed at build time) */
extern int libraw_open_file(void *lr, const char *path);
extern int libraw_open_buffer(void *lr, const void *buffer, size_t size);

/* -------------------------------------------------------------------------------------------- */

/** 1 = GNU/Linux (and other Unix), 2 = macOS, 3 = Windows */
int qr_platform(void)
{
#if defined(_WIN32)
    return 3;
#elif defined(__APPLE__)
    return 2;
#else
    return 1;
#endif
}

void qr_free(void *p)
{
    free(p);
}

void qr_sleep_ms(int ms)
{
    if (ms <= 0) return;
#if defined(_WIN32)
    Sleep((DWORD)ms);
#else
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) { }
#endif
}

/** Local time as 'YYYY-MM-DD  HH:MM:SS'. Returns the length, 0 on failure. */
int qr_format_time(long long epoch, char *out, int out_len)
{
    struct tm tm_local;
    time_t t = (time_t)epoch;
    size_t n;
    if (out_len <= 0 || epoch <= 0) return 0;
#if defined(_WIN32)
    if (localtime_s(&tm_local, &t) != 0) return 0;
#else
    if (localtime_r(&t, &tm_local) == NULL) return 0;
#endif
    n = strftime(out, (size_t)out_len, "%Y-%m-%d  %H:%M:%S", &tm_local);
    return (int)n;
}

/* ============================================================================================ */
/* Windows UTF-8 <-> UTF-16 helpers                                                             */
/* ============================================================================================ */

#if defined(_WIN32)
static wchar_t *widen(const char *utf8)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    wchar_t *w;
    if (n <= 0) return NULL;
    w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, n);
    return w;
}

/** Returns the UTF-8 length without the terminator, or -1 if out is too small. */
static int narrow(const wchar_t *w, char *out, int out_len)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0 || n > out_len) return -1;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, out, out_len, NULL, NULL);
    return n - 1;
}
#endif

/* ============================================================================================ */
/* Files and folders                                                                            */
/* ============================================================================================ */

int qr_exists(const char *path)
{
#if defined(_WIN32)
    wchar_t *w = widen(path);
    DWORD attr;
    if (!w) return 0;
    attr = GetFileAttributesW(w);
    free(w);
    return attr != INVALID_FILE_ATTRIBUTES;
#else
    struct stat st;
    return stat(path, &st) == 0;
#endif
}

int qr_is_dir(const char *path)
{
#if defined(_WIN32)
    wchar_t *w = widen(path);
    DWORD attr;
    if (!w) return 0;
    attr = GetFileAttributesW(w);
    free(w);
    return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
#endif
}

/** Create a folder. Returns 0 if it exists afterwards, -1 otherwise. */
int qr_mkdir(const char *path)
{
#if defined(_WIN32)
    wchar_t *w = widen(path);
    if (!w) return -1;
    CreateDirectoryW(w, NULL);
    free(w);
#else
    mkdir(path, 0755);
#endif
    return qr_is_dir(path) ? 0 : -1;
}

/** Rename that never overwrites an existing file. */
int qr_rename_noreplace(const char *from, const char *to)
{
    if (!qr_exists(from)) return QR_RENAME_NO_SRC;
    if (qr_exists(to)) return QR_RENAME_EXISTS;

#if defined(_WIN32)
    {
        wchar_t *wf = widen(from), *wt = widen(to);
        BOOL ok = FALSE;
        DWORD err = 0;
        if (wf && wt) {
            /* Without MOVEFILE_REPLACE_EXISTING, MoveFileExW fails if 'to' exists. */
            ok = MoveFileExW(wf, wt, 0);
            if (!ok) err = GetLastError();
        }
        free(wf);
        free(wt);
        if (ok) return QR_RENAME_OK;
        if (err == ERROR_ALREADY_EXISTS || err == ERROR_FILE_EXISTS) return QR_RENAME_EXISTS;
        return QR_RENAME_FAILED;
    }
#else
    {
        int rc = -1;
#  if defined(__linux__) && defined(SYS_renameat2)
        rc = (int)syscall(SYS_renameat2, AT_FDCWD, from, AT_FDCWD, to, 1 /* RENAME_NOREPLACE */);
#  elif defined(__APPLE__)
        rc = renamex_np(from, to, RENAME_EXCL);
#  else
        errno = ENOSYS;
#  endif
        if (rc == 0) return QR_RENAME_OK;
        if (errno == EEXIST) return QR_RENAME_EXISTS;
        if (errno != EINVAL && errno != ENOSYS && errno != ENOTSUP) return QR_RENAME_FAILED;
        /* Filesystem without atomic no-replace support (FUSE, network, exFAT on
           some kernels): the target was free a moment ago, fall back to rename(). */
        if (qr_exists(to)) return QR_RENAME_EXISTS;
        return rename(from, to) == 0 ? QR_RENAME_OK : QR_RENAME_FAILED;
    }
#endif
}

/* ---- directory listing ----------------------------------------------------------------------- */

typedef struct qr_dir {
#if defined(_WIN32)
    HANDLE handle;
    WIN32_FIND_DATAW data;
    int have_entry;
#else
    DIR *dir;
    char *path;
#endif
} qr_dir;

/** Start listing a folder. Returns NULL if it cannot be opened. */
void *qr_dir_open(const char *path)
{
    qr_dir *d = (qr_dir *)calloc(1, sizeof(qr_dir));
    if (!d) return NULL;
#if defined(_WIN32)
    {
        size_t n = strlen(path);
        char *pattern = (char *)malloc(n + 3);
        wchar_t *w;
        if (!pattern) { free(d); return NULL; }
        memcpy(pattern, path, n);
        if (n > 0 && path[n - 1] != '\\' && path[n - 1] != '/') pattern[n++] = '\\';
        pattern[n++] = '*';
        pattern[n] = '\0';
        w = widen(pattern);
        free(pattern);
        if (!w) { free(d); return NULL; }
        d->handle = FindFirstFileW(w, &d->data);
        free(w);
        if (d->handle == INVALID_HANDLE_VALUE) { free(d); return NULL; }
        d->have_entry = 1;
    }
#else
    d->dir = opendir(path);
    if (!d->dir) { free(d); return NULL; }
    d->path = strdup(path);
#endif
    return d;
}

/** Next entry (never "." or ".."). Returns 1 and fills name/is_dir, or 0 at the end.
    Names that do not fit in name_len bytes are skipped. */
int qr_dir_next(void *handle, char *name, int name_len, int *is_dir)
{
    qr_dir *d = (qr_dir *)handle;
    if (!d) return 0;
#if defined(_WIN32)
    while (d->have_entry) {
        int n = narrow(d->data.cFileName, name, name_len);
        int dir = (d->data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        d->have_entry = FindNextFileW(d->handle, &d->data) ? 1 : 0;
        if (n <= 0) continue;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        *is_dir = dir;
        return 1;
    }
    return 0;
#else
    for (;;) {
        struct dirent *e = readdir(d->dir);
        size_t n;
        if (!e) return 0;
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        n = strlen(e->d_name);
        if ((int)n >= name_len) continue;
        memcpy(name, e->d_name, n + 1);
#  if defined(DT_DIR)
        if (e->d_type == DT_DIR) { *is_dir = 1; return 1; }
        if (e->d_type == DT_REG) { *is_dir = 0; return 1; }
#  endif
        {   /* DT_UNKNOWN or a symlink: ask the filesystem */
            size_t m = strlen(d->path);
            char *full = (char *)malloc(m + n + 2);
            if (!full) { *is_dir = 0; return 1; }
            memcpy(full, d->path, m);
            full[m] = '/';
            memcpy(full + m + 1, e->d_name, n + 1);
            *is_dir = qr_is_dir(full);
            free(full);
            return 1;
        }
    }
#endif
}

void qr_dir_close(void *handle)
{
    qr_dir *d = (qr_dir *)handle;
    if (!d) return;
#if defined(_WIN32)
    FindClose(d->handle);
#else
    closedir(d->dir);
    free(d->path);
#endif
    free(d);
}

/* ============================================================================================ */
/* Command line                                                                                 */
/* ============================================================================================ */

/** Number of arguments (without the program name). -1 means: use the Fortran
    intrinsics, which already give UTF-8 on Linux and macOS. */
int qr_argument_count(void)
{
#if defined(_WIN32)
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return -1;
    LocalFree(argv);
    return argc - 1;
#else
    return -1;
#endif
}

/** Argument i (1-based) as UTF-8. Returns its length, or -1. */
int qr_argument(int i, char *out, int out_len)
{
#if defined(_WIN32)
    int argc = 0, n = -1;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return -1;
    if (i >= 1 && i < argc) n = narrow(argv[i], out, out_len);
    LocalFree(argv);
    return n;
#else
    (void)i; (void)out; (void)out_len;
    return -1;
#endif
}

/* ============================================================================================ */
/* LibRaw                                                                                       */
/* ============================================================================================ */

/** libraw_open_file() with UTF-8 paths on every platform. When a memory buffer
    had to be used, *owned receives it and must be released with qr_free()
    after libraw_close(). */
int qr_libraw_open(void *lr, const char *path, void **owned)
{
    *owned = NULL;
#if defined(_WIN32)
    {
        const unsigned char *p;
        int ascii = 1;
        wchar_t *w;
        for (p = (const unsigned char *)path; *p; ++p) if (*p >= 0x80) { ascii = 0; break; }
        if (ascii) return libraw_open_file(lr, path);

        w = widen(path);
        if (!w) return -1;

        /* 1) The 8.3 short name is pure ANSI when short names are enabled. */
        {
            wchar_t shortw[MAX_PATH];
            char ansi[MAX_PATH * 2];
            BOOL lossy = FALSE;
            DWORD n = GetShortPathNameW(w, shortw, MAX_PATH);
            if (n > 0 && n < MAX_PATH &&
                WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, shortw, -1, ansi, sizeof ansi,
                                    NULL, &lossy) > 0 && !lossy) {
                free(w);
                return libraw_open_file(lr, ansi);
            }
        }

        /* 2) Read the whole file and let LibRaw parse it from memory. */
        {
            FILE *f = _wfopen(w, L"rb");
            long long size;
            void *buffer;
            int rc;
            free(w);
            if (!f) return -1;
            _fseeki64(f, 0, SEEK_END);
            size = _ftelli64(f);
            _fseeki64(f, 0, SEEK_SET);
            if (size <= 0) { fclose(f); return -1; }
            buffer = malloc((size_t)size);
            if (!buffer) { fclose(f); return -1; }
            if (fread(buffer, 1, (size_t)size, f) != (size_t)size) {
                fclose(f);
                free(buffer);
                return -1;
            }
            fclose(f);
            rc = libraw_open_buffer(lr, buffer, (size_t)size);
            if (rc == 0) *owned = buffer; else free(buffer);
            return rc;
        }
    }
#else
    return libraw_open_file(lr, path);
#endif
}

/* ============================================================================================ */
/* Native "open photo" dialog                                                                   */
/* ============================================================================================ */

#if !defined(_WIN32)
/** Run a command and read one line of output into out. Returns the length or -1. */
static int read_command_line(const char *command, char *out, int out_len)
{
    FILE *p = popen(command, "r");
    size_t n;
    int status;
    if (!p) return -1;
    if (!fgets(out, out_len, p)) out[0] = '\0';
    status = pclose(p);
    n = strlen(out);
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r')) out[--n] = '\0';
    if (status == -1) return -1;
    return (int)n;
}
#endif

/** Ask the user for a photo. Returns the UTF-8 path length, 0 if cancelled,
    -1 if no dialog is available on this system. */
int qr_open_file_dialog(char *out, int out_len)
{
    if (out_len <= 0) return -1;
    out[0] = '\0';
#if defined(_WIN32)
    {
        wchar_t file[4096] = L"";
        OPENFILENAMEW ofn;
        memset(&ofn, 0, sizeof ofn);
        ofn.lStructSize = sizeof ofn;
        ofn.hwndOwner = GetActiveWindow();
        ofn.lpstrFilter = L"Canon RAW photos (*.cr2, *.cr3)\0*.cr2;*.cr3\0All files\0*.*\0";
        ofn.lpstrFile = file;
        ofn.nMaxFile = (DWORD)(sizeof file / sizeof file[0]);
        ofn.lpstrTitle = L"Open a photo - QuickRAW";
        ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER;
        if (!GetOpenFileNameW(&ofn)) return 0;
        return narrow(file, out, out_len) > 0 ? (int)strlen(out) : 0;
    }
#elif defined(__APPLE__)
    {
        int n = read_command_line(
            "/usr/bin/osascript -e 'POSIX path of (choose file with prompt \"Open a photo - QuickRAW\")' "
            "2>/dev/null", out, out_len);
        return n < 0 ? -1 : n;
    }
#else
    {
        int n;
        if (system("command -v zenity >/dev/null 2>&1") == 0) {
            n = read_command_line(
                "zenity --file-selection --title='Open a photo - QuickRAW' "
                "--file-filter='Canon RAW | *.cr2 *.CR2 *.cr3 *.CR3' --file-filter='All files | *' "
                "2>/dev/null", out, out_len);
            return n < 0 ? -1 : n;
        }
        if (system("command -v kdialog >/dev/null 2>&1") == 0) {
            n = read_command_line(
                "kdialog --title 'Open a photo - QuickRAW' --getopenfilename . "
                "'*.cr2 *.CR2 *.cr3 *.CR3|Canon RAW' 2>/dev/null", out, out_len);
            return n < 0 ? -1 : n;
        }
        return -1;
    }
#endif
}
