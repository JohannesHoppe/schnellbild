// A small C face for LibRaw (libraw/libraw.h): one LibRaw instance per
// call, owned by a unique_ptr so it is freed on every path (an exception
// caught here included), the file's bytes in memory, the limits set before
// anything is read, every exception caught here. LibRaw is built
// thread-safe (no LIBRAW_NOTHREADS), so calls run on several threads at once.
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <memory>
#include <new>
#include <atomic>
#include <chrono>
#include <thread>
#include "libraw/libraw/libraw.h"
#include "include/CRaw.h"

namespace {

/// Stops LibRaw's work once the caller's flag is set.
int progress(void *data, enum LibRaw_progress, int, int) {
    const int *cancel = static_cast<const int *>(data);
    return cancel && __atomic_load_n(cancel, __ATOMIC_RELAXED) ? 1 : 0;
}

/// While it lives, LibRaw's own cancel flag (`setCancelFlag`) is set once
/// the caller's is: the raw decoders check only LibRaw's (`checkCancel`),
/// not the progress callback, so a large compressed file (CR3, RAF) stops
/// during `unpack`, not after it.
class CancelWatch {
public:
    CancelWatch(LibRaw &raw, const int *cancel) {
        if (!cancel) return;
        watcher = std::thread([this, &raw, cancel] {
            while (!done.load()) {
                if (__atomic_load_n(cancel, __ATOMIC_RELAXED)) { raw.setCancelFlag(); return; }
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
        });
    }
    ~CancelWatch() {
        done = true;
        if (watcher.joinable()) watcher.join();
    }
private:
    std::atomic<bool> done{false};
    std::thread watcher;
};

/// A LibRaw instance with the limits set, the file's headers read and its
/// size checked against `max_pixels`.
int open(LibRaw &raw, const void *bytes, size_t size, SBRawLimits limits) {
    if (!bytes || size == 0) return LIBRAW_IO_ERROR;
    raw.imgdata.rawparams.max_raw_memory_mb = limits.max_raw_memory_mb;
    int status = raw.open_buffer(bytes, size);
    if (status != LIBRAW_SUCCESS) return status;
    const libraw_image_sizes_t &s = raw.imgdata.sizes;
    if (s.raw_width == 0 || s.raw_height == 0 || s.width == 0 || s.height == 0) return LIBRAW_FILE_UNSUPPORTED;
    if (int64_t(s.raw_width) * int64_t(s.raw_height) > limits.max_pixels * 4) return LIBRAW_TOO_BIG;
    return LIBRAW_SUCCESS;
}

double degrees(const float dms[3], char ref) {
    double value = double(dms[0]) + double(dms[1]) / 60.0 + double(dms[2]) / 3600.0;
    return (ref == 'S' || ref == 'W') ? -value : value;
}

/// Hands LibRaw's processed image over; `bits` 8 or 16, sizes checked.
int handOver(libraw_processed_image_t *image, SBRawPicture *out, int64_t max_pixels) {
    if (!image) return LIBRAW_UNSPECIFIED_ERROR;
    memset(out, 0, sizeof *out);
    if (image->type == LIBRAW_IMAGE_JPEG || image->type == LIBRAW_IMAGE_JPEGXL) {
        out->kind = 1;
    } else if (image->type == LIBRAW_IMAGE_BITMAP) {
        int64_t samples = int64_t(image->width) * image->height * image->colors;
        int bytes = image->bits == 16 ? 2 : 1;
        if (image->width == 0 || image->height == 0 || (image->colors != 1 && image->colors != 3)
            || (image->bits != 8 && image->bits != 16) || int64_t(image->width) * image->height > max_pixels
            || int64_t(image->data_size) < samples * bytes) {
            LibRaw::dcraw_clear_mem(image);
            return LIBRAW_UNSPECIFIED_ERROR;
        }
        out->kind = 2;
    } else {
        LibRaw::dcraw_clear_mem(image);
        return LIBRAW_NO_THUMBNAIL;
    }
    out->width = image->width;
    out->height = image->height;
    out->colors = image->colors;
    out->bits = image->bits;
    out->data = image->data;
    out->size = image->data_size;
    out->opaque = image;
    return LIBRAW_SUCCESS;
}

/// What the headers say, from an instance opened (`open`).
void fill(LibRaw &raw, SBRawFacts *facts) {
    memset(facts, 0, sizeof *facts);
    const libraw_iparams_t &id = raw.imgdata.idata;
    const libraw_image_sizes_t &s = raw.imgdata.sizes;
    const libraw_imgother_t &o = raw.imgdata.other;
    strncpy(facts->make, id.make, sizeof facts->make - 1);
    strncpy(facts->model, id.model, sizeof facts->model - 1);
    facts->raw_width = s.raw_width;
    facts->raw_height = s.raw_height;
    facts->width = s.width;
    facts->height = s.height;
    facts->flip = s.flip;
    facts->bits = raw.imgdata.color.raw_bps;
    facts->iso = o.iso_speed;
    facts->shutter = o.shutter;
    facts->aperture = o.aperture;
    facts->focal_length = o.focal_len;
    facts->timestamp = int64_t(o.timestamp);
    const libraw_gps_info_t &gps = o.parsed_gps;
    if (gps.gpsparsed && (gps.latref == 'N' || gps.latref == 'S') && (gps.longref == 'E' || gps.longref == 'W')) {
        double latitude = degrees(gps.latitude, gps.latref), longitude = degrees(gps.longitude, gps.longref);
        if (isfinite(latitude) && isfinite(longitude) && fabs(latitude) <= 90 && fabs(longitude) <= 180) {
            facts->has_gps = 1;
            facts->latitude = latitude;
            facts->longitude = longitude;
            facts->altitude = isfinite(gps.altitude) ? (gps.altref == 1 ? -gps.altitude : gps.altitude) : 0;
        }
    }
}

} // namespace

extern "C" int sb_raw_facts(const void *bytes, size_t size, SBRawLimits limits, SBRawFacts *facts) {
    try {
        std::unique_ptr<LibRaw> raw(new (std::nothrow) LibRaw(0));
        if (!raw) return LIBRAW_UNSUFFICIENT_MEMORY;
        int status = open(*raw, bytes, size, limits);
        if (status == LIBRAW_SUCCESS) fill(*raw, facts);
        return status;
    } catch (...) {
        return LIBRAW_UNSPECIFIED_ERROR;
    }
}

extern "C" int sb_raw_thumbnail(const void *bytes, size_t size, SBRawLimits limits, int max_side, SBRawPicture *out, SBRawFacts *facts) {
    try {
        std::unique_ptr<LibRaw> raw(new (std::nothrow) LibRaw(0));
        if (!raw) return LIBRAW_UNSUFFICIENT_MEMORY;
        int status = open(*raw, bytes, size, limits);
        if (status == LIBRAW_SUCCESS) {
            if (facts) fill(*raw, facts);
            // The largest preview within `max_side` that is a JPEG, JPEG XL
            // or bitmap (not an H.265 one: nothing here decodes it alone)
            const libraw_thumbnail_list_t &list = raw->imgdata.thumbs_list;
            int best = -1, bestSide = 0;
            for (int i = 0; i < list.thumbcount && i < LIBRAW_THUMBNAIL_MAXCOUNT; i++) {
                const libraw_thumbnail_item_t &item = list.thumblist[i];
                if (item.tformat != LIBRAW_INTERNAL_THUMBNAIL_JPEG && item.tformat != LIBRAW_INTERNAL_THUMBNAIL_JPEGXL
                    && item.tformat != LIBRAW_INTERNAL_THUMBNAIL_PPM && item.tformat != LIBRAW_INTERNAL_THUMBNAIL_KODAK_RGB
                    && item.tformat != LIBRAW_INTERNAL_THUMBNAIL_KODAK_YCBCR && item.tformat != LIBRAW_INTERNAL_THUMBNAIL_KODAK_THUMB)
                    continue;
                int side = item.twidth > item.theight ? item.twidth : item.theight;
                bool fits = max_side <= 0 || side <= max_side;
                bool bestFits = max_side <= 0 || bestSide <= max_side;
                // Fitting ones before larger ones; among those the larger,
                // among larger ones the smaller
                if (best < 0 || (fits && (!bestFits || side > bestSide)) || (!fits && !bestFits && side < bestSide)) {
                    best = i;
                    bestSide = side;
                }
            }
            if (best < 0) {
                status = LIBRAW_NO_THUMBNAIL;
            } else {
                status = list.thumbcount > 1 ? raw->unpack_thumb_ex(best) : raw->unpack_thumb();
                if (status == LIBRAW_SUCCESS) {
                    int error = 0;
                    libraw_processed_image_t *image = raw->dcraw_make_mem_thumb(&error);
                    status = image ? handOver(image, out, limits.max_pixels) : (error ? error : LIBRAW_UNSPECIFIED_ERROR);
                }
            }
        }
        return status;
    } catch (...) {
        return LIBRAW_UNSPECIFIED_ERROR;
    }
}

extern "C" int sb_raw_develop(const void *bytes, size_t size, SBRawLimits limits, int half, const int *cancel, SBRawPicture *out,
                              SBRawFacts *facts) {
    try {
        std::unique_ptr<LibRaw> raw(new (std::nothrow) LibRaw(0));
        if (!raw) return LIBRAW_UNSUFFICIENT_MEMORY;
        raw->set_progress_handler(progress, const_cast<int *>(cancel));
        CancelWatch watch(*raw, cancel);
        int status = open(*raw, bytes, size, limits);
        if (status == LIBRAW_SUCCESS) {
            if (facts) fill(*raw, facts);
            // More pixels than allowed at full size: half size
            const libraw_image_sizes_t &s = raw->imgdata.sizes;
            if (int64_t(s.width) * s.height > limits.max_pixels) half = 1;
            int64_t pixels = int64_t(s.width) * s.height / (half ? 4 : 1);
            if (pixels > limits.max_pixels) status = LIBRAW_TOO_BIG;
        }
        if (status == LIBRAW_SUCCESS) {
            libraw_output_params_t &p = raw->imgdata.params;
            p.half_size = half ? 1 : 0;
            p.use_camera_wb = 1;      // as shot
            p.output_color = 1;       // sRGB primaries
            p.output_bps = 8;
            p.gamm[0] = 1 / 2.4;      // sRGB's curve
            p.gamm[1] = 12.92;
            p.user_qual = 3;          // AHD
            status = raw->unpack();
            if (status == LIBRAW_SUCCESS) status = raw->dcraw_process();
            if (status == LIBRAW_SUCCESS) {
                int error = 0;
                libraw_processed_image_t *image = raw->dcraw_make_mem_image(&error);
                status = image ? handOver(image, out, limits.max_pixels) : (error ? error : LIBRAW_UNSPECIFIED_ERROR);
            }
        }
        return status;
    } catch (...) {
        return LIBRAW_UNSPECIFIED_ERROR;
    }
}

extern "C" void sb_raw_free(SBRawPicture *picture) {
    if (picture && picture->opaque) {
        LibRaw::dcraw_clear_mem(static_cast<libraw_processed_image_t *>(picture->opaque));
        picture->opaque = nullptr;
        picture->data = nullptr;
    }
}

extern "C" const char *sb_raw_version(void) {
    return LibRaw::version();
}
