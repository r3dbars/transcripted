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

One connection per VM: Apple's VNC server behind `--vnc-experimental` crashed
tart (an assertion in -[_VZVNCServer _setupVirtualMachineAccessor]) on a new
client connection after Transcripted launched, on both real runs. So the VM
script starts `vnc.py serve`, which connects once when the VM boots and keeps
that connection for the VM's whole life. Every other command goes through
its local socket (--socket, or $TVM_VNC_SOCKET) instead of reconnecting:

  vnc.py --socket /path/vm.vncsock serve      # URL from $TVM_VNC_URL
  vnc.py --socket /path/vm.vncsock screenshot shot.png
"""

from __future__ import annotations

import argparse
import json
import select
import os
import socket
import stat
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
        keysym = int(lowered, 16)
        if not 0 <= keysym <= 0xFFFFFFFF:
            raise ValueError(f"keysym out of range: {name}")
        return keysym
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
# Finding the default button


def find_default_button(width: int, height: int, bgrx: bytes, step: int = 2,
                        within: tuple[int, int, int, int] | None = None) -> tuple[int, int] | None:
    """Centre of the blue default button on screen (the "Open" in the
    "downloaded from the Internet" prompt), or None.

    Looks for a solid, pill-shaped patch of macOS's accent blue above the
    Dock. Icons, wallpaper and window chrome don't match its colour, size and
    shape together. `within` (left, top, width, height in framebuffer pixels)
    only accepts a button whose centre is inside that window.
    """
    cols, rows = width // step, int(height * 0.85) // step
    mask = bytearray(cols * rows)
    stride = 4 * step
    for row in range(rows):
        start = row * step * width * 4
        line = bgrx[start:start + cols * stride]
        blue, green, red = line[0::stride], line[1::stride], line[2::stride]
        base = row * cols
        for col in range(len(blue)):
            b, g = blue[col], green[col]
            if b >= 200 and red[col] <= 90 and 90 <= g <= 175 and b - g >= 60:
                mask[base + col] = 1
    best = None
    for seed in range(len(mask)):
        if mask[seed] != 1:
            continue
        mask[seed] = 2
        stack, count = [seed], 0
        left, top, right, bottom = cols, rows, -1, -1
        while stack:
            index = stack.pop()
            count += 1
            row, col = divmod(index, cols)
            left, right = min(left, col), max(right, col)
            top, bottom = min(top, row), max(bottom, row)
            for near in ((index - 1) if col else -1, (index + 1) if col + 1 < cols else -1,
                         index - cols, index + cols):
                if 0 <= near < len(mask) and mask[near] == 1:
                    mask[near] = 2
                    stack.append(near)
        box_w, box_h = right - left + 1, bottom - top + 1
        if not (0.02 * cols <= box_w <= 0.25 * cols and 0.012 * rows <= box_h <= 0.1 * rows):
            continue
        if not (1.8 <= box_w / box_h <= 9) or count < 0.7 * box_w * box_h:
            continue
        x, y = (left + right) * step // 2, (top + bottom) * step // 2
        if within and not (within[0] <= x < within[0] + within[2] and within[1] <= y < within[1] + within[3]):
            continue
        if best is None or count > best[0]:
            best = (count, x, y)
    return None if best is None else (best[1], best[2])


def parse_window(text: str, points_wide: int, pixels_wide: int) -> tuple[int, int, int, int]:
    """'X,Y,W,H' in screen points (what macOS's window list reports) ->
    the same box in framebuffer pixels."""
    try:
        box = [float(part) for part in text.split(",")]
    except ValueError:
        box = []
    if len(box) != 4 or box[2] <= 0 or box[3] <= 0 or points_wide <= 0:
        raise CommandError(f"bad window box {text!r} (want X,Y,W,H in points and --points-wide)")
    scale = pixels_wide / points_wide
    return tuple(round(value * scale) for value in box)


# --------------------------------------------------------------------------
# RFB client
# --------------------------------------------------------------------------


class VNCError(RuntimeError):
    pass


class CommandError(VNCError):
    """One command failed, but the VNC connection is still in sync and usable."""


# How long a screenshot waits for the screen before giving up on that command.
CAPTURE_TIMEOUT = 20.0


class VNCClient:
    def __init__(self, host: str, port: int, password: str | None, timeout: float = 20.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.password = password
        self.width = 0
        self.height = 0
        self.name = ""
        self.framebuffer = bytearray()
        # Full-screen requests sent but not yet answered by an update message.
        self.outstanding = 0
        self.resized = False
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
                # The screen changed size; capture() asks for the new screen.
                self._resize(w, h)
                covered[0] = 0
                self.resized = True
            else:
                raise VNCError(f"server sent unrequested encoding {encoding}")

    def _request(self, incremental: bool) -> None:
        self.sock.sendall(struct.pack(">BBHHHH", 3, 1 if incremental else 0, 0, 0, self.width, self.height))
        self.outstanding += 1

    def _readable(self, wait: float) -> bool:
        return bool(select.select([self.sock], [], [], max(0.0, wait))[0])

    def drain(self, quiet: float = 0.1, limit: float = 1.0) -> None:
        """Apply whatever the server sent (or is still sending) for earlier
        requests, so an old frame can't pass for the next screenshot."""
        end = time.monotonic() + limit
        while True:
            left = end - time.monotonic()
            wait = left if self.outstanding else min(quiet, left)
            if wait <= 0 or not self._readable(wait):
                break
            self.read_message([0])
        self.outstanding = 0

    def read_message(self, covered: list[int]) -> int:
        """Read one server message; returns its type."""
        (kind,) = struct.unpack(">B", self._recv(1))
        if kind == 0:
            self.outstanding = max(0, self.outstanding - 1)
            self._read_update(covered)
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
        return kind

    def capture(self, timeout: float | None = None) -> None:
        """Fill the framebuffer with one full-screen update.

        A timeout raises CommandError: it only ever stops between messages,
        so the connection stays in sync and the next command can use it.
        """
        self.drain()
        deadline = time.monotonic() + (CAPTURE_TIMEOUT if timeout is None else timeout)
        self.resized = False
        covered = [0]
        self._request(incremental=False)
        while covered[0] < self.width * self.height:
            left = deadline - time.monotonic()
            if left <= 0:
                raise CommandError("timed out waiting for the screen (the VNC session is still open)")
            if self._readable(min(left, 0.5)):
                self.read_message(covered)
                if self.resized:
                    self.resized = False
                    if covered[0] < self.width * self.height and not self.outstanding:
                        self._request(incremental=False)  # ask for the whole new screen
            elif not self.outstanding:
                # Part of the screen came, then nothing: ask for the rest. Never
                # while a request is still unanswered, or the extra answers
                # would spill into the next screenshot.
                self._request(incremental=False)

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


def _fake_vnc_server(events: list[str], conns: list[socket.socket],
                     mode: dict | None = None) -> tuple[socket.socket, int]:
    """A minimal RFB 3.8 server (no auth, 4x2 screen) that logs what it gets.

    Every pixel's value is the number of key/pointer events so far, so a
    screenshot shows whether it was taken after the input. `mode` (changeable
    while running): "split" sends each frame one row per message, "resize"
    (once) answers a request with only a resize to 2x2, "stall" answers nothing.
    """
    import threading
    mode = {} if mode is None else mode
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)

    def recv_exact(conn: socket.socket, count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = conn.recv(count - len(data))
            if not chunk:
                raise OSError("client went away")
            data += chunk
        return data

    def handle(conn: socket.socket) -> None:
        with conn:
            conn.sendall(b"RFB 003.008\n")
            recv_exact(conn, 12)
            conn.sendall(b"\x01\x01")
            recv_exact(conn, 1)
            conn.sendall(b"\x00\x00\x00\x00")
            recv_exact(conn, 1)
            conn.sendall(struct.pack(">HH", 4, 2) + bytes(16) + struct.pack(">I", 4) + b"fake")
            size, inputs = [4, 2], [0]
            while True:
                try:
                    (kind,) = recv_exact(conn, 1)
                except OSError:
                    return
                if kind == 0:
                    recv_exact(conn, 19)
                elif kind == 2:
                    (count,) = struct.unpack(">xH", recv_exact(conn, 3))
                    recv_exact(conn, 4 * count)
                elif kind == 3:
                    recv_exact(conn, 9)
                    events.append("update")
                    if mode.get("stall"):
                        continue
                    conn.sendall(b"\x02")  # an unsolicited bell first, like a real server may send
                    if mode.pop("resize", False):
                        size[:] = [2, 2]
                        conn.sendall(struct.pack(">BxHHHHHi", 0, 1, 0, 0, 2, 2, -223))
                        continue
                    width, height = size
                    pixel = bytes([inputs[0] % 256] * 3 + [0])
                    rows = [(row, 1) for row in range(height)] if mode.get("split") else [(0, height)]
                    for top, count in rows:
                        conn.sendall(struct.pack(">BxHHHHHi", 0, 1, 0, top, width, count, 0) + pixel * (width * count))
                elif kind == 4:
                    down, keysym = struct.unpack(">BxxI", recv_exact(conn, 7))
                    events.append(f"key {keysym:x} {'down' if down else 'up'}")
                    inputs[0] += 1
                elif kind == 5:
                    recv_exact(conn, 5)
                    events.append("pointer")
                    inputs[0] += 1
                else:
                    return

    def accept_loop() -> None:
        while True:
            try:
                conn, _ = listener.accept()
            except OSError:
                return
            events.append("connect")
            conns.append(conn)
            threading.Thread(target=handle, args=(conn,), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()
    return listener, listener.getsockname()[1]


def _self_test_serve(tmp: str) -> None:
    """`serve` keeps ONE connection and runs every command over it."""
    import threading
    events: list[str] = []
    conns: list[socket.socket] = []
    mode: dict = {}
    listener, port = _fake_vnc_server(events, conns, mode)
    path = os.path.join(tmp, "vm.vncsock")
    result: list[int] = []
    server = threading.Thread(target=lambda: result.append(serve("127.0.0.1", port, None, path)), daemon=True)
    server.start()
    deadline = time.monotonic() + 5
    while not os.path.exists(path):
        assert time.monotonic() < deadline, "serve never opened its socket"
        time.sleep(0.02)
    shot = os.path.join(tmp, "shot.png")
    parser = build_parser()
    for argv in (["screenshot", shot], ["key", "cmd-q"], ["click", "1", "1"], ["screenshot", shot]):
        assert via_socket(path, parser.parse_args(argv)) == 0, argv
    with open(shot, "rb") as handle:
        assert handle.read().startswith(b"\x89PNG")
    assert events.count("connect") == 1, events
    assert events.count("update") == 2 and "key 71 down" in events and "pointer" in events, events
    # Anything but a screen command is refused, and the session stays up.
    assert via_socket(path, argparse.Namespace(command="serve")) == 1
    assert via_socket(path, parser.parse_args(["info"])) == 0
    # Client-side trouble fails only that request; the session stays up.
    assert via_socket(path, parser.parse_args(["screenshot", os.path.join(tmp, "no", "dir.png")])) == 1
    for payload in (b"", b'{"args": {"command": "screenshot"', b"\xff\n"):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.connect(path)
        conn.sendall(payload)
        conn.close()  # hangs up before (or instead of) sending a whole request
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.connect(path)
    conn.sendall(json.dumps({"args": vars(parser.parse_args(["key", "a"]))}).encode() + b"\n")
    conn.close()  # gone before the reply
    assert via_socket(path, parser.parse_args(["screenshot", shot])) == 0
    # No blue default button on the fake screen: that command fails, the session stays.
    assert via_socket(path, parser.parse_args(["click-default-button", "--dry-run"])) == 1
    # Values the wire format can't carry fail that command before anything is sent.
    for argv in (["key", "0x100000000"], ["key", "cmd-0x100000000"]):
        assert via_socket(path, parser.parse_args(argv)) == 1, argv
    # A second serve on the same path is refused and leaves the first alone.
    assert serve("127.0.0.1", port, None, path) == 1 and os.path.exists(path)
    # A screen that doesn't answer fails that screenshot only.
    global CAPTURE_TIMEOUT
    saved, CAPTURE_TIMEOUT = CAPTURE_TIMEOUT, 0.5
    try:
        mode["stall"] = True
        assert via_socket(path, parser.parse_args(["screenshot", shot])) == 1
        mode["stall"] = False
        assert via_socket(path, parser.parse_args(["screenshot", shot])) == 0
    finally:
        CAPTURE_TIMEOUT = saved
    assert events.count("connect") == 1 and server.is_alive(), events
    # When the VNC server goes away (the VM stopped), serve exits and cleans up.
    listener.close()
    for conn in conns:
        conn.shutdown(socket.SHUT_RDWR)
    server.join(5)
    assert not server.is_alive() and result == [1] and not os.path.exists(path), result


def _self_test_default_button() -> None:
    """The blue default button is found; blue icons in the Dock, a blue sky
    and small blue things are not mistaken for it."""
    width, height = 400, 250
    sky, white, accent = bytes([230, 170, 90, 0]), bytes([245, 245, 245, 0]), bytes([255, 132, 10, 0])
    fb = bytearray(sky * (width * height))

    def fill(x0: int, y0: int, x1: int, y1: int, pixel: bytes) -> None:
        for y in range(y0, y1):
            fb[(y * width + x0) * 4:(y * width + x1) * 4] = pixel * (x1 - x0)

    for x in range(20, 380, 30):
        fill(x, 225, x + 20, 245, accent)  # Dock icons: below the cut-off
    fill(20, 20, 26, 26, accent)          # a small blue dot
    assert find_default_button(width, height, bytes(fb)) is None
    fill(150, 60, 260, 150, white)        # the prompt
    fill(165, 125, 200, 137, white)       # Cancel
    fill(210, 125, 250, 137, accent)      # Open
    x, y = find_default_button(width, height, bytes(fb))
    assert 225 <= x <= 235 and 128 <= y <= 134, (x, y)
    # Only the prompt's window counts: a bigger blue button elsewhere is ignored.
    fill(10, 50, 110, 90, white)
    fill(20, 60, 90, 80, accent)
    assert find_default_button(width, height, bytes(fb))[0] < 100
    x, y = find_default_button(width, height, bytes(fb), within=(150, 60, 110, 90))
    assert 225 <= x <= 235 and 128 <= y <= 134, (x, y)
    assert find_default_button(width, height, bytes(fb), within=(150, 60, 50, 50)) is None
    # Window boxes come in screen points; the framebuffer may be 2x.
    assert parse_window("75,30,55,45", 200, 400) == (150, 60, 110, 90)
    for bad in ("1,2,3", "a,b,c,d", "1,2,0,4"):
        try:
            parse_window(bad, 200, 400)
        except CommandError:
            continue
        raise AssertionError(bad)


def _self_test_fresh_frames() -> None:
    """A screenshot after input shows the screen after that input, even when
    the server splits frames or resizes (no answer to an old request is left
    over to pass for the next screenshot)."""
    for mode in ({"split": True}, {"resize": True}, {"resize": True, "split": True}):
        events: list[str] = []
        conns: list[socket.socket] = []
        listener, port = _fake_vnc_server(events, conns, dict(mode))
        client = VNCClient("127.0.0.1", port, None)
        try:
            for inputs in range(3):
                client.capture(timeout=5)
                assert client.framebuffer[0] == inputs, (mode, inputs, client.framebuffer[0])
                client.pointer(0, 0, 0)
        finally:
            client.close()
            listener.close()


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
        import contextlib
        import io
        _self_test_fresh_frames()
        _self_test_default_button()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            _self_test_serve(tmp)
    print("vnc.py self-test: ok")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("TVM_VNC_URL"), help="vnc://:PASSWORD@HOST:PORT (default $TVM_VNC_URL)")
    parser.add_argument("--allow-remote", action="store_true", help="allow a non-loopback VNC host (off by default)")
    parser.add_argument("--socket", default=os.environ.get("TVM_VNC_SOCKET"),
                        help="send the command to a running `serve` instead of connecting (default $TVM_VNC_SOCKET)")
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="command")

    shot = sub.add_parser("screenshot", help="save the screen as PNG")
    shot.add_argument("path")
    shot.add_argument("--shrink", type=int, default=1, help="integer downscale factor (2 = half size)")

    sub.add_parser("info", help="print screen size and server name")

    sub.add_parser("serve", help="hold one connection and take commands on --socket")

    click = sub.add_parser("click", help="click at framebuffer pixel X Y")
    click.add_argument("x", type=int)
    click.add_argument("y", type=int)
    click.add_argument("--button", choices=["left", "middle", "right"], default="left")
    click.add_argument("--double", action="store_true")

    default = sub.add_parser("click-default-button",
                             help='click the blue default button on screen (e.g. "Open" in a prompt)')
    default.add_argument("--dry-run", action="store_true", help="only say where it is")
    default.add_argument("--within", metavar="X,Y,W,H",
                         help="only a button inside this window (screen points, from macOS's window list)")
    default.add_argument("--points-wide", type=int, help="screen width in points, to scale --within")

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

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.command:
        parser.print_help()
        return 2
    if args.command == "serve" and not args.socket:
        print("vnc.py: serve needs --socket", file=sys.stderr)
        return 2
    if args.command != "serve" and args.socket:
        # Never fall back to a direct connection: a second VNC client is what crashed tart.
        if not os.path.exists(args.socket):
            print(f"vnc.py: no VNC session at {args.socket}", file=sys.stderr)
            return 1
        return via_socket(args.socket, args)
    if not args.url:
        print("vnc.py: no VNC URL; pass --url or set TVM_VNC_URL", file=sys.stderr)
        return 2

    host, port, password = parse_url(args.url)
    if not args.allow_remote and not is_loopback(host):
        print(f"vnc.py: refusing non-local VNC host {host} (Tart's VNC is always 127.0.0.1; pass --allow-remote to override)", file=sys.stderr)
        return 2
    if args.command == "serve":
        return serve(host, port, password, args.socket)
    client = VNCClient(host, port, password)
    try:
        print(run_command(client, args), end="")
    finally:
        client.close()
    return 0


def run_command(client: VNCClient, args: argparse.Namespace) -> str:
    """Run one command on a connected client; returns what it prints."""
    out = ""
    if args.command == "info":
        out = f"{client.width}x{client.height} {client.name}\n"
    elif args.command == "screenshot":
        client.capture()
        width, height, rgb = client.rgb(max(1, args.shrink))
        try:
            write_png(args.path, width, height, rgb)
        except OSError as error:
            raise CommandError(f"could not save {args.path}: {error.strerror or error}") from error
        out = f"{args.path} {width}x{height}\n"
    elif args.command == "click-default-button":
        client.capture()
        within = None
        if args.within:
            within = parse_window(args.within, args.points_wide or 0, client.width)
        spot = find_default_button(client.width, client.height, bytes(client.framebuffer), within=within)
        if spot is None:
            raise CommandError("no blue default button " + ("in that window" if within else "on screen"))
        if not args.dry_run:
            client.click(*spot)
        out = f"{'found' if args.dry_run else 'clicked'} the default button at {spot[0]} {spot[1]}\n"
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
    # Give the server a beat to process input before replying or closing.
    time.sleep(0.15)
    return out


def serve(host: str, port: int, password: str | None, path: str) -> int:
    """Hold one VNC connection and run commands sent over a local socket.

    Exits when the VNC server goes away (the VM stopped), removing the socket.
    Between commands it keeps reading whatever the server sends (bells,
    clipboard) so nothing piles up on the connection. A bad request, a
    client that hangs up or goes quiet, or a failed command only fails that
    one request: the session can't reconnect, so only a broken VNC link ends it.
    """
    # Bind first: a VNC connection opened for nothing is the event that crashed tart.
    try:
        listener = _bind_socket(path)
    except (VNCError, OSError) as error:
        print(f"vnc.py serve: can't listen on {path}: {error}", flush=True)
        return 1
    inode = os.stat(path).st_ino
    client = None
    try:
        client = VNCClient(host, port, password)
        print(f"vnc.py serve: connected {client.width}x{client.height} {client.name}; socket {path}", flush=True)
        while True:
            readable, _, _ = select.select([listener, client.sock], [], [])
            if client.sock in readable:
                client.read_message([0])  # raises when the server closes
            if listener in readable:
                conn, _ = listener.accept()
                with conn:
                    _serve_request(client, conn)
    except (VNCError, OSError) as error:
        what = "VNC connection ended" if client else "could not connect to VNC"
        print(f"vnc.py serve: {what}: {error}", flush=True)
        return 1
    finally:
        if client:
            client.close()
        listener.close()
        try:
            if os.lstat(path).st_ino == inode:
                os.unlink(path)
        except OSError:
            pass


def _bind_socket(path: str) -> socket.socket:
    """Listen on PATH (mode 0700), replacing only a stale socket left there."""
    if os.path.lexists(path):
        if not stat.S_ISSOCK(os.lstat(path).st_mode):
            raise VNCError(f"{path} exists and is not a socket")
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(path)
        except OSError:
            os.unlink(path)  # nobody answers: left over from a session that died
        else:
            raise VNCError(f"another vnc.py serve is already running on {path}")
        finally:
            probe.close()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old_umask = os.umask(0o077)
    try:
        listener.bind(path)
    except OSError:
        listener.close()
        raise
    finally:
        os.umask(old_umask)
    listener.listen(4)
    return listener


def _serve_request(client: VNCClient, conn: socket.socket) -> None:
    """Run one request. Only an error on the VNC link itself propagates."""
    conn.settimeout(30.0)
    reply = {"ok": False, "out": "", "err": ""}
    try:
        line = _read_line(conn)
    except OSError:
        return  # the client went quiet or hung up; drop it
    except ValueError as error:
        reply["err"] = str(error)
        _send_reply(conn, reply)
        return
    try:
        request = json.loads(line)
        args = argparse.Namespace(**request["args"])
        if getattr(args, "command", None) not in SCREEN_COMMANDS:
            raise ValueError("send one screen command")
        reply = {"ok": True, "out": run_command(client, args), "err": ""}
    except CommandError as error:
        reply["err"] = str(error)
    except (VNCError, OSError) as error:
        reply["err"] = f"the VNC connection ended: {error}"
        _send_reply(conn, reply)
        raise
    except (ValueError, KeyError, TypeError, AttributeError, struct.error) as error:
        # All raised before anything is sent (packing comes first), so the link is still in sync.
        reply["err"] = str(error) or type(error).__name__
    _send_reply(conn, reply)


def _send_reply(conn: socket.socket, reply: dict) -> None:
    try:
        conn.sendall((json.dumps(reply) + "\n").encode())
    except OSError:
        pass  # the client gave up waiting; the command itself still ran


def _read_line(conn: socket.socket) -> str:
    data = b""
    while not data.endswith(b"\n"):
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
        if len(data) > 1 << 20:
            raise ValueError("request too large")
    return data.decode("utf-8")


SCREEN_COMMANDS = ("info", "screenshot", "click", "click-default-button", "move", "drag", "scroll", "type", "key")


def via_socket(path: str, args: argparse.Namespace) -> int:
    """Send one parsed command to a running `vnc.py serve`."""
    fields = {k: v for k, v in vars(args).items() if k not in ("url", "socket", "allow_remote", "self_test")}
    if fields.get("command") == "screenshot":
        fields["path"] = os.path.abspath(fields["path"])
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(120.0)
    try:
        conn.connect(path)
        conn.sendall((json.dumps({"args": fields}) + "\n").encode())
        line = _read_line(conn)
    finally:
        conn.close()
    if not line:
        raise VNCError("the VNC session closed without answering (did the VM stop?)")
    reply = json.loads(line)
    print(reply.get("out", ""), end="")
    if not reply.get("ok"):
        print(f"vnc.py: {reply.get('err') or 'failed'}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (VNCError, OSError, ValueError) as error:
        print(f"vnc.py: {error}", file=sys.stderr)
        sys.exit(1)
