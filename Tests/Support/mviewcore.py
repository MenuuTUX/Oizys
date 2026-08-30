"""ctypes bindings to libMViewCore.dylib.

The tests drive the real driver code rather than a reimplementation of it. Everything the
suite touches goes through this module, so there is one place where an argument type is
declared and one place a signature change breaks.

The library is built by the MViewCoreDylib target. `python3 Tools/test.py` builds it first;
importing this module without it raises with the command to run.
"""
from __future__ import annotations

import ctypes
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent

STRIP_W = 64
STRIP_H = 16
MAX_STRIPS = 30 * 68
DOCK_BUFFERS = 2
DAMAGE_REPEATS = DOCK_BUFFERS + 1
MACRO_STRIPS = 4

# Codebook ceilings, spelled out rather than read from the library. A decoder that imported
# the encoder's constants could not catch the encoder using the wrong one, which is the bug
# these caught the first time.
CAP_SYNC = 7
CAP_DC = 10
CAP_AC = 10
CAP_AC_LUMA = 9


def _find_library() -> pathlib.Path:
    # An explicit path wins, so a sanitiser or coverage build can be selected without
    # touching the tests. Tools/test.py sets this.
    override = os.environ.get("MVIEW_DYLIB")
    if override:
        path = pathlib.Path(override)
        if not path.exists():
            raise RuntimeError(f"MVIEW_DYLIB points at {path}, which does not exist")
        return path
    candidates = [
        ROOT / "build" / "Release" / "libMViewCore.dylib",
        ROOT / "build" / "Debug" / "libMViewCore.dylib",
    ]
    derived = subprocess.run(
        ["xcodebuild", "-project", str(ROOT / "MView.xcodeproj"),
         "-target", "MViewCoreDylib", "-configuration", "Release", "-showBuildSettings"],
        capture_output=True, text=True, cwd=ROOT,
    )
    for line in derived.stdout.splitlines():
        if "BUILT_PRODUCTS_DIR" in line:
            candidates.append(pathlib.Path(line.split("=", 1)[1].strip()) / "libMViewCore.dylib")
    for path in candidates:
        if path.exists():
            return path
    raise RuntimeError(
        "libMViewCore.dylib not found. Build it with:\n"
        "  xcodebuild -project MView.xcodeproj -target MViewCoreDylib -configuration Release build"
    )


LIBRARY_PATH = _find_library()
lib = ctypes.CDLL(str(LIBRARY_PATH))


class Strip(ctypes.Structure):
    _fields_ = [("col", ctypes.c_uint32), ("row", ctypes.c_uint32),
                ("x", ctypes.c_uint32), ("y", ctypes.c_uint32),
                ("w", ctypes.c_uint32), ("h", ctypes.c_uint32)]

    def __repr__(self):
        return f"Strip(col={self.col}, row={self.row}, {self.w}x{self.h} at {self.x},{self.y})"


class DamageMap(ctypes.Structure):
    _fields_ = [
        ("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
        ("cols", ctypes.c_uint32), ("rows", ctypes.c_uint32),
        ("hashes", ctypes.c_uint64 * MAX_STRIPS),
        ("pending", ctypes.c_uint64 * MAX_STRIPS),
        ("debt", ctypes.c_uint8 * MAX_STRIPS),
        ("keyframe_owed", ctypes.c_uint8),
    ]


class DL3Profile(ctypes.Structure):
    _fields_ = [("product_id", ctypes.c_uint16), ("head_count", ctypes.c_uint8),
                ("video_endpoint", ctypes.c_uint8 * 2), ("ddc_selector", ctypes.c_uint8 * 2)]


_u8p = ctypes.POINTER(ctypes.c_uint8)
_i32p = ctypes.POINTER(ctypes.c_int32)

_SIGNATURES = {
    # encoder
    "mview_video_colour_strip_bgra": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint16, ctypes.c_uint16, _u8p,
        ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]),
    "mview_video_colour_strip_planes": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint16, ctypes.c_uint16, _i32p]),
    "mview_quantize_reference": (ctypes.c_int32, [
        ctypes.c_uint, ctypes.c_uint, ctypes.c_int32]),
    "mview_scan_index": (ctypes.c_uint, [ctypes.c_uint, ctypes.c_uint]),
    "mview_inverse_scan": (ctypes.c_uint, [ctypes.c_uint]),
    "mview_encode_selftest": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint]),
    # damage ledger
    "mview_damage_init": (None, [ctypes.POINTER(DamageMap), ctypes.c_uint32, ctypes.c_uint32]),
    "mview_damage_geom": (Strip, [ctypes.POINTER(DamageMap), ctypes.c_uint32, ctypes.c_uint32]),
    "mview_damage_plan": (ctypes.c_int, [
        ctypes.POINTER(DamageMap), _u8p, ctypes.c_size_t, ctypes.POINTER(Strip),
        ctypes.c_int, ctypes.POINTER(ctypes.c_int)]),
    "mview_damage_owed": (ctypes.c_int, [
        ctypes.POINTER(DamageMap), ctypes.POINTER(Strip), ctypes.c_int]),
    "mview_damage_presented": (None, [ctypes.POINTER(DamageMap)]),
    "mview_damage_update": (ctypes.c_int, [
        ctypes.POINTER(DamageMap), _u8p, ctypes.c_size_t, ctypes.POINTER(Strip), ctypes.c_int]),
    # crypto
    "mview_aes_cmac": (None, [_u8p, _u8p, ctypes.c_size_t, _u8p]),
    "mview_aes_ctr_xor": (None, [_u8p, _u8p, ctypes.c_uint32, _u8p, _u8p, ctypes.c_size_t]),
    "mview_hmac_sha256": (None, [_u8p, ctypes.c_size_t, _u8p, ctypes.c_size_t, _u8p]),
    "mview_hdcp_random": (None, [ctypes.c_void_p, ctypes.c_size_t]),
    "mview_hdcp_derive_kd": (None, [_u8p, _u8p, _u8p, _u8p]),
    "mview_hdcp_compute_h": (None, [_u8p, _u8p, ctypes.c_int, _u8p]),
    "mview_hdcp_compute_l": (None, [_u8p, _u8p, _u8p, _u8p]),
    "mview_hdcp_rsa_oaep_encrypt": (ctypes.c_int, [_u8p, _u8p, _u8p, _u8p]),
    # protocol
    "mview_cp_session_key": (None, [_u8p, _u8p]),
    "mview_dl3_parse_ridge_edid": (ctypes.c_int, [
        _u8p, ctypes.c_size_t, _u8p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]),
    "mview_dl3_header": (None, [
        _u8p, ctypes.c_uint32, ctypes.c_uint16, ctypes.c_uint16, ctypes.c_uint32,
        ctypes.c_size_t]),
    "mview_dl3_profile": (ctypes.POINTER(DL3Profile), [ctypes.c_uint16]),
    "mview_dl3_init_0": (ctypes.c_size_t, [_u8p, ctypes.c_size_t]),
    "mview_dl3_init_25": (ctypes.c_size_t, [_u8p, ctypes.c_size_t]),
    "mview_dl3_init_4_probe": (ctypes.c_size_t, [_u8p, ctypes.c_size_t]),
    "mview_dl3_set_mode_1080p60": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint16, ctypes.c_uint8]),
    "mview_hdcp_session_ack": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]),
    "mview_hdcp_ake_init": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32, _u8p]),
    "mview_hdcp_ake_txinfo": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]),
    "mview_hdcp_ake_no_stored_km": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32, _u8p]),
    "mview_hdcp_lc_init": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32, _u8p]),
    "mview_hdcp_ske_send_eks": (ctypes.c_size_t, [
        _u8p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32, _u8p, _u8p]),
    "mview_hdcp_stream_manage": (ctypes.c_size_t, [_u8p, ctypes.c_size_t, ctypes.c_uint32,
                                                   ctypes.c_uint32]),
    # profiler
    "mview_profile_enable": (None, [ctypes.c_int]),
    "mview_profile_reset": (None, []),
    "mview_profile_report": (None, [ctypes.c_char_p]),
    "mview_profile_total_ms": (ctypes.c_double, [ctypes.c_int]),
    "mview_profile_calls": (ctypes.c_uint64, [ctypes.c_int]),
    "mview_profile_push": (ctypes.c_uint64, [ctypes.c_int]),
    "mview_profile_pop": (None, [ctypes.c_int, ctypes.c_uint64]),
}

for _name, (_restype, _argtypes) in _SIGNATURES.items():
    _fn = getattr(lib, _name)
    _fn.restype = _restype
    _fn.argtypes = _argtypes


def buffer(size: int, fill: int = 0) -> ctypes.Array:
    """A uint8 array, filled with a poison byte by default so a short write is visible."""
    array = (ctypes.c_uint8 * size)()
    if fill:
        ctypes.memset(array, fill, size)
    return array


def as_u8(data: bytes | bytearray | ctypes.Array):
    """Anything byte-like as a uint8 pointer ctypes will accept."""
    if isinstance(data, ctypes.Array):
        return ctypes.cast(data, _u8p)
    array = (ctypes.c_uint8 * len(data)).from_buffer_copy(bytes(data))
    return ctypes.cast(array, _u8p)


def encode_strip(surface: bytes, stride: int, width: int, height: int,
                 x: int = 0, y: int = 0, capacity: int = 16384) -> bytes:
    """One colour strip. Returns b"" when the encoder declines, which it does when the
    output would not fit."""
    out = buffer(capacity, fill=0xC3)
    source = as_u8(surface)
    length = lib.mview_video_colour_strip_bgra(
        ctypes.cast(out, _u8p), capacity, x, y, source, stride, width, height)
    return bytes(out[:length]) if length else b""


def encode_strip_checked(surface: bytes, stride: int, width: int, height: int,
                         x: int = 0, y: int = 0, capacity: int = 16384):
    """As encode_strip, but also reports whether anything was written past `capacity`."""
    guard = 64
    out = buffer(capacity + guard, fill=0xC3)
    length = lib.mview_video_colour_strip_bgra(
        ctypes.cast(out, _u8p), capacity, x, y, as_u8(surface), stride, width, height)
    overran = any(out[i] != 0xC3 for i in range(capacity, capacity + guard))
    return bytes(out[:length]) if length else b"", overran
