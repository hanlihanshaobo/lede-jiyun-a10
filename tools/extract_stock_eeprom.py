#!/usr/bin/env python3
"""
Extract the MT7916 EEPROM (calibration) blob from the stock Jiyun A10 firmware.

There is *no* standalone MT7916_EEPROM.bin in the stock rootfs: MTK's vendor
driver compiles the EEPROM template into mt_wifi.ko as a plain array and falls
back to it (the driver looks for /lib/firmware/MT7916_EEPROM.bin first, which
does not exist on this router).

Path used here:
   stock SPI NOR backup
     -> "Kernel" partition (0x300000)          : u-boot FIT
     -> kernel image node (LZMA)               : 0x1c600, size 0x191fd7a
     -> decompressed arm64 Image               : contains the initramfs
     -> initramfs (LZMA, 0x13b6e78 in Image)   : cpio of the WayOS rootfs
     -> lib/modules/.../mt_wifi.ko             : EEPROM arrays

The EEPROM blob starts with the MT7916 chip id 0x7916 (bytes 16 79 00 00) and
is 4096 bytes long.  There are two of them in the ko:
   * one sparse template (~700 non-zero bytes)  - same as mt76's default file
   * one populated EEPROM (~3300 non-zero)      - the vendor's real one

This script prefers the populated one (more non-zero bytes).

Usage:
    extract_stock_eeprom.py <spi_nor_backup.bin> <out.bin>
    extract_stock_eeprom.py --ko <mt_wifi.ko>    <out.bin>

The --ko form only needs the 14 MiB mt_wifi.ko from the stock initramfs (the
EEPROM is an array inside it); use it when you do not have the whole SPI NOR
backup.  Note that this file is identical for every A10 - the MAC addresses
are NOT in it, those live in the WayOS config partition (Config_new).
"""

import lzma
import re
import struct
import sys

KERNEL_PART_OFF = 0x300000          # SPI NOR "Kernel" partition
FIT_KERNEL_OFF = 0x1C600            # kernel image node inside the FIT
FIT_KERNEL_SIZE = 0x191FD7A
EEPROM_SIZE = 4096
EEPROM_MAGIC = b"\x16\x79\x00\x00"  # 0x7916 = MT7916


def lzma_decompress_tolerant(blob):
    """The stock streams have no end-of-stream marker, so partial output is
    expected - return everything that could be decoded."""
    d = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
    out = b""
    for i in range(0, len(blob), 1 << 20):
        try:
            out += d.decompress(blob[i:i + (1 << 20)])
        except (lzma.LZMAError, EOFError):
            break
    return out


def find_lzma_stream(data, want_cpio=True):
    """Locate an LZMA-alone stream whose payload is a cpio archive."""
    dicts = {1 << n for n in range(12, 28)}
    for i in range(len(data) - 13):
        if data[i] != 0x5D:
            continue
        if struct.unpack_from("<I", data, i + 1)[0] not in dicts:
            continue
        size = struct.unpack_from("<Q", data, i + 5)[0]
        if size != 0xFFFFFFFFFFFFFFFF and not (1_000_000 < size < 200_000_000):
            continue
        out = lzma_decompress_tolerant(data[i:i + 120_000_000])
        if not want_cpio or out[:6] in (b"070701", b"070702"):
            return out
    return None


def cpio_find(cpio, needle):
    """Return (name, data) of the first cpio entry whose name contains needle."""
    pos = 0
    while pos + 110 <= len(cpio):
        hdr = cpio[pos:pos + 110]
        if hdr[:6] not in (b"070701", b"070702"):
            return None
        filesize = int(hdr[54:62], 16)
        namesize = int(hdr[94:102], 16)
        name = cpio[pos + 110:pos + 110 + namesize - 1].decode(errors="replace")
        dataoff = (pos + 110 + namesize + 3) & ~3
        if needle in name and filesize:
            return name, cpio[dataoff:dataoff + filesize]
        if name == "TRAILER!!!":
            return None
        pos = (dataoff + filesize + 3) & ~3
    return None


def eeprom_from_ko(ko):
    """Pick the populated 4 KiB MT7916 EEPROM array out of mt_wifi.ko."""
    best = None
    for m in re.finditer(re.escape(EEPROM_MAGIC), ko):
        blob = ko[m.start():m.start() + EEPROM_SIZE]
        if len(blob) < EEPROM_SIZE:
            continue
        nz = sum(1 for b in blob if b not in (0, 0xFF))
        print("  eeprom candidate @%#x: %d non-zero bytes" % (m.start(), nz))
        if best is None or nz > best[0]:
            best = (nz, blob)
    if not best:
        raise SystemExit("no EEPROM blob found")
    return best[1], best[0]


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--ko":
        ko = open(sys.argv[2], "rb").read()
        blob, nz = eeprom_from_ko(ko)
        open(sys.argv[3], "wb").write(blob)
        print("wrote %s (%d bytes, %d non-zero)" % (sys.argv[3], len(blob), nz))
        return

    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1:3]

    raw = open(src, "rb").read()
    kern = raw[KERNEL_PART_OFF + FIT_KERNEL_OFF:
               KERNEL_PART_OFF + FIT_KERNEL_OFF + FIT_KERNEL_SIZE]
    image = lzma_decompress_tolerant(kern)
    if len(image) < 1_000_000:
        raise SystemExit("kernel decompression failed")
    print("kernel Image: %d bytes" % len(image))

    initramfs = find_lzma_stream(image)
    if not initramfs:
        raise SystemExit("initramfs not found")
    print("initramfs: %d bytes" % len(initramfs))

    hit = cpio_find(initramfs, "mt_wifi.ko")
    if not hit:
        raise SystemExit("mt_wifi.ko not found")
    name, ko = hit
    print("module: %s (%d bytes)" % (name, len(ko)))

    best = None
    for m in re.finditer(re.escape(EEPROM_MAGIC), ko):
        blob = ko[m.start():m.start() + EEPROM_SIZE]
        if len(blob) < EEPROM_SIZE:
            continue
        nz = sum(1 for b in blob if b not in (0, 0xFF))
        print("  eeprom candidate @%#x: %d non-zero bytes" % (m.start(), nz))
        if best is None or nz > best[0]:
            best = (nz, blob)

    if not best:
        raise SystemExit("no EEPROM blob found in mt_wifi.ko")

    open(dst, "wb").write(best[1])
    print("wrote %s (%d bytes, %d non-zero)" % (dst, len(best[1]), best[0]))


if __name__ == "__main__":
    main()
