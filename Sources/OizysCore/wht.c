#include "oizys_dl3.h"
#include "oizys_profile.h"

#include <arm_neon.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/*
 * Ridge colour strips use a three-level 8x8 Haar pyramid with unscaled integer
 * lifting steps.  The scan order, quantiser tables and rounding rules were
 * measured against the public oracle; the transform family and colour
 * arithmetic follow the public DisplayLink patent and Vino protocol notes.
 */

/*
 * Bits go out least-significant-first within each byte, ascending. Holding them in a
 * register and storing whole little-endian words is the same layout as ORing single bits
 * into zeroed memory, without the zeroing: the old writer memset 36 KB of worst-case
 * buffer per strip, 75 MB per 1080p surface, before a single bit was written.
 */
typedef struct {
    uint8_t *bytes;
    size_t capacity;
    size_t byte_count;
    uint64_t accumulator;
    unsigned held;
    int overflow;
} RidgeBits;

static const uint8_t kScanIndex[8][8] = {
    {0, 63, 2, 61, 8, 10, 55, 53},
    {1, 62, 3, 60, 12, 14, 51, 49},
    {4, 59, 6, 57, 9, 11, 54, 52},
    {5, 58, 7, 56, 13, 15, 50, 48},
    {16, 18, 47, 45, 24, 26, 39, 37},
    {20, 22, 43, 41, 28, 30, 35, 33},
    {17, 19, 46, 44, 25, 27, 38, 36},
    {21, 23, 42, 40, 29, 31, 34, 32},
};

static void ridge_bits_init(RidgeBits *bits, uint8_t *bytes, size_t capacity) {
    bits->bytes = bytes;
    bits->capacity = capacity;
    bits->byte_count = 0;
    bits->accumulator = 0;
    bits->held = 0;
    bits->overflow = 0;
}

/* Append `count` low bits of `value`, first-written bit lowest. `count` is at most 32. */
static inline void ridge_put(RidgeBits *bits, uint32_t value, unsigned count) {
    uint32_t mask = count >= 32 ? UINT32_MAX : ((1u << count) - 1u);
    bits->accumulator |= (uint64_t)(value & mask) << bits->held;
    bits->held += count;
    if (bits->held >= 32) {
        if (bits->byte_count + 4 > bits->capacity) {
            bits->overflow = 1;
            bits->held -= 32;
            bits->accumulator >>= 32;
            return;
        }
        uint32_t word = (uint32_t)bits->accumulator;
        memcpy(bits->bytes + bits->byte_count, &word, sizeof(word));
        bits->byte_count += 4;
        bits->accumulator >>= 32;
        bits->held -= 32;
    }
}

static inline void ridge_bit(RidgeBits *bits, unsigned value) {
    ridge_put(bits, value & 1u, 1);
}

/* Push the tail out of the register. Padding bits are zero because the accumulator is. */
static void ridge_bits_flush(RidgeBits *bits) {
    while (bits->held > 0) {
        if (bits->byte_count >= bits->capacity) {
            bits->overflow = 1;
            return;
        }
        bits->bytes[bits->byte_count++] = (uint8_t)bits->accumulator;
        bits->accumulator >>= 8;
        bits->held = bits->held > 8 ? bits->held - 8 : 0;
    }
}

/*
 * Signed symbol: a unary category prefix, the magnitude's low bits, then the
 * sign.  The prefix is capped per field; at the cap the terminating zero is
 * omitted because no longer category can follow.
 */
#ifndef OIZYS_CAP_SYNC
#define OIZYS_CAP_SYNC 7
#endif
#ifndef OIZYS_CAP_DC
#define OIZYS_CAP_DC 10
#endif
#ifndef OIZYS_CAP_AC
#define OIZYS_CAP_AC 10
#endif
/*
 * Luma AC stops one category below chroma.  At the maximum category the unary
 * prefix carries no terminating zero, so a luma coefficient coded with chroma's
 * ceiling emits a terminator the dock reads as an offset bit and the rest of the
 * half-strip decodes off by one.  Ridge: chroma 10, luma 9.
 */
#ifndef OIZYS_CAP_AC_LUMA
#define OIZYS_CAP_AC_LUMA 9
#endif

static void ridge_symbol(RidgeBits *bits, int32_t value, unsigned cap) {
    if (value == 0) {
        ridge_bit(bits, 0);
        return;
    }
    uint32_t magnitude = (uint32_t)(value < 0 ? -value : value);
    unsigned category = 0;
    for (uint32_t n = magnitude; n; n >>= 1) {
        category++;
    }
    /* Saturate rather than fail.  A magnitude past the codebook would otherwise put
       cap+1 ones on the wire, and a decoder that stops counting at cap reads the extra
       one as an offset bit.  Clamping costs one tile its precision; overflowing costs
       the rest of the strip. */
    if (category > cap) {
        category = cap;
        magnitude = (1u << cap) - 1;
    }
    /* Prefix, offset and sign total at most 21 bits, so the whole symbol is one store.
       The offset goes out most-significant-first, which is the low bits of the reversed
       word; RBIT does that in a single instruction. */
    uint32_t word = (1u << category) - 1u;
    unsigned count = category < cap ? category + 1 : category;
    unsigned offset_bits = category - 1;
    if (offset_bits) {
        uint32_t offset = magnitude - (1u << (category - 1));
        word |= (__builtin_bitreverse32(offset) >> (32 - offset_bits)) << count;
        count += offset_bits;
    }
    word |= (uint32_t)(value > 0) << count;
    ridge_put(bits, word, count + 1);
}

static size_t ridge_bits_bytes(RidgeBits *bits) {
    ridge_bits_flush(bits);
    return bits->overflow ? 0 : bits->byte_count;
}

/*
 * Quantiser tables measured from the public oracle.  Row 0 covers the two
 * colour-difference planes, row 1 the luma-like plane.
 */
static const uint8_t kQuantShift[2][64] = {
    {12, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
     11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12,
     12, 12, 12, 12, 12, 12, 12, 12, 11, 11, 11, 11, 11, 11, 11, 11,
     11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 10, 10, 10, 10, 11, 10},
    {10, 10,  8,  8,  8,  8,  9,  9,  7,  7,  7,  7,  7,  7,  7,  7,
      7,  7,  7,  7,  7,  7,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
      8,  8,  8,  8,  8,  8,  8,  8,  7,  7,  7,  7,  7,  7,  7,  7,
      7,  7,  7,  7,  7,  7,  7,  7,  9,  9,  8,  8,  8,  8, 11, 10},
};

/* Scan positions 8-23 and 40-55 are the mixed horizontal/vertical detail bands. */
static int mixed_band(unsigned scan) {
    return (scan >= 8 && scan <= 23) || (scan >= 40 && scan <= 55);
}

static int32_t quantize(unsigned plane, unsigned scan, int32_t value) {
    unsigned shift = kQuantShift[plane == 2][scan];
    /* Ridge rounds these coefficients, except that the luma plane's mixed
       detail bands truncate positives and round negatives. */
    int32_t bias = (plane == 2 && mixed_band(scan) && value >= 0) ? 0 : (1 << shift >> 1);
    return (value + bias) >> shift;
}

/*
 * Derived from kScanIndex, kQuantShift and mixed_band at load time so the inner loop reads
 * one contiguous table per scan position instead of chasing two levels of indirection per
 * coefficient. test_quantizer_tables_match_the_scalar_path checks them against the scalar
 * quantize() above, which stays as the definition of correct.
 */
static uint8_t kInverseScan[64];   /* scan position -> offset within the 8x8 block */
static int32_t kNegShift[2][64];   /* negated, because SSHL shifts right on negatives */
static int32_t kBias[2][64];
static int32_t kMixedMask[64];     /* all ones where the luma plane truncates positives */
static uint8_t kScanAt[63];

__attribute__((constructor)) static void build_scan_tables(void) {
    for (unsigned row = 0; row < 8; row++) {
        for (unsigned column = 0; column < 8; column++) {
            kInverseScan[kScanIndex[row][column]] = (uint8_t)(row * 8 + column);
        }
    }
    for (unsigned scan = 0; scan < 64; scan++) {
        for (unsigned luma = 0; luma < 2; luma++) {
            unsigned shift = kQuantShift[luma][scan];
            kNegShift[luma][scan] = -(int32_t)shift;
            kBias[luma][scan] = (int32_t)(1u << shift) >> 1;
        }
        kMixedMask[scan] = mixed_band(scan) ? -1 : 0;
    }
    for (unsigned position = 0; position < 63; position++) {
        kScanAt[position] = (uint8_t)((position & 1) ? (position + 1) / 2 : 63 - position / 2);
    }
}

/*
 * Test seam. The scalar quantiser above is the definition of correct; the derived tables
 * and their vector path below are an optimisation that has to agree with it exactly.
 * Exposed so the suite can check that agreement over the whole input range rather than
 * trusting that the tables were transcribed correctly.
 */
int32_t oizys_quantize_reference(unsigned plane, unsigned scan, int32_t value) {
    return (plane > 2 || scan > 63) ? 0 : quantize(plane, scan, value);
}

/* Scan order for a coefficient position, and the position ordering itself, both exposed
   for the same reason. */
unsigned oizys_scan_index(unsigned row, unsigned column) {
    return (row > 7 || column > 7) ? 0 : kScanIndex[row][column];
}

/*
 * Quantise one transformed block straight into scan order. Reading through kInverseScan
 * turns the old scatter into a gather, which leaves the shifts, biases and the output all
 * contiguous — the arrangement NEON can actually use.
 */
static void quantize_block(unsigned plane, const int32_t *transformed, int32_t *out) {
    unsigned luma = plane == 2;
    const int32_t *negative_shift = kNegShift[luma];
    const int32_t *bias_table = kBias[luma];
    const int32x4_t zero = vdupq_n_s32(0);
    for (unsigned scan = 0; scan < 64; scan += 4) {
        int32x4_t value = {transformed[kInverseScan[scan]], transformed[kInverseScan[scan + 1]],
                           transformed[kInverseScan[scan + 2]], transformed[kInverseScan[scan + 3]]};
        int32x4_t bias = vld1q_s32(bias_table + scan);
        if (luma) {
            int32x4_t mixed = vld1q_s32(kMixedMask + scan);
            int32x4_t non_negative = vreinterpretq_s32_u32(vcgeq_s32(value, zero));
            bias = vbicq_s32(bias, vandq_s32(mixed, non_negative));
        }
        vst1q_s32(out + scan,
                  vshlq_s32(vaddq_s32(value, bias), vld1q_s32(negative_shift + scan)));
    }
}

/*
 * Test seam. Runs the vector quantiser and the scalar one over the same coefficients and
 * counts disagreements. The scalar version is the definition; the tables and NEON path
 * below are an optimisation, and this is what proves the optimisation did not change the
 * answer. Returns 0 when they agree everywhere.
 */
int oizys_encode_selftest(int32_t (*generate)(void *context, unsigned index), void *context,
                          unsigned rounds) {
    int mismatches = 0;
    for (unsigned round = 0; round < rounds; round++) {
        int32_t transformed[64], vector_result[64];
        for (unsigned i = 0; i < 64; i++) {
            transformed[i] = generate ? generate(context, i) : (int32_t)(i * 977) - 32768;
        }
        for (unsigned plane = 0; plane < 3; plane++) {
            quantize_block(plane, transformed, vector_result);
            for (unsigned scan = 0; scan < 64; scan++) {
                int32_t expected = quantize(plane, scan, transformed[kInverseScan[scan]]);
                if (vector_result[scan] != expected) {
                    mismatches++;
                }
            }
        }
    }
    return mismatches;
}

/* Test seam: the scan tables the vector path depends on. */
unsigned oizys_inverse_scan(unsigned scan) {
    return scan < 64 ? kInverseScan[scan] : 0;
}

/* Scan of the highest-numbered position still carrying a coefficient, 0 if the block is
   flat. Walking down and stopping beats the old always-63-iteration sweep. */
static unsigned last_significant(const int32_t *coefficients) {
    for (int position = 62; position >= 0; position--) {
        unsigned scan = kScanAt[position];
        if (coefficients[scan]) {
            return scan;
        }
    }
    return 0;
}

static void haar_pyramid(int32_t values[64]) {
    int32_t scratch[8];
    for (unsigned size = 8; size >= 2; size >>= 1) {
        unsigned half = size >> 1;
        for (unsigned y = 0; y < size; y++) {
            for (unsigned x = 0; x < half; x++) {
                int32_t a = values[y * 8 + 2 * x];
                int32_t b = values[y * 8 + 2 * x + 1];
                scratch[x] = a + b;
                scratch[half + x] = a - b;
            }
            memcpy(values + y * 8, scratch, size * sizeof(*scratch));
        }
        for (unsigned x = 0; x < size; x++) {
            for (unsigned y = 0; y < half; y++) {
                int32_t a = values[(2 * y) * 8 + x];
                int32_t b = values[(2 * y + 1) * 8 + x];
                scratch[y] = a + b;
                scratch[half + y] = a - b;
            }
            for (unsigned y = 0; y < size; y++) {
                values[y * 8 + x] = scratch[y];
            }
        }
    }
}

static unsigned scan_at(unsigned position) {
    return (position & 1) ? (position + 1) / 2 : 63 - position / 2;
}

static void put_u16le(uint8_t *bytes, uint16_t value) {
    memcpy(bytes, &value, sizeof(value));
}

size_t oizys_video_colour_strip_planes(uint8_t *out, size_t capacity, uint16_t x, uint16_t y,
                                       const int32_t *planes) {
    if (!out || !planes || capacity < 54) {
        return 0;
    }

    int32_t coefficients[16][3][64];
    uint8_t last[16][3];
    memset(coefficients, 0, sizeof(coefficients));
    memset(last, 0, sizeof(last));
    for (unsigned block = 0; block < 16; block++) {
        for (unsigned plane = 0; plane < 3; plane++) {
            int32_t transformed[64];
            memcpy(transformed, planes + (block * 3 + plane) * 64, sizeof(transformed));
            OIZYS_PROFILE_BEGIN(haar, OIZYS_ZONE_HAAR);
            haar_pyramid(transformed);
            OIZYS_PROFILE_END(haar, OIZYS_ZONE_HAAR);
            OIZYS_PROFILE_BEGIN(quant, OIZYS_ZONE_QUANTIZE);
            quantize_block(plane, transformed, coefficients[block][plane]);
            last[block][plane] = (uint8_t)last_significant(coefficients[block][plane]);
            OIZYS_PROFILE_END(quant, OIZYS_ZONE_QUANTIZE);
        }
    }

    OIZYS_PROFILE_BEGIN(entropy, OIZYS_ZONE_ENTROPY);
    uint8_t main_bytes[4096];
    uint8_t row_bytes[2][16384];
    RidgeBits main;
    RidgeBits rows[2];
    ridge_bits_init(&main, main_bytes, sizeof(main_bytes));
    ridge_bits_init(&rows[0], row_bytes[0], sizeof(row_bytes[0]));
    ridge_bits_init(&rows[1], row_bytes[1], sizeof(row_bytes[1]));

    for (unsigned block = 0; block < 16; block++) {
        for (unsigned plane = 0; plane < 3; plane++) {
            int value = last[block][plane];
            if (plane == 2) {
                value -= 32;
            } else if (value >= 32) {
                value -= 64;
            }
            ridge_symbol(&main, value, OIZYS_CAP_SYNC);
        }
    }

    int32_t previous[3] = {0, 0, 0};
    for (unsigned block = 0; block < 16; block++) {
        for (unsigned plane = 0; plane < 3; plane++) {
            int32_t dc = coefficients[block][plane][0];
            ridge_symbol(&main, dc - previous[plane], OIZYS_CAP_DC);
            previous[plane] = dc;
        }
    }

    for (unsigned block = 0; block < 16; block++) {
        RidgeBits *row = &rows[block / 8];
        for (unsigned plane = 0; plane < 3; plane++) {
            if (last[block][plane] == 0) {
                continue;
            }
            unsigned cap = plane == 2 ? OIZYS_CAP_AC_LUMA : OIZYS_CAP_AC;
            for (unsigned position = 0; position < 63; position++) {
                unsigned scan = scan_at(position);
                ridge_symbol(row, coefficients[block][plane][scan], cap);
                if (scan == last[block][plane]) {
                    break;
                }
            }
        }
    }

    size_t main_length = ridge_bits_bytes(&main);
    size_t row0_length = ridge_bits_bytes(&rows[0]);
    size_t row1_length = ridge_bits_bytes(&rows[1]);
    if (!main_length || rows[0].overflow || rows[1].overflow) {
        return 0;
    }
    size_t main_padded = (main_length + 1) & ~(size_t)1;
    size_t row0_padded = (row0_length + 1) & ~(size_t)1;
    size_t row1_padded = (row1_length + 1) & ~(size_t)1;
    size_t main_end = 16 + main_padded + 2;
    size_t second_row = main_end + row0_padded;
    size_t length = second_row + row1_padded;
    if (length > capacity || length > UINT16_MAX) {
        return 0;
    }

    memset(out, 0, length);
    out[0] = 0x01;
    out[1] = 0x28;
    put_u16le(out + 2, x);
    put_u16le(out + 4, y);
    put_u16le(out + 10, (uint16_t)main_end);
    put_u16le(out + 12, (uint16_t)second_row);
    memcpy(out + 16, main_bytes, main_length);
    memcpy(out + main_end, row_bytes[0], row0_length);
    memcpy(out + second_row, row_bytes[1], row1_length);
    OIZYS_PROFILE_END(entropy, OIZYS_ZONE_ENTROPY);
    return length;
}

/* Widen eight int16 lanes to int32 and scale by 64, the encoder's fixed-point step. */
static inline void store_scaled(int32_t *out, int16x8_t value) {
    vst1q_s32(out, vshlq_n_s32(vmovl_s16(vget_low_s16(value)), 6));
    vst1q_s32(out + 4, vshlq_n_s32(vmovl_s16(vget_high_s16(value)), 6));
}

/*
 * Eight BGRA pixels to the three planes. vld4 deinterleaves the channels in the load, which
 * is the whole reason this is worth vectorising: the scalar version re-read each pixel's
 * bytes one at a time. Everything stays in int16 — the widest intermediate is
 * green + ((red_delta + blue_delta) >> 2), which spans -128..382.
 */
static inline void convert_pixel_row(const uint8_t *pixels, int32_t *blue_plane,
                                     int32_t *red_plane, int32_t *luma_plane) {
    uint8x8x4_t bgra = vld4_u8(pixels);
    int16x8_t blue = vreinterpretq_s16_u16(vmovl_u8(bgra.val[0]));
    int16x8_t green = vreinterpretq_s16_u16(vmovl_u8(bgra.val[1]));
    int16x8_t red = vreinterpretq_s16_u16(vmovl_u8(bgra.val[2]));
    int16x8_t red_delta = vsubq_s16(red, green);
    int16x8_t blue_delta = vsubq_s16(blue, green);
    store_scaled(blue_plane, blue_delta);
    store_scaled(red_plane, red_delta);
    store_scaled(luma_plane,
                 vaddq_s16(green, vshrq_n_s16(vaddq_s16(red_delta, blue_delta), 2)));
}

size_t oizys_video_colour_strip_bgra(uint8_t *out, size_t capacity, uint16_t x, uint16_t y,
                                     const uint8_t *bgra, size_t stride, uint32_t width,
                                     uint32_t height) {
    if (!bgra || stride < (size_t)width * 4) {
        return 0;
    }
    OIZYS_PROFILE_BEGIN(strip, OIZYS_ZONE_STRIP);
    OIZYS_PROFILE_BEGIN(convert, OIZYS_ZONE_CONVERT);
    int32_t planes[16][3][64];
    if ((size_t)x + OIZYS_STRIP_W <= width && (size_t)y + OIZYS_STRIP_H <= height) {
        /* Whole strip inside the surface: every sample is written, so no clearing pass. */
        for (unsigned block = 0; block < 16; block++) {
            const uint8_t *rows =
                bgra + (size_t)(y + (block / 8) * 8) * stride + (size_t)(x + (block % 8) * 8) * 4;
            for (unsigned py = 0; py < 8; py++) {
                convert_pixel_row(rows + (size_t)py * stride, &planes[block][0][py * 8],
                                  &planes[block][1][py * 8], &planes[block][2][py * 8]);
            }
        }
    } else {
        memset(planes, 0, sizeof(planes));
        for (unsigned block = 0; block < 16; block++) {
            unsigned block_x = block % 8;
            unsigned block_y = block / 8;
            for (unsigned py = 0; py < 8; py++) {
                uint32_t source_y = (uint32_t)y + block_y * 8 + py;
                for (unsigned px = 0; px < 8; px++) {
                    uint32_t source_x = (uint32_t)x + block_x * 8 + px;
                    if (source_x >= width || source_y >= height) {
                        continue;
                    }
                    const uint8_t *pixel = bgra + (size_t)source_y * stride + (size_t)source_x * 4;
                    int blue = pixel[0];
                    int green = pixel[1];
                    int red = pixel[2];
                    int red_delta = red - green;
                    int blue_delta = blue - green;
                    unsigned sample = py * 8 + px;
                    planes[block][0][sample] = 64 * blue_delta;
                    planes[block][1][sample] = 64 * red_delta;
                    planes[block][2][sample] =
                        64 * green + 64 * ((red_delta + blue_delta) >> 2);
                }
            }
        }
    }
    OIZYS_PROFILE_END(convert, OIZYS_ZONE_CONVERT);
    size_t encoded = oizys_video_colour_strip_planes(out, capacity, x, y, &planes[0][0][0]);
    OIZYS_PROFILE_END(strip, OIZYS_ZONE_STRIP);
    return encoded;
}
