#include "mview_dl3.h"

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonHMAC.h>
#include <Security/Security.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void mview_hdcp_random(void *buf, size_t n) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        ssize_t r = read(fd, buf, n);
        (void)r;
        close(fd);
        return;
    }
    memset(buf, 0xa5, n);
}

static void aes_ecb(const uint8_t key[16], const uint8_t in[16], uint8_t out[16]) {
    size_t moved = 0;
    CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, key, 16, NULL, in, 16, out, 16, &moved);
}

void mview_aes_cmac(const uint8_t key[16], const uint8_t *msg, size_t n, uint8_t tag[16]) {
    uint8_t L[16] = {0}, K1[16], K2[16];
    aes_ecb(key, L, L);
    int i;
    uint8_t carry = (L[0] & 0x80) ? 1 : 0;
    for (i = 0; i < 15; i++) {
        K1[i] = (uint8_t)((L[i] << 1) | (L[i + 1] >> 7));
    }
    K1[15] = (uint8_t)(L[15] << 1);
    if (carry) {
        K1[15] ^= 0x87;
    }
    carry = (K1[0] & 0x80) ? 1 : 0;
    for (i = 0; i < 15; i++) {
        K2[i] = (uint8_t)((K1[i] << 1) | (K1[i + 1] >> 7));
    }
    K2[15] = (uint8_t)(K1[15] << 1);
    if (carry) {
        K2[15] ^= 0x87;
    }

    uint8_t x[16] = {0};
    size_t complete = n / 16;
    int last_full = (n % 16 == 0 && n != 0);
    size_t blocks = last_full ? complete : complete + 1;
    if (n == 0) {
        blocks = 1;
        last_full = 0;
    }
    for (size_t b = 0; b < blocks; b++) {
        uint8_t y[16] = {0};
        if (b + 1 == blocks) {
            if (last_full) {
                memcpy(y, msg + b * 16, 16);
                for (i = 0; i < 16; i++) {
                    y[i] ^= K1[i];
                }
            } else {
                size_t rem = n % 16;
                if (n) {
                    memcpy(y, msg + b * 16, rem);
                }
                y[rem] = 0x80;
                for (i = 0; i < 16; i++) {
                    y[i] ^= K2[i];
                }
            }
        } else {
            memcpy(y, msg + b * 16, 16);
        }
        for (i = 0; i < 16; i++) {
            y[i] ^= x[i];
        }
        aes_ecb(key, y, x);
    }
    memcpy(tag, x, 16);
}

void mview_aes_ctr_xor(const uint8_t key[16], const uint8_t riv[8], uint32_t seq,
                       const uint8_t *in, uint8_t *out, size_t n) {
    size_t off = 0;
    uint32_t blk = 0;
    while (off < n) {
        uint8_t iv[16] = {0};
        memcpy(iv, riv, 8);
        uint32_t ctr = seq + blk;
        iv[12] = (uint8_t)(ctr >> 24);
        iv[13] = (uint8_t)(ctr >> 16);
        iv[14] = (uint8_t)(ctr >> 8);
        iv[15] = (uint8_t)ctr;
        uint8_t ks[16];
        aes_ecb(key, iv, ks);
        size_t chunk = n - off;
        if (chunk > 16) {
            chunk = 16;
        }
        for (size_t i = 0; i < chunk; i++) {
            out[off + i] = in[off + i] ^ ks[i];
        }
        off += chunk;
        blk++;
    }
}

void mview_hmac_sha256(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen,
                       uint8_t out[32]) {
    CCHmac(kCCHmacAlgSHA256, key, klen, msg, mlen, out);
}

void mview_hdcp_compute_h(const uint8_t kd[32], const uint8_t rtx[8], int repeater, uint8_t h[32]) {
    uint8_t x[8];
    memcpy(x, rtx, 8);
    x[7] ^= (uint8_t)repeater;
    mview_hmac_sha256(kd, 32, x, 8, h);
}

void mview_hdcp_compute_l(const uint8_t kd[32], const uint8_t rrx[8], const uint8_t rn[8],
                          uint8_t l[32]) {
    uint8_t key[32];
    memcpy(key, kd, 32);
    for (int i = 0; i < 8; i++) {
        key[24 + i] ^= rrx[i];
    }
    mview_hmac_sha256(key, 32, rn, 8, l);
}

void mview_hdcp_derive_kd(const uint8_t km[16], const uint8_t rtx[8], const uint8_t rrx[8],
                          uint8_t kd[32]) {
    uint8_t rn[8] = {0};
    for (int n = 0; n < 2; n++) {
        uint8_t key[16];
        memcpy(key, km, 16);
        for (int i = 0; i < 8; i++) {
            key[8 + i] ^= rn[i];
        }
        uint8_t ctr[16];
        memcpy(ctr, rtx, 8);
        memcpy(ctr + 8, rrx, 8);
        ctr[15] ^= (uint8_t)n;
        aes_ecb(key, ctr, kd + n * 16);
    }
}

void mview_hdcp_ske_edkey(const uint8_t km[16], const uint8_t rtx[8], const uint8_t rrx[8],
                          const uint8_t rn[8], const uint8_t ks[16], uint8_t edkey[16]) {
    uint8_t key[16];
    memcpy(key, km, 16);
    for (int i = 0; i < 8; i++) {
        key[8 + i] ^= rn[i];
    }
    uint8_t ctr[16];
    memcpy(ctr, rtx, 8);
    memcpy(ctr + 8, rrx, 8);
    ctr[15] ^= 2;
    uint8_t d2[16];
    aes_ecb(key, ctr, d2);
    for (int i = 0; i < 8; i++) {
        d2[8 + i] ^= rrx[i];
    }
    for (int i = 0; i < 16; i++) {
        edkey[i] = ks[i] ^ d2[i];
    }
}

static uint8_t *der_put_len(uint8_t *p, size_t n) {
    if (n < 128) {
        *p++ = (uint8_t)n;
        return p;
    }
    if (n < 256) {
        *p++ = 0x81;
        *p++ = (uint8_t)n;
        return p;
    }
    *p++ = 0x82;
    *p++ = (uint8_t)(n >> 8);
    *p++ = (uint8_t)n;
    return p;
}

static uint8_t *der_put_int(uint8_t *p, const uint8_t *m, size_t n) {
    while (n > 1 && m[0] == 0) {
        m++;
        n--;
    }
    size_t pad = (n && (m[0] & 0x80)) ? 1 : 0;
    *p++ = 0x02;
    p = der_put_len(p, n + pad);
    if (pad) {
        *p++ = 0;
    }
    memcpy(p, m, n);
    return p + n;
}

int mview_hdcp_rsa_oaep_encrypt(const uint8_t modulus[128], const uint8_t exponent[3],
                                const uint8_t km[16], uint8_t out[128]) {
    uint8_t der[256];
    uint8_t *p = der + 4; /* leave room for SEQUENCE header */
    uint8_t *body = p;
    p = der_put_int(p, modulus, 128);
    p = der_put_int(p, exponent, 3);
    size_t body_n = (size_t)(p - body);
    uint8_t *seq = der;
    *seq++ = 0x30;
    seq = der_put_len(seq, body_n);
    memmove(seq, body, body_n);
    size_t der_n = (size_t)(seq - der) + body_n;

    CFDataRef key_data = CFDataCreate(kCFAllocatorDefault, der, (CFIndex)der_n);
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kSecAttrKeyType, kSecAttrKeyTypeRSA);
    CFDictionarySetValue(attrs, kSecAttrKeyClass, kSecAttrKeyClassPublic);
    int bits = 1024;
    CFNumberRef nbits = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bits);
    CFDictionarySetValue(attrs, kSecAttrKeySizeInBits, nbits);

    CFErrorRef cferr = NULL;
    SecKeyRef key = SecKeyCreateWithData(key_data, attrs, &cferr);
    CFRelease(key_data);
    CFRelease(attrs);
    CFRelease(nbits);
    if (!key) {
        if (cferr) {
            CFRelease(cferr);
        }
        return -1;
    }
    CFDataRef plain = CFDataCreate(kCFAllocatorDefault, km, 16);
    CFDataRef cipher =
        SecKeyCreateEncryptedData(key, kSecKeyAlgorithmRSAEncryptionOAEPSHA256, plain, &cferr);
    CFRelease(plain);
    CFRelease(key);
    if (!cipher) {
        if (cferr) {
            CFRelease(cferr);
        }
        return -1;
    }
    CFIndex clen = CFDataGetLength(cipher);
    if (clen != 128) {
        CFRelease(cipher);
        return -1;
    }
    memcpy(out, CFDataGetBytePtr(cipher), 128);
    CFRelease(cipher);
    return 0;
}
