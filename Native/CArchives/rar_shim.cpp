// A small C face for UnRAR's DLL interface (unrar/dll.hpp): UTF-8 names,
// data through a callback, passwords and volumes answered here.
#include <wchar.h>
#include <string.h>
#include <string>
#include <new>
#include "unrar/rar.hpp"
#include "include/CArchives.h"

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
    rar->handle = RAROpenArchiveEx(&data);
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
    int r = RARReadHeaderEx(rar->handle, header);
    if (r == ERAR_SUCCESS) {
        toUTF8(header->FileNameW, entry->name, sizeof(entry->name));
        entry->size = ((uint64_t)header->UnpSizeHigh << 32) | header->UnpSize;
        uint64_t filetime = ((uint64_t)header->MtimeHigh << 32) | header->MtimeLow;   // 100 ns since 1601
        entry->modified = filetime ? (int64_t)(filetime / 10000000ULL) - 11644473600LL : 0;
        entry->is_directory = (header->Flags & RHDF_DIRECTORY) != 0;
        entry->is_encrypted = (header->Flags & RHDF_ENCRYPTED) != 0;
        entry->split_before = (header->Flags & RHDF_SPLITBEFORE) != 0;
        entry->split_after = (header->Flags & RHDF_SPLITAFTER) != 0;
    }
    delete header;
    return r;
}

extern "C" int sb_rar_read(SBRar *rar, SBRarData data, void *context) {
    rar->data = data;
    rar->context = context;
    rar->stopped = false;
    int r = RARProcessFile(rar->handle, RAR_TEST, nullptr, nullptr);
    rar->data = nullptr;
    rar->context = nullptr;
    return rar->stopped ? ERAR_SUCCESS : r;
}

extern "C" int sb_rar_skip(SBRar *rar) {
    return RARProcessFile(rar->handle, RAR_SKIP, nullptr, nullptr);
}

extern "C" int sb_rar_volume_missing(const SBRar *rar) { return rar->volumeMissing; }
extern "C" int sb_rar_password_asked(const SBRar *rar) { return rar->passwordAsked; }
extern "C" int sb_rar_headers_encrypted(const SBRar *rar) { return rar->headersEncrypted; }

extern "C" void sb_rar_close(SBRar *rar) {
    if (!rar) return;
    if (rar->handle) RARCloseArchive(rar->handle);
    delete rar;
}
