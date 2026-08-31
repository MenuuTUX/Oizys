"""HDCP 2.2 primitives against published known-answer vectors.

Every one of these is load-bearing for authentication. A CMAC that is subtly wrong still
returns sixteen plausible bytes, the dock rejects the session, and the failure surfaces
four layers away as "no HDMI". Standard vectors are what separates a correct
implementation from a confident one.

AES-CMAC: RFC 4493. HMAC-SHA-256: RFC 4231.
"""
import ctypes

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from Support import oizyscore as core

KEY = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")

CMAC_VECTORS = [
    ("", "bb1d6929e95937287fa37d129b756746", "empty message"),
    ("6bc1bee22e409f96e93d7e117393172a", "070a16b46b4d4144f79bdd9dd04a287c", "one block"),
    ("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411",
     "dfa66747de9ae63030ca32611497c827", "partial block"),
    ("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411"
     "e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710",
     "51f0bebf7e3b9d92fc49741779363cfe", "four blocks"),
]


def cmac(key: bytes, message: bytes) -> bytes:
    tag = core.buffer(16)
    core.lib.oizys_aes_cmac(core.as_u8(key), core.as_u8(message), len(message),
                            ctypes.cast(tag, ctypes.POINTER(ctypes.c_uint8)))
    return bytes(tag)


def hmac(key: bytes, message: bytes) -> bytes:
    out = core.buffer(32)
    core.lib.oizys_hmac_sha256(core.as_u8(key), len(key), core.as_u8(message), len(message),
                               ctypes.cast(out, ctypes.POINTER(ctypes.c_uint8)))
    return bytes(out)


def ctr(key: bytes, riv: bytes, seq: int, data: bytes) -> bytes:
    out = core.buffer(len(data))
    core.lib.oizys_aes_ctr_xor(core.as_u8(key), core.as_u8(riv), seq, core.as_u8(data),
                               ctypes.cast(out, ctypes.POINTER(ctypes.c_uint8)), len(data))
    return bytes(out)


@pytest.mark.parametrize("message,tag,label", CMAC_VECTORS)
def test_aes_cmac_matches_rfc4493(message, tag, label):
    assert cmac(KEY, bytes.fromhex(message)).hex() == tag, label


@pytest.mark.parametrize("key,message,expected,label", [
    (bytes([0x0b]) * 20, b"Hi There",
     "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "case 1"),
    (b"Jefe", b"what do ya want for nothing?",
     "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "case 2"),
    (bytes([0xaa]) * 20, bytes([0xdd]) * 50,
     "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe", "case 3"),
    (bytes([0xaa]) * 131, b"Test Using Larger Than Block-Size Key - Hash Key First",
     "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "case 6, long key"),
])
def test_hmac_sha256_matches_rfc4231(key, message, expected, label):
    assert hmac(key, message).hex() == expected, label


@given(st.binary(min_size=16, max_size=16), st.binary(min_size=8, max_size=8),
       st.integers(0, 2 ** 32 - 1), st.binary(min_size=1, max_size=512))
@settings(max_examples=300, deadline=None)
def test_ctr_is_its_own_inverse(key, riv, seq, data):
    """CTR builds its counter from riv and seq, so there is no published vector. What has
    to hold is that it is a keystream XOR."""
    assert ctr(key, riv, seq, ctr(key, riv, seq, data)) == data


@given(st.binary(min_size=16, max_size=16), st.binary(min_size=8, max_size=8),
       st.integers(0, 2 ** 32 - 2))
@settings(max_examples=200, deadline=None)
def test_ctr_keystream_depends_on_the_sequence(key, riv, seq):
    zeros = bytes(32)
    assert ctr(key, riv, seq, zeros) != ctr(key, riv, seq + 1, zeros), \
        "two sequence numbers produced the same keystream"
    assert ctr(key, riv, seq, zeros) == ctr(key, riv, seq, zeros), \
        "keystream is not reproducible, so a retransmit would decrypt to garbage"


@given(st.binary(min_size=16, max_size=16), st.binary(min_size=8, max_size=8),
       st.binary(min_size=8, max_size=8), st.integers(0, 15))
@settings(max_examples=120, deadline=None)
def test_kd_depends_on_every_input_byte(km, rtx, rrx, index):
    """A derivation that silently drops one of its inputs is the classic way these go
    wrong, and it still produces 32 convincing bytes."""
    def derive(km_, rtx_, rrx_):
        out = core.buffer(32)
        core.lib.oizys_hdcp_derive_kd(core.as_u8(km_), core.as_u8(rtx_), core.as_u8(rrx_),
                                      ctypes.cast(out, ctypes.POINTER(ctypes.c_uint8)))
        return bytes(out)

    baseline = derive(km, rtx, rrx)
    assert derive(km, rtx, rrx) == baseline, "kd is not deterministic"

    altered = bytearray(km)
    altered[index] ^= 0x01
    assert derive(bytes(altered), rtx, rrx) != baseline, f"kd ignored bit 0 of km[{index}]"

    altered = bytearray(rtx)
    altered[index % 8] ^= 0x01
    assert derive(km, bytes(altered), rrx) != baseline, "kd ignored a bit of rtx"

    altered = bytearray(rrx)
    altered[index % 8] ^= 0x01
    assert derive(km, rtx, bytes(altered)) != baseline, "kd ignored a bit of rrx"


def test_h_distinguishes_a_repeater():
    kd, rtx = bytes(range(32)), bytes(range(8))
    out_a, out_b = core.buffer(32), core.buffer(32)
    p = ctypes.POINTER(ctypes.c_uint8)
    core.lib.oizys_hdcp_compute_h(core.as_u8(kd), core.as_u8(rtx), 0, ctypes.cast(out_a, p))
    core.lib.oizys_hdcp_compute_h(core.as_u8(kd), core.as_u8(rtx), 1, ctypes.cast(out_b, p))
    assert bytes(out_a) != bytes(out_b), "H ignored the repeater flag"


def test_random_is_not_stubbed():
    """A generator returning zeroes would authenticate against a permissive dock and
    silently destroy the session's security."""
    a, b = core.buffer(32), core.buffer(32)
    core.lib.oizys_hdcp_random(a, 32)
    core.lib.oizys_hdcp_random(b, 32)
    assert bytes(a) != bytes(32), "hdcp_random returned all zeroes"
    assert bytes(a) != bytes(b), "hdcp_random repeated across two calls"


# A real 1024-bit RSA modulus. Security.framework validates the key it is handed, so
# random bytes never reach the encryption path -- which the rejection tests below rely on.
MODULUS = bytes.fromhex(
    "ce987b19fc4658c6ddd94276822148d27e1b19da78f9e9b214a6cb15c0764637f0a02a4c"
    "74aeb2b2294c63ed830d8128f10d539513341d826e6c3099e3f43aa60ec66e4ac33323d1"
    "17ee2cb503aaa187646e910b2106670099e4a4aba6874004fd2ec0796dda2c7a95cbbd1a"
    "c48b87ae947f14a7d48d848bf3d56eb62b068463"
)


def oaep(modulus: bytes, message: bytes = bytes(16)):
    out = core.buffer(128)
    status = core.lib.oizys_hdcp_rsa_oaep_encrypt(
        core.as_u8(modulus), core.as_u8(bytes([0x01, 0x00, 0x01])), core.as_u8(message),
        ctypes.cast(out, ctypes.POINTER(ctypes.c_uint8)))
    return status, bytes(out)


def test_oaep_encrypts_with_a_valid_key():
    status, first = oaep(MODULUS)
    assert status == 0, "a valid public key was rejected"
    status, second = oaep(MODULUS)
    assert status == 0
    # OAEP seeds every encryption randomly. Identical ciphertext would leak whether two
    # sessions used the same km.
    assert first != second, "two encryptions of one message were byte-identical"


@pytest.mark.parametrize("label,modulus", [
    ("all zero", bytes(128)),
    ("even", MODULUS[:-1] + bytes([MODULUS[-1] & 0xFE])),
])
def test_oaep_rejects_keys_that_are_not_rsa_moduli(label, modulus):
    """Security.framework checks that the modulus is structurally an RSA key, not that it
    is a product of primes -- an all-ones modulus is odd and passes. These two are the
    cases it genuinely refuses, and the point is that a bad key is refused rather than
    silently producing something that looks like ciphertext."""
    status, _ = oaep(modulus)
    assert status != 0, f"an {label} modulus was accepted as an RSA key"
