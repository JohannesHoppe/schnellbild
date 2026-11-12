// The system's libarchive, looked up in /usr/lib/libarchive.2.dylib itself
// (see CArchives.h for why not by link). Each function is resolved once; if
// the library or a function is missing, the call fails the way libarchive
// reports a failure (NULL, ARCHIVE_FATAL), and the archive counts as unreadable.
#include <dlfcn.h>
#include "include/CArchives.h"

namespace {

void *systemLibarchive() {
    static void *handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_LAZY | RTLD_LOCAL);
    return handle;
}

template <typename Function> Function resolve(const char *name) {
    void *handle = systemLibarchive();
    return handle ? reinterpret_cast<Function>(dlsym(handle, name)) : nullptr;
}

}

#define SB_FORWARD(result, name, parameters, arguments, failure)          \
    extern "C" result sb_##name parameters {                                \
        static const auto function = resolve<result(*) parameters>(#name);  \
        return function ? function arguments : failure;                     \
    }

SB_FORWARD(struct archive *, archive_read_new, (void), (), nullptr)
SB_FORWARD(int, archive_read_support_format_zip_seekable, (struct archive *a), (a), SB_ARCHIVE_FATAL)
SB_FORWARD(int, archive_read_support_format_zip_streamable, (struct archive *a), (a), SB_ARCHIVE_FATAL)
SB_FORWARD(int, archive_read_support_format_7zip, (struct archive *a), (a), SB_ARCHIVE_FATAL)
SB_FORWARD(int, archive_read_add_passphrase, (struct archive *a, const char *p), (a, p), SB_ARCHIVE_FATAL)
SB_FORWARD(int, archive_read_open_filenames, (struct archive *a, const char **f, size_t b), (a, f, b), SB_ARCHIVE_FATAL)
SB_FORWARD(int, archive_read_next_header, (struct archive *a, struct archive_entry **e), (a, e), SB_ARCHIVE_FATAL)
SB_FORWARD(ssize_t, archive_read_data, (struct archive *a, void *b, size_t s), (a, b, s), SB_ARCHIVE_FATAL)
SB_FORWARD(int, archive_read_data_skip, (struct archive *a), (a), SB_ARCHIVE_FATAL)
SB_FORWARD(int, archive_read_free, (struct archive *a), (a), SB_ARCHIVE_FATAL)
SB_FORWARD(const char *, archive_error_string, (struct archive *a), (a), nullptr)
SB_FORWARD(const char *, archive_entry_pathname_utf8, (struct archive_entry *e), (e), nullptr)
SB_FORWARD(const char *, archive_entry_pathname, (struct archive_entry *e), (e), nullptr)
SB_FORWARD(int64_t, archive_entry_size, (struct archive_entry *e), (e), 0)
SB_FORWARD(int, archive_entry_size_is_set, (struct archive_entry *e), (e), 0)
SB_FORWARD(mode_t, archive_entry_filetype, (struct archive_entry *e), (e), 0)
SB_FORWARD(time_t, archive_entry_mtime, (struct archive_entry *e), (e), 0)
SB_FORWARD(int, archive_entry_is_encrypted, (struct archive_entry *e), (e), 0)
