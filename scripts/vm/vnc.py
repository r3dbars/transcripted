#!/usr/bin/env python3
"""Tiny dependency-free VNC client for driving the clean test VM.

Tart's `--vnc-experimental` mode exposes the VM's screen through the
Virtualization.framework VNC server. Input sent that way arrives as virtual
keyboard/mouse hardware inside the guest, so it can click macOS permission
prompts that ignore synthetic in-guest clicks. That is the whole reason this
exists: an agent can take a screenshot, look at it, and click "Allow" or
"Don't Allow" the same way a new user would.

Standard library only, so it runs on the stock macOS python3 with nothing to
install.

  vnc.py --url vnc://:PASS@127.0.0.1:PORT screenshot shot.png
  vnc.py click 640 400            # URL from $TVM_VNC_URL
  vnc.py click 640 400 --double
  vnc.py type "hello world"
  vnc.py key cmd-q
  vnc.py info
  vnc.py --self-test

Coordinates are framebuffer pixels, the same pixels as in `screenshot`.
"""

from __future__ import annotations

import argparse
import os
import socket
import struct
import sys
import time
import urllib.parse
import zlib

# --------------------------------------------------------------------------
# DES (encrypt only), needed for classic VNC password auth. Tables are the
# FIPS 46-3 ones; the self-test checks them against published vectors.
# --------------------------------------------------------------------------

_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27,
        19, 11, 3, 60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
        14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20,
        13, 2, 41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53,
        46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30,
       22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51,
       43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23,
       15, 7]
_FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54,
       22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3,
       43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57,
       25]
_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
      16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30,
      31, 32, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27,
      3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
_SBOX = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6,
     12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8,
     2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12,
     0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8,
     10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8,
     5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10,
     13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7,
     2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0,
     6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5,
     0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8,
     12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1,
     13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2,
     12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14,
     3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11,
     13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12,
     5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1,
     14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
]


def _permute(value: int, table: list[int], in_bits: int) -> int:
    out = 0
    for position in table:
        out = (out << 1) | ((value >> (in_bits - position)) & 1)
    return out


def _subkeys(key: bytes) -> list[int]:
    k = _permute(int.from_bytes(key, "big"), _PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    keys = []
    for shift in _SHIFTS:
        c = ((c << shift) | (c >> (28 - shift))) & 0xFFFFFFF
        d = ((d << shift) | (d >> (28 - shift))) & 0xFFFFFFF
        keys.append(_permute((c << 28) | d, _PC2, 56))
    return keys


def des_encrypt_block(key: bytes, block: bytes) -> bytes:
    value = _permute(int.from_bytes(block, "big"), _IP, 64)
    left, right = value >> 32, value & 0xFFFFFFFF
    for subkey in _subkeys(key):
        mixed = _permute(right, _E, 32) ^ subkey
        sbox_out = 0
        for index in range(8):
            chunk = (mixed >> (42 - 6 * index)) & 0x3F
            row = ((chunk & 0x20) >> 4) | (chunk & 1)
            col = (chunk >> 1) & 0xF
            sbox_out = (sbox_out << 4) | _SBOX[index][row * 16 + col]
        left, right = right, left ^ _permute(sbox_out, _P, 32)
    return _permute((right << 32) | left, _FP, 64).to_bytes(8, "big")


def vnc_auth_response(password: str, challenge: bytes) -> bytes:
    """VNC auth: DES-encrypt the 16-byte challenge with the password as key,
    where each key byte has its bit order reversed (a quirk of the protocol)."""
    raw = password.encode("latin-1")[:8].ljust(8, b"\0")
    key = bytes(int(f"{byte:08b}"[::-1], 2) for byte in raw)
    return des_encrypt_block(key, challenge[:8]) + des_encrypt_block(key, challenge[8:16])


# --------------------------------------------------------------------------
# PNG writer
# --------------------------------------------------------------------------


def write_png(path: str, width: int, height: int, rgb: bytes) -> None:
    stride = width * 3
    raw = bytearray()
    for row in range(height):
        raw.append(0)
        raw += rgb[row * stride:(row + 1) * stride]

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(png)
    os.replace(tmp, path)


# --------------------------------------------------------------------------
# Keysyms
# --------------------------------------------------------------------------

_NAMED_KEYS = {
    "return": 0xFF0D, "enter": 0xFF0D, "tab": 0xFF09, "escape": 0xFF1B, "esc": 0xFF1B,
    # On a Mac keyboard "delete" is backspace; forward delete is its own key.
    "backspace": 0xFF08, "delete": 0xFF08, "forwarddelete": 0xFFFF, "space": 0x0020,
    "left": 0xFF51, "up": 0xFF52, "right": 0xFF53, "down": 0xFF54,
    "home": 0xFF50, "end": 0xFF57, "pageup": 0xFF55, "pagedown": 0xFF56,
    "shift": 0xFFE1, "ctrl": 0xFFE3, "control": 0xFFE3,
    "alt": 0xFFE9, "option": 0xFFE9, "opt": 0xFFE9,
    "f1": 0xFFBE, "f2": 0xFFBF, "f3": 0xFFC0, "f4": 0xFFC1, "f5": 0xFFC2, "f6": 0xFFC3,
    "f7": 0xFFC4, "f8": 0xFFC5, "f9": 0xFFC6, "f10": 0xFFC7, "f11": 0xFFC8, "f12": 0xFFC9,
    "minus": ord("-"), "plus": ord("+"), "comma": ord(","), "period": ord("."),
}
# Which X keysym a VNC server treats as Command is not standardized. Super_L is
# the default; set TVM_VNC_CMD_KEYSYM=meta if cmd shortcuts do nothing.
_CMD_KEYSYMS = {"super": 0xFFEB, "meta": 0xFFE7}
_SHIFTED = set('~!@#$%^&*()_+{}|:"<>?ABCDEFGHIJKLMNOPQRSTUVWXYZ')
SHIFT_L = 0xFFE1


def cmd_keysym() -> int:
    return _CMD_KEYSYMS.get(os.environ.get("TVM_VNC_CMD_KEYSYM", "super").lower(), _CMD_KEYSYMS["super"])


def char_keysym(char: str) -> int:
    """Latin-1 characters are their own keysym; anything above uses the
    Unicode keysym range (0x01000000 + code point)."""
    code = ord(char)
    return code if code <= 0xFF else 0x01000000 + code


def keysym_for(name: str) -> int:
    lowered = name.lower()
    if lowered in ("cmd", "command"):
        return cmd_keysym()
    if lowered in _NAMED_KEYS:
        return _NAMED_KEYS[lowered]
    if len(name) == 1:
        return char_keysym(name)
    if lowered.startswith("0x"):
        return int(lowered, 16)
    raise ValueError(f"unknown key name: {name}")


def parse_combo(combo: str) -> list[int]:
    """'cmd-shift-4' -> [cmd, shift, '4']. A lone '-' means the minus key."""
    if combo == "-":
        return [ord("-")]
    parts = combo.split("-")
    # "cmd--" means cmd + minus
    if combo.endswith("--"):
        parts = combo[:-2].split("-") + ["-"]
    return [keysym_for(part) for part in parts if part != ""]


# --------------------------------------------------------------------------
# RFB client
# --------------------------------------------------------------------------


class VNCError(RuntimeError):
    pass


class VNCClient:
    def __init__(self, host: str, port: int, password: str | None, timeout: float = 20.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.password = password
        self.width = 0
        self.height = 0
        self.name = ""
        self.framebuffer = bytearray()
        self._handshake()

    # socket helpers
    def _recv(self, count: int) -> bytes:
        chunks = []
        remaining = count
        while remaining:
            chunk = self.sock.recv(min(remaining, 1 << 20))
            if not chunk:
                raise VNCError("VNC server closed the connection")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _recv_into(self, view: memoryview) -> None:
        while len(view):
            received = self.sock.recv_into(view, min(len(view), 1 << 20))
            if not received:
                raise VNCError("VNC server closed the connection")
            view = view[received:]

    def _reason(self) -> str:
        (length,) = struct.unpack(">I", self._recv(4))
        return self._recv(length).decode("utf-8", "replace")

    def _handshake(self) -> None:
        banner = self._recv(12)
        if not banner.startswith(b"RFB "):
            raise VNCError(f"not a VNC server: {banner!r}")
        major, minor = int(banner[4:7]), int(banner[8:11])
        version = (3, 8) if (major, minor) >= (3, 8) else (3, 7) if (major, minor) >= (3, 7) else (3, 3)
        self.sock.sendall(b"RFB 003.%03d\n" % version[1])

        if version == (3, 3):
            (security,) = struct.unpack(">I", self._recv(4))
            if security == 0:
                raise VNCError(self._reason())
        else:
            (count,) = struct.unpack(">B", self._recv(1))
            if count == 0:
                raise VNCError(self._reason())
            offered = list(self._recv(count))
            if 1 in offered and not self.password:
                security = 1
            elif 2 in offered:
                security = 2
            elif 1 in offered:
                security = 1
            else:
                raise VNCError(f"no supported VNC security type (server offered {offered})")
            self.sock.sendall(bytes([security]))

        if security == 2:
            if self.password is None:
                raise VNCError("server needs a VNC password; pass --url vnc://:PASSWORD@host:port")
            challenge = self._recv(16)
            self.sock.sendall(vnc_auth_response(self.password, challenge))
        elif security != 1:
            raise VNCError(f"unsupported VNC security type {security}")

        if security == 2 or version == (3, 8):
            (result,) = struct.unpack(">I", self._recv(4))
            if result != 0:
                reason = self._reason() if version == (3, 8) else "authentication failed"
                raise VNCError(f"VNC auth failed: {reason}")

        self.sock.sendall(b"\x01")  # shared session: don't kick other viewers
        header = self._recv(24)
        self.width, self.height = struct.unpack(">HH", header[:4])
        (name_length,) = struct.unpack(">I", header[20:24])
        self.name = self._recv(name_length).decode("utf-8", "replace")

        # 32bpp little-endian true colour, so each pixel is B, G, R, X in memory.
        pixel_format = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        self.sock.sendall(b"\x00\x00\x00\x00" + pixel_format)
        # Raw (0) plus the DesktopSize pseudo-encoding (-223) so a resize is legal.
        self.sock.sendall(struct.pack(">BxHii", 2, 2, 0, -223))
        self._resize(self.width, self.height)

    def _resize(self, width: int, height: int) -> None:
        self.width, self.height = width, height
        self.framebuffer = bytearray(width * height * 4)

    def _read_update(self, covered: list[int]) -> None:
        self._recv(1)  # padding
        (rects,) = struct.unpack(">H", self._recv(2))
        for _ in range(rects):
            x, y, w, h, encoding = struct.unpack(">HHHHi", self._recv(12))
            if encoding == 0 and (x + w > self.width or y + h > self.height):
                raise VNCError(f"server sent a rectangle outside the screen ({x},{y} {w}x{h})")
            if encoding == 0:
                row_bytes = w * 4
                if x == 0 and w == self.width:
                    start = y * self.width * 4
                    self._recv_into(memoryview(self.framebuffer)[start:start + row_bytes * h])
                else:
                    data = self._recv(row_bytes * h)
                    for row in range(h):
                        start = ((y + row) * self.width + x) * 4
                        self.framebuffer[start:start + row_bytes] = data[row * row_bytes:(row + 1) * row_bytes]
                covered[0] += w * h
            elif encoding == -223:
                self._resize(w, h)
                covered[0] = 0
                self._request(incremental=False)
            else:
                raise VNCError(f"server sent unrequested encoding {encoding}")

    def _request(self, incremental: bool) -> None:
        self.sock.sendall(struct.pack(">BBHHHH", 3, 1 if incremental else 0, 0, 0, self.width, self.height))

    def capture(self, timeout: float = 20.0) -> None:
        """Fill the framebuffer with one full-screen update."""
        covered = [0]
        deadline = time.monotonic() + timeout
        self._request(incremental=False)
        while covered[0] < self.width * self.height:
            if time.monotonic() > deadline:
                raise VNCError("timed out waiting for the screen")
            (kind,) = struct.unpack(">B", self._recv(1))
            if kind == 0:
                self._read_update(covered)
                if covered[0] < self.width * self.height:
                    self._request(incremental=False)
            elif kind == 1:  # colour map entries: skip
                self._recv(1)
                _, count = struct.unpack(">HH", self._recv(4))
                self._recv(count * 6)
            elif kind == 2:  # bell
                pass
            elif kind == 3:  # server clipboard
                self._recv(3)
                (length,) = struct.unpack(">I", self._recv(4))
                self._recv(length)
            else:
                raise VNCError(f"unknown server message {kind}")

    def rgb(self, shrink: int = 1) -> tuple[int, int, bytes]:
        fb = self.framebuffer
        if shrink <= 1:
            out = bytearray(self.width * self.height * 3)
            out[0::3] = fb[2::4]
            out[1::3] = fb[1::4]
            out[2::3] = fb[0::4]
            return self.width, self.height, bytes(out)
        width, height = self.width // shrink, self.height // shrink
        out = bytearray(width * height * 3)
        step = 4 * shrink
        for row in range(height):
            src = row * shrink * self.width * 4
            line = fb[src:src + width * step]
            dst = row * width * 3
            out[dst:dst + width * 3:3] = line[2::step]
            out[dst + 1:dst + width * 3:3] = line[1::step]
            out[dst + 2:dst + width * 3:3] = line[0::step]
        return width, height, bytes(out)

    # input
    def pointer(self, x: int, y: int, mask: int = 0) -> None:
        x = max(0, min(self.width - 1, x))
        y = max(0, min(self.height - 1, y))
        self.sock.sendall(struct.pack(">BBHH", 5, mask, x, y))

    def key(self, keysym: int, down: bool) -> None:
        self.sock.sendall(struct.pack(">BBxxI", 4, 1 if down else 0, keysym))

    def tap(self, keysyms: list[int], hold: float = 0.03) -> None:
        for keysym in keysyms:
            self.key(keysym, True)
            time.sleep(hold)
        for keysym in reversed(keysyms):
            self.key(keysym, False)
            time.sleep(hold)

    def click(self, x: int, y: int, button: int = 1, count: int = 1) -> None:
        self.pointer(x, y, 0)
        time.sleep(0.08)
        for _ in range(count):
            self.pointer(x, y, button)
            time.sleep(0.06)
            self.pointer(x, y, 0)
            time.sleep(0.06)

    def type_text(self, text: str, delay: float = 0.02) -> None:
        for char in text:
            if char == "\n":
                self.tap([_NAMED_KEYS["return"]])
            elif char == "\t":
                self.tap([_NAMED_KEYS["tab"]])
            elif char in _SHIFTED:
                self.tap([SHIFT_L, ord(char)])
            else:
                self.tap([char_keysym(char)])
            time.sleep(delay)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def parse_url(url: str) -> tuple[str, int, str | None]:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("vnc", ""):
        raise ValueError(f"expected a vnc:// URL, got {url}")
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 5900
    password = urllib.parse.unquote(parsed.password) if parsed.password else None
    return host, port, password


def is_loopback(host: str) -> bool:
    import ipaddress
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def self_test() -> int:
    # FIPS/NBS DES vector: key 133457799BBCDFF1, plaintext 0123456789ABCDEF.
    got = des_encrypt_block(bytes.fromhex("133457799BBCDFF1"), bytes.fromhex("0123456789ABCDEF"))
    assert got.hex().upper() == "85E813540F0AB405", got.hex()
    got = des_encrypt_block(bytes.fromhex("0E329232EA6D0D73"), bytes.fromhex("8787878787878787"))
    assert got.hex() == "0" * 16, got.hex()
    # VNC key bit-reversal: 'a' (0x61) reversed is 0x86.
    challenge = bytes(range(16))
    expected = des_encrypt_block(bytes([0x86, 0x46, 0xC6, 0] + [0] * 4), challenge[:8])
    assert vnc_auth_response("abc", challenge)[:8] == expected
    assert parse_combo("cmd-shift-4")[1:] == [SHIFT_L, ord("4")]
    assert parse_combo("cmd--")[-1] == ord("-")
    assert parse_url("vnc://:p%40ss@127.0.0.1:5901") == ("127.0.0.1", 5901, "p@ss")
    assert is_loopback("127.0.0.1") and is_loopback("::1") and not is_loopback("192.168.64.2")
    assert keysym_for("delete") == 0xFF08 and keysym_for("forwarddelete") == 0xFFFF
    assert char_keysym("é") == 0xE9 and char_keysym("€") == 0x010020AC
    # PNG round trip header check.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "x.png")
        write_png(path, 2, 1, bytes([255, 0, 0, 0, 255, 0]))
        with open(path, "rb") as handle:
            data = handle.read()
        assert data.startswith(b"\x89PNG") and b"IEND" in data
    print("vnc.py self-test: ok")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("TVM_VNC_URL"), help="vnc://:PASSWORD@HOST:PORT (default $TVM_VNC_URL)")
    parser.add_argument("--allow-remote", action="store_true", help="allow a non-loopback VNC host (off by default)")
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="command")

    shot = sub.add_parser("screenshot", help="save the screen as PNG")
    shot.add_argument("path")
    shot.add_argument("--shrink", type=int, default=1, help="integer downscale factor (2 = half size)")

    sub.add_parser("info", help="print screen size and server name")

    click = sub.add_parser("click", help="click at framebuffer pixel X Y")
    click.add_argument("x", type=int)
    click.add_argument("y", type=int)
    click.add_argument("--button", choices=["left", "middle", "right"], default="left")
    click.add_argument("--double", action="store_true")

    move = sub.add_parser("move", help="move the pointer")
    move.add_argument("x", type=int)
    move.add_argument("y", type=int)

    drag = sub.add_parser("drag", help="drag from X1 Y1 to X2 Y2")
    for name in ("x1", "y1", "x2", "y2"):
        drag.add_argument(name, type=int)

    scroll = sub.add_parser("scroll", help="scroll at X Y")
    scroll.add_argument("x", type=int)
    scroll.add_argument("y", type=int)
    scroll.add_argument("direction", choices=["up", "down"])
    scroll.add_argument("--steps", type=int, default=3)

    typ = sub.add_parser("type", help="type text (US layout)")
    typ.add_argument("text")

    key = sub.add_parser("key", help="press key combos, e.g. cmd-q return cmd-shift-4")
    key.add_argument("combos", nargs="+")

    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.command:
        parser.print_help()
        return 2
    if not args.url:
        print("vnc.py: no VNC URL; pass --url or set TVM_VNC_URL", file=sys.stderr)
        return 2

    host, port, password = parse_url(args.url)
    if not args.allow_remote and not is_loopback(host):
        print(f"vnc.py: refusing non-local VNC host {host} (Tart's VNC is always 127.0.0.1; pass --allow-remote to override)", file=sys.stderr)
        return 2
    client = VNCClient(host, port, password)
    try:
        if args.command == "info":
            print(f"{client.width}x{client.height} {client.name}")
        elif args.command == "screenshot":
            client.capture()
            width, height, rgb = client.rgb(max(1, args.shrink))
            write_png(args.path, width, height, rgb)
            print(f"{args.path} {width}x{height}")
        elif args.command == "click":
            button = {"left": 1, "middle": 2, "right": 4}[args.button]
            client.click(args.x, args.y, button=button, count=2 if args.double else 1)
        elif args.command == "move":
            client.pointer(args.x, args.y, 0)
        elif args.command == "drag":
            client.pointer(args.x1, args.y1, 0)
            time.sleep(0.08)
            client.pointer(args.x1, args.y1, 1)
            steps = 12
            for step in range(1, steps + 1):
                time.sleep(0.03)
                client.pointer(args.x1 + (args.x2 - args.x1) * step // steps,
                               args.y1 + (args.y2 - args.y1) * step // steps, 1)
            client.pointer(args.x2, args.y2, 0)
        elif args.command == "scroll":
            mask = 8 if args.direction == "up" else 16
            client.pointer(args.x, args.y, 0)
            for _ in range(args.steps):
                client.pointer(args.x, args.y, mask)
                client.pointer(args.x, args.y, 0)
                time.sleep(0.05)
        elif args.command == "type":
            client.type_text(args.text)
        elif args.command == "key":
            for combo in args.combos:
                client.tap(parse_combo(combo))
                time.sleep(0.08)
        # Give the server a beat to process input before the socket closes.
        time.sleep(0.15)
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (VNCError, OSError, ValueError) as error:
        print(f"vnc.py: {error}", file=sys.stderr)
        sys.exit(1)
