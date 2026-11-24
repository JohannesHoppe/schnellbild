// What Swift calls to read camera RAW files ImageIO doesn't read: LibRaw
// (Scripts/fetch_libraw.sh vendors its source; raw_shim.cpp is compiled
// with it). Everything works on bytes in memory, one LibRaw instance per
// call, so files are read on several threads at once.
#ifndef SCHNELLBILD_CRAW_H
#define SCHNELLBILD_CRAW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// What LibRaw read from a file's headers.
typedef struct {
    char make[64];
    char model[64];
    int raw_width, raw_height;   // the sensor's data
    int width, height;           // the picture, before turning
    int flip;                    // LibRaw's: 0, 3 (180°), 5 (90° left), 6 (90° right)
    int bits;                    // bits per sample of the raw data, 0 when unknown
    float iso, shutter, aperture, focal_length;
    int64_t timestamp;           // Unix time, 0 when unknown
    int has_gps;
    double latitude, longitude;  // degrees, south and west negative
    double altitude;             // metres
} SBRawFacts;

/// A picture LibRaw handed over: `data` holds `size` bytes until
/// `sb_raw_free`. `kind` 1: JPEG or JPEG XL bytes (`width` / `height` as the
/// file says); 2: `height` rows of `width` × `colors` samples of `bits` (8
/// or 16, 16 in native byte order), no padding.
typedef struct {
    int kind;
    int width, height, colors, bits;
    const uint8_t *data;
    size_t size;
    void *opaque;
} SBRawPicture;

/// Limits handed to LibRaw: the most memory a raw image may take, and
/// the most pixels a picture may have; larger ones are refused.
typedef struct {
    unsigned max_raw_memory_mb;
    int64_t max_pixels;
} SBRawLimits;

/// Reads the headers of `size` bytes at `bytes`. Returns 0, or LibRaw's
/// error code (negative); refused beyond the limits.
int sb_raw_facts(const void *bytes, size_t size, SBRawLimits limits, SBRawFacts *facts);

/// The picture the file carries for previews (JPEG, JPEG XL or a bitmap),
/// the largest one no wider than `max_side` (0: any), and the headers'
/// facts (`facts` may be NULL; filled once the headers are read, also when
/// there is no preview). Returns 0 or an error.
int sb_raw_thumbnail(const void *bytes, size_t size, SBRawLimits limits, int max_side, SBRawPicture *out, SBRawFacts *facts);

/// The raw data developed (camera white balance, sRGB, 8 bits per sample,
/// turned upright); `half` develops at half the size (four times faster),
/// as does a picture of more pixels than `limits.max_pixels`. `facts` (may
/// be NULL) as for sb_raw_thumbnail. `cancel`: watched during the work
/// (another thread sets it), nonzero stops it, also inside LibRaw's raw
/// decoders. Returns 0 or an error.
int sb_raw_develop(const void *bytes, size_t size, SBRawLimits limits, int half, const int *cancel, SBRawPicture *out,
                   SBRawFacts *facts);

void sb_raw_free(SBRawPicture *picture);

/// LibRaw's version ("0.22.3-Release").
const char *sb_raw_version(void);

#ifdef __cplusplus
}
#endif

#endif
