// A small C face for UnRAR's DLL interface (unrar/dll.hpp): UTF-8 names,
// data through a callback, passwords and volumes answered here.
//
// UnRAR keeps its error state (ErrHandler) per thread here (fetch_unrar.sh
// makes it thread_local) and returns it after every header and every file:
// a warning from an earlier archive on the same thread (an unfinished
// download) would make the next call fail, so the state is cleared before
// each call. A handle also keeps the code of the last file it processed
// and returns it with the next header: a header read whole (it has a name)
// that comes with exactly that code counts as read, except a password
// error where the headers themselves are encrypted; any other code (a
// damaged header) stands. A file's
// data is checked against its CRC32 here where it has one.
#include <wchar.h>
#include <string.h>
#include <string>
#include <new>
#include "unrar/rar.hpp"
#include "include/CArchives.h"


// A running CRC32 over a file's data, through UnRAR's own (fast) CRC32,
// which leaves the start and end inversion to its caller
static uint32_t crc32Update(uint32_t crc, const uint8_t *bytes, size_t count) {
    return ~CRC32(~crc, bytes, count);
}

struct SBRar {
    HANDLE handle = nullptr;
    std::wstring password;
    bool hasPassword = false;
    bool passwordAsked = false;
    bool volumeMissing = false;
    bool headersEncrypted = false;
    bool solid = false;
    bool volume = false;
    SBRarData data = nullptr;
    void *context = nullptr;
    bool stopped = false;
    // What the last RARProcessFile returned: UnRAR hands it back with the
    // next header
    int lastProcessed = ERAR_SUCCESS;
    // The current entry, for checking its data
    uint32_t expectedCRC = 0;
    bool checkCRC = false;
    uint64_t expectedSize = 0;
    bool encrypted = false;
    uint32_t crc = 0;
    uint64_t received = 0;
};

// UTF-8 ⇄ the wide strings UnRAR takes, with UnRAR's own converters
static std::wstring fromUTF8(const char *s) {
    std::wstring out;
    UtfToWide(s, out);
    return out;
}

static void toUTF8(const wchar_t *w, char *out, size_t size) {
    WideToUtf(w, out, size);
}

static int CALLBACK callback(UINT message, LPARAM user, LPARAM p1, LPARAM p2) {
    SBRar *rar = (SBRar *)user;
    switch (message) {
    case UCM_CHANGEVOLUMEW:
    case UCM_CHANGEVOLUME:
        // Asked for a volume that isn't there: stop with what was read.
        if (p2 == RAR_VOL_ASK) { rar->volumeMissing = true; return -1; }
        return 1;
    case UCM_PROCESSDATA:
        if (!rar->data) return 1;
        rar->crc = crc32Update(rar->crc, (const uint8_t *)p1, (size_t)p2);
        rar->received += (uint64_t)p2;
        if (rar->data(rar->context, (const uint8_t *)p1, (size_t)p2)) return 1;
        rar->stopped = true;
        return -1;
    case UCM_NEEDPASSWORDW:
        rar->passwordAsked = true;
        if (!rar->hasPassword || p2 <= 0) return -1;
        wcsncpy((wchar_t *)p1, rar->password.c_str(), (size_t)p2 - 1);
        ((wchar_t *)p1)[p2 - 1] = 0;
        return 1;
    case UCM_NEEDPASSWORD:
        return -1;   // the wide version above answers
    default:
        return 0;
    }
}

extern "C" SBRar *sb_rar_open(const char *path, const char *password, int list_only, int *result, int *password_asked) {
    SBRar *rar = new (std::nothrow) SBRar();
    if (!rar) { *result = ERAR_NO_MEMORY; return nullptr; }
    if (password) { rar->password = fromUTF8(password); rar->hasPassword = true; }
    std::wstring widePath = fromUTF8(path);
    RAROpenArchiveDataEx data;
    memset(&data, 0, sizeof(data));
    data.ArcNameW = (wchar_t *)widePath.c_str();
    // RAR_OM_LIST would skip the headers of files continued from an
    // earlier volume by calling itself once per header (a crafted archive
    // of many such headers overflows the stack); the caller skips them
    data.OpenMode = list_only ? RAR_OM_LIST_INCSPLIT : RAR_OM_EXTRACT;
    data.Callback = callback;
    data.UserData = (LPARAM)rar;
    {
        ErrHandler.Clean();
        rar->handle = RAROpenArchiveEx(&data);
    }
    *result = (int)data.OpenResult;
    *password_asked = rar->passwordAsked;
    if (!rar->handle || data.OpenResult != ERAR_SUCCESS) {
        if (rar->handle) RARCloseArchive(rar->handle);
        delete rar;
        return nullptr;
    }
    rar->headersEncrypted = (data.Flags & ROADF_ENCHEADERS) != 0;
    rar->solid = (data.Flags & ROADF_SOLID) != 0;
    rar->volume = (data.Flags & ROADF_VOLUME) != 0;
    return rar;
}

extern "C" int sb_rar_next(SBRar *rar, SBRarEntry *entry) {
    RARHeaderDataEx *header = new (std::nothrow) RARHeaderDataEx();
    if (!header) return ERAR_NO_MEMORY;
    memset(header, 0, sizeof(*header));
    header->RedirName = entry->redirect;
    header->RedirNameSize = sizeof(entry->redirect) / sizeof(wchar_t);
    entry->redirect[0] = 0;
    int r;
    {
        ErrHandler.Clean();
        r = RARReadHeaderEx(rar->handle, header);
    }
    // The last file's code, handed back with this header (see the top)
    bool passwordError = r == ERAR_BAD_PASSWORD || r == ERAR_MISSING_PASSWORD;
    if (r != ERAR_SUCCESS && r != ERAR_END_ARCHIVE && header->FileNameW[0] != 0
        && r == rar->lastProcessed && !(passwordError && rar->headersEncrypted)) r = ERAR_SUCCESS;
    if (r == ERAR_SUCCESS) {
        toUTF8(header->FileNameW, entry->name, sizeof(entry->name));
        entry->size = ((uint64_t)header->UnpSizeHigh << 32) | header->UnpSize;
        uint64_t filetime = ((uint64_t)header->MtimeHigh << 32) | header->MtimeLow;   // 100 ns since 1601
        entry->modified = filetime ? (int64_t)(filetime / 10000000ULL) - 11644473600LL : 0;
        entry->is_directory = (header->Flags & RHDF_DIRECTORY) != 0;
        entry->is_encrypted = (header->Flags & RHDF_ENCRYPTED) != 0;
        entry->split_before = (header->Flags & RHDF_SPLITBEFORE) != 0;
        entry->split_after = (header->Flags & RHDF_SPLITAFTER) != 0;
        // Hard links and file copies are files whose data is another
        // entry's: kept, with that entry's name; links to outside are not
        entry->redirect_type = (int)header->RedirType;
        if (header->RedirType != FSREDIR_HARDLINK && header->RedirType != FSREDIR_FILECOPY) entry->redirect[0] = 0;
        // The CRC of unencrypted, unsplit files (encrypted RAR5 keeps a
        // keyed one; a split file's covers only its part)
        rar->checkCRC = header->HashType == RAR_HASH_CRC32 && !entry->is_encrypted
            && !entry->split_before && !entry->split_after;
        rar->expectedCRC = header->FileCRC;
        rar->expectedSize = entry->size;
        rar->encrypted = entry->is_encrypted;
    }
    delete header;
    return r;
}

extern "C" int sb_rar_read(SBRar *rar, SBRarData data, void *context) {
    rar->data = data;
    rar->context = context;
    rar->stopped = false;
    rar->crc = 0;
    rar->received = 0;
    ErrHandler.Clean();
    int r = RARProcessFile(rar->handle, RAR_TEST, nullptr, nullptr);
    rar->lastProcessed = r;
    rar->data = nullptr;
    rar->context = nullptr;
    if (rar->stopped) return ERAR_SUCCESS;
    if (rar->volumeMissing) return ERAR_EOPEN;
    if ((r == ERAR_MISSING_PASSWORD || r == ERAR_BAD_PASSWORD) && rar->encrypted) return r;
    // The size UnRAR reports for a file stored from a stream is a placeholder
    bool sizeKnown = rar->expectedSize != (uint64_t)INT64NDF;
    bool whole = !sizeKnown || rar->received == rar->expectedSize;
    // The data itself says whether it came out whole. RAR 1.4 keeps a
    // 16-bit checksum that the DLL reports as CRC32: there UnRAR's own
    // check (a success no other thread can fake) decides.
    if (rar->checkCRC) {
        if (whole && rar->crc == rar->expectedCRC) return ERAR_SUCCESS;
        return whole && r == ERAR_SUCCESS ? ERAR_SUCCESS : ERAR_BAD_DATA;
    }
    if (r == ERAR_UNKNOWN && whole) return ERAR_SUCCESS;
    // Less data than the file holds is no success (a wrong password can
    // end a read early without an error)
    if (r == ERAR_SUCCESS && !whole) return ERAR_BAD_DATA;
    return r;
}

extern "C" int sb_rar_skip(SBRar *rar) {
    ErrHandler.Clean();
    rar->lastProcessed = RARProcessFile(rar->handle, RAR_SKIP, nullptr, nullptr);
    // Only a missing volume ends it here; anything else shows at the next header
    return rar->volumeMissing ? ERAR_EOPEN : ERAR_SUCCESS;
}

extern "C" int sb_rar_volume_missing(const SBRar *rar) { return rar->volumeMissing; }
extern "C" int sb_rar_password_asked(const SBRar *rar) { return rar->passwordAsked; }
extern "C" int sb_rar_headers_encrypted(const SBRar *rar) { return rar->headersEncrypted; }
extern "C" int sb_rar_solid(const SBRar *rar) { return rar->solid; }
extern "C" int sb_rar_volume(const SBRar *rar) { return rar->volume; }

extern "C" void sb_rar_redirect_utf8(const SBRarEntry *entry, char *out, size_t size) {
    toUTF8(entry->redirect, out, size);
}

extern "C" void sb_rar_close(SBRar *rar) {
    if (!rar) return;
    if (rar->handle) RARCloseArchive(rar->handle);
    delete rar;
}
