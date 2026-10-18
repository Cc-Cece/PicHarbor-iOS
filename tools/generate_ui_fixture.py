"""Deterministic synthetic PNG for simulator PhotoKit UI checks; no private media."""
from pathlib import Path
import struct
import sys
import zlib


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)


def main(path):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    size = 64
    pixels = b"".join(b"\0" + b"".join(bytes((30 + x * 3, 80 + y * 2, 200)) for x in range(size)) for y in range(size))
    target.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    main(sys.argv[1])
