// A small C face for UnRAR's DLL interface (unrar/dll.hpp): UTF-8 names,
// data through a callback, passwords and volumes answered here.
//
// UnRAR keeps its error state in one global object (ErrHandler) and returns
// it after every header and every file: a warning from one archive (an
// unfinished download) would make every later call fail, also for other
// archives. So the state is cleared before each call, opening and reading
// headers (short) run one at a time, and a file's data is checked against
// its CRC32 here instead of trusting the shared state (unpacking can take
// long and must not block other archives). An unpacking thread can still set
// the state while another reads a header (a pass stopped by its reader is a
// "user break", a wrong password probed in another archive), and a handle
// keeps the last file's error until its next file is processed: a header
// read whole (it has a name) counts as read, whatever code comes with it,
// except a password error where the headers themselves are encrypted; a
// password error for a file that isn't encrypted is someone else's.
#include <wchar.h>
#include <string.h>
#include <string>
#include <new>
#include <mutex>
#include "unrar/rar.hpp"
#include "include/CArchives.h"

static std::mutex headerLock;

static uint32_t crcTable[256];
static std::once_flag crcOnce;
static uint32_t crc32Update(uint32_t crc, const uint8_t *bytes, size_t count) {
    std::call_once(crcOnce, [] {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            crcTable[i] = c;
        }
    });
    crc = ~crc;
    for (size_t i = 0; i < count; i++) crc = crcTable[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

struct SBRar {
    HANDLE handle = nullptr;
    std::wstring password;
    bool hasPassword = false;
    bool passwordAsked = false;
    bool volumeMissing = false;
    bool headersEncrypted = false;
    SBRarData data = nullptr;
    void *context = nullptr;
    bool stopped = false;
    // The current entry, for checking its data
    uint32_t expectedCRC = 0;
    bool checkCRC = false;
    uint64_t expectedSize = 0;
    bool encrypted = false;
    uint32_t crc = 0;
    uint64_t received = 0;
};

static std::wstring fromUTF8(const char *s) {
    std::wstring out;
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        uint32_t c = *p++;
        int extra = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
        if (extra) c &= (0x3F >> extra);
        for (int i = 0; i < extra && (*p & 0xC0) == 0x80; i++) c = (c << 6) | (*p++ & 0x3F);
        out.push_back((wchar_t)c);
    }
    return out;
}

static void toUTF8(const wchar_t *w, char *out, size_t size) {
    size_t n = 0;
    for (; *w && n + 4 < size; w++) {
        uint32_t c = (uint32_t)*w;
        if (c < 0x80) out[n++] = (char)c;
        else if (c < 0x800) { out[n++] = (char)(0xC0 | (c >> 6)); out[n++] = (char)(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) {
            out[n++] = (char)(0xE0 | (c >> 12)); out[n++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[n++] = (char)(0x80 | (c & 0x3F));
        } else {
            out[n++] = (char)(0xF0 | (c >> 18)); out[n++] = (char)(0x80 | ((c >> 12) & 0x3F));
            out[n++] = (char)(0x80 | ((c >> 6) & 0x3F)); out[n++] = (char)(0x80 | (c & 0x3F));
        }
    }
    out[n] = 0;
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
    data.OpenMode = list_only ? RAR_OM_LIST : RAR_OM_EXTRACT;
    data.Callback = callback;
    data.UserData = (LPARAM)rar;
    {
        std::lock_guard<std::mutex> guard(headerLock);
        ErrHandler.Clean();
        rar->handle = RAROpenArchiveEx(&data);
    }
    if (rar->handle && data.OpenResult == ERAR_UNKNOWN) data.OpenResult = ERAR_SUCCESS;
    *result = (int)data.OpenResult;
    *password_asked = rar->passwordAsked;
    if (!rar->handle || data.OpenResult != ERAR_SUCCESS) {
        if (rar->handle) RARCloseArchive(rar->handle);
        delete rar;
        return nullptr;
    }
    rar->headersEncrypted = (data.Flags & ROADF_ENCHEADERS) != 0;
    return rar;
}

extern "C" int sb_rar_next(SBRar *rar, SBRarEntry *entry) {
    RARHeaderDataEx *header = new (std::nothrow) RARHeaderDataEx();
    if (!header) return ERAR_NO_MEMORY;
    memset(header, 0, sizeof(*header));
    int r;
    {
        std::lock_guard<std::mutex> guard(headerLock);
        ErrHandler.Clean();
        r = RARReadHeaderEx(rar->handle, header);
    }
    bool passwordError = r == ERAR_BAD_PASSWORD || r == ERAR_MISSING_PASSWORD;
    if (r != ERAR_SUCCESS && r != ERAR_END_ARCHIVE && header->FileNameW[0] != 0
        && !(passwordError && rar->headersEncrypted)) r = ERAR_SUCCESS;
    if (r == ERAR_SUCCESS) {
        toUTF8(header->FileNameW, entry->name, sizeof(entry->name));
        entry->size = ((uint64_t)header->UnpSizeHigh << 32) | header->UnpSize;
        uint64_t filetime = ((uint64_t)header->MtimeHigh << 32) | header->MtimeLow;   // 100 ns since 1601
        entry->modified = filetime ? (int64_t)(filetime / 10000000ULL) - 11644473600LL : 0;
        entry->is_directory = (header->Flags & RHDF_DIRECTORY) != 0;
        entry->is_encrypted = (header->Flags & RHDF_ENCRYPTED) != 0;
        entry->split_before = (header->Flags & RHDF_SPLITBEFORE) != 0;
        entry->split_after = (header->Flags & RHDF_SPLITAFTER) != 0;
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
    return r;
}

extern "C" int sb_rar_skip(SBRar *rar) {
    ErrHandler.Clean();
    RARProcessFile(rar->handle, RAR_SKIP, nullptr, nullptr);
    // Only a missing volume ends it here; anything else shows at the next header
    return rar->volumeMissing ? ERAR_EOPEN : ERAR_SUCCESS;
}

extern "C" int sb_rar_volume_missing(const SBRar *rar) { return rar->volumeMissing; }
extern "C" int sb_rar_password_asked(const SBRar *rar) { return rar->passwordAsked; }
extern "C" int sb_rar_headers_encrypted(const SBRar *rar) { return rar->headersEncrypted; }

extern "C" void sb_rar_close(SBRar *rar) {
    if (!rar) return;
    if (rar->handle) RARCloseArchive(rar->handle);
    delete rar;
}
