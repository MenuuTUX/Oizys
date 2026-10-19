"""HDCP 2.2 primitives against published known-answer vectors.

Every one of these is load-bearing for authentication. A CMAC that is subtly wrong still
returns sixteen plausible bytes, the dock rejects the session, and the failure surfaces
four layers away as "no HDMI". Standard vectors are what separates a correct
implementation from a confident one.

AES-CMAC: RFC 4493. HMAC-SHA-256: RFC 4231.
"""
import ctypes
from pathlib import Path

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
    assert core.lib.oizys_hdcp_random(a, 32) == 0
    assert core.lib.oizys_hdcp_random(b, 32) == 0
    assert bytes(a) != bytes(32), "hdcp_random returned all zeroes"
    assert bytes(a) != bytes(b), "hdcp_random repeated across two calls"


# HDCP 2.2 IIA Appendix D, Tables D.2 and D.3: DCP facsimile issuer and receiver R1.
# These keys are published for tests only; the driver uses the production key in Appendix B.
FACSIMILE_DCP_MODULUS = bytes.fromhex(
    "a2c7555754cbaaa77a2792c31a6dc231cf12c224bf897246a48d2083b2dd04da"
    "7e01a919ef7e8c4754c859725c8960629f39d0e480caa8d41e91e30e2c77556d"
    "58a89e3ef2da783ebad1053707f288740cbcfb68a47a27ad63a51f67f1458516"
    "498ae6341c6e80f5ff1372855dc1de5f0186558671e8103314702a5f157b5c65"
    "3c463a1779ed546aa6c9dfeb2a812a802a46a206dbfdd5f3cf74bb665648d77c"
    "6a03141e5556e4b6fa382b5dfb879f9e782187c00c633e8d0fe2a719109b15e1"
    "1187493349b86632287c87f5d22ec5f3662f79ef405ad41485745f064350cdde"
    "84e73c7d8e8a49cc5acf73a18a13ff37133dad57d85122d6321fc0684ca05bdd"
    "5f78c89f2d3aa2b81e4ae408556405e694fbeb036a0abe831894d4b6c3f2589c"
    "7a24ddd13ab73ab0bbe5d128abad2454720e76d28932ea46d378d0a96778c12d"
    "18b033dedb27ccb07cc9a4bddf2b64103244068121b3bacf3385491e864cbdf2"
    "3d34efd6237a9f2cda84f08383717dda6e4496cd1d05de30f61e2f9c999c6007"
)
FACSIMILE_R1_CERT = bytes.fromhex(
    "745bb8bd04afb5c5c67bc53a3490a954c08fb7eba154d24f22de83f503a6c668"
    "469bc0b8c86cdb26f93c492f02e171df4ef30ec8bf229d04cfbfa90dff68ab05"
    "6f1f128a6862ebfec9ea9fa7fb8cbab1bd65ac359ca033b1dda60536af00a27f"
    "bc07b2ddb5cc575cdcc09550e5ff1f20db5946fa47c4ed122e9e22bd95a98559"
    "a1593cc78301000110000ba37377dd0318038a9163291ea29574429078d06725"
    "b6322fcc232bad21393d14ba37a365146b9ccf612044a107bbcfc34e955b10cf"
    "c76ff1c3537c63a18cb2e8ab2e9697c3839970d3dc2141f60ad11aeef4ccebfb"
    "a6aab69aaf1d165ee283a04a41f67b07bf4785286ca077a6a3d785a5c4a7e76e"
    "b51f407297fec48123a0c290b34924f5b7902cbffe042e00a95f8604cac53acc"
    "26d9397ea92d286dc0cc6e819fb9b7113332234798430da51c59f3cdd24ab73e"
    "69d921539af26e7762ae50da85c6aac4b51ccda8a5dd6e6273ff5f7bd73c17ba"
    "470c890e62794394aaa847f44c3889a881ad2313270c17cf3d83845736e72226"
    "2e76fd568083f670d45c9148847b18db0e153b492623e6a3e2c63a235766b072"
    "b812174f86fe480d53eafe31487d86deeb82861e620398590037eb61e9f97a40"
    "781cbabc0b88fbfd9dd5011194e035be33e8e536fb9c45cb75afd635ff78927f"
    "a17ca8fcb7f7a852a9c684723d1cc9df35c6e600e14872ce831bccf8332d4f98"
    "75003c41df7aed3853b1"
)


def verify_cert(cert: bytes, issuer: bytes = FACSIMILE_DCP_MODULUS) -> int:
    return core.lib.oizys_hdcp_verify_receiver_cert(core.as_u8(cert), len(cert),
                                                     core.as_u8(issuer))


def test_receiver_certificate_signature_matches_published_vector():
    assert len(FACSIMILE_DCP_MODULUS) == 384
    assert len(FACSIMILE_R1_CERT) == 522
    assert verify_cert(FACSIMILE_R1_CERT) == 0


@pytest.mark.parametrize("index", [0, 5, 136, 137, 138, 521])
def test_receiver_certificate_rejects_modified_fields_and_signature(index):
    altered = bytearray(FACSIMILE_R1_CERT)
    altered[index] ^= 1
    assert verify_cert(altered) != 0


def test_receiver_certificate_rejects_short_or_untrusted_certificate():
    assert verify_cert(FACSIMILE_R1_CERT[:-1]) != 0
    assert verify_cert(FACSIMILE_R1_CERT, bytes(384)) != 0


def test_ake_certificate_accepts_transport_padding_but_not_truncation():
    def verify(payload: bytes) -> int:
        return core.lib.oizys_hdcp_verify_ake_cert_payload(
            core.as_u8(payload), len(payload), core.as_u8(FACSIMILE_DCP_MODULUS))

    payload = b"\x01" + FACSIMILE_R1_CERT
    assert verify(payload) == 0
    assert verify(payload + b"\xa5" * 5) == 0
    assert verify(payload[:-1]) != 0
    assert verify(b"\x02" + FACSIMILE_R1_CERT) != 0


def ridge_certificate():
    return bytes.fromhex((Path(__file__).parent / "Support/ridge_receiver_certificate.hex").read_text())


def verify_ridge(payload):
    return core.lib.oizys_dl3_verify_ridge_certificate(core.as_u8(payload), len(payload))


def test_known_ridge_certificate_is_accepted_by_explicit_pin():
    cert = ridge_certificate()
    assert len(cert) == 522
    payload = b"\x01" + cert
    assert verify_ridge(payload) == 0
    assert verify_ridge(payload + b"\xa5" * 5) == 0
    assert verify_ridge(payload[:-1]) != 0
    assert verify_ridge(b"\x02" + cert) != 0
    assert verify_ridge(b"\x01" + FACSIMILE_R1_CERT) != 0


@pytest.mark.parametrize("index", [0, 5, 136, 137, 138, 521])
def test_known_ridge_pin_rejects_modified_fields_and_signature(index):
    cert = bytearray(ridge_certificate())
    cert[index] ^= 1
    assert verify_ridge(b"\x01" + cert) != 0


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
