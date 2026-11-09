// What Swift calls to read archives: UnRAR (through rar_shim.cpp, compiled
// with the vendored UnRAR source) and the system's libarchive (macOS ships
// the library but no headers, so the few functions used are declared here,
// as in libarchive's archive.h and archive_entry.h).
#ifndef SCHNELLBILD_CARCHIVES_H
#define SCHNELLBILD_CARCHIVES_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: UnRAR

typedef struct SBRar SBRar;

typedef struct {
    char name[4096];          // UTF-8, '/'-separated
    uint64_t size;            // unpacked
    int64_t modified;         // Unix time, 0 when unknown
    int is_directory;
    int is_encrypted;
    int split_before;         // continues from the previous volume
    int split_after;          // continues in the next volume
} SBRarEntry;

/// Receives an entry's data; returns nonzero to go on, zero to stop.
typedef int (*SBRarData)(void *context, const uint8_t *bytes, size_t count);

/// Opens `path` (the first volume) for reading; `password` may be NULL.
/// `list_only` reads the names without unpacking (skipping is cheap then,
/// also in solid archives). Returns NULL with an UnRAR error code in
/// `result`; `password_asked` tells whether opening needed a password
/// (encrypted names).
SBRar *sb_rar_open(const char *path, const char *password, int list_only, int *result, int *password_asked);
/// The next entry: 0, 10 at the end, or an UnRAR error code.
int sb_rar_next(SBRar *rar, SBRarEntry *entry);
/// The current entry's data through `data`; 0 or an UnRAR error code.
int sb_rar_read(SBRar *rar, SBRarData data, void *context);
/// Past the current entry without unpacking it (where the format allows).
int sb_rar_skip(SBRar *rar);
/// A later volume wasn't there (not downloaded yet, or missing).
int sb_rar_volume_missing(const SBRar *rar);
/// The archive asked for a password (the names or the data are encrypted).
int sb_rar_password_asked(const SBRar *rar);
/// The archive's names are encrypted too.
int sb_rar_headers_encrypted(const SBRar *rar);
void sb_rar_close(SBRar *rar);

// MARK: libarchive (system)

struct archive;
struct archive_entry;

#define SB_ARCHIVE_EOF 1
#define SB_ARCHIVE_OK 0
#define SB_ARCHIVE_WARN (-20)
#define SB_ARCHIVE_FAILED (-25)
#define SB_ARCHIVE_FATAL (-30)
#define SB_AE_IFDIR 0040000
#define SB_AE_IFMT 0170000

struct archive *archive_read_new(void);
int archive_read_support_format_zip_seekable(struct archive *);
int archive_read_support_format_zip_streamable(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filenames(struct archive *, const char **filenames, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

#ifdef __cplusplus
}
#endif

#endif
