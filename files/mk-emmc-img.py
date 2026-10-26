#!/usr/bin/env python3
"""Build the eMMC flashing image: MBR partition table + root.ext4.

Layout (identical to the stock unit, so `root=/dev/mmcblk0p1` keeps working):

    LBA 0        MBR, one primary partition, type 0x83
    LBA 2048     p1 = rootfs (ext4), 14596096 sectors / ~7 GB
    ...          rest of the partition left untouched

Only the first 256 MB of p1 are written, which is all the rootfs occupies.

    usage: mk-emmc-img.py <root.ext4> <out.img>
"""

import os
import struct
import sys

DISK_ID = 0x3F2C7DCE          # stock disk signature, kept for identification
P1_START = 2048               # 1 MiB
P1_SECTORS = 14596096         # 7 GiB, same as the stock MBR
CHUNK = 1 << 20


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)

    rootfs, out = sys.argv[1], sys.argv[2]
    size = os.path.getsize(rootfs)
    if size > P1_SECTORS * 512:
        sys.exit("rootfs is %d bytes, larger than the %d byte partition"
                 % (size, P1_SECTORS * 512))

    mbr = bytearray(512)
    mbr[440:444] = struct.pack('<I', DISK_ID)
    mbr[446:462] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0x83,
                               b'\xfe\xff\xff', P1_START, P1_SECTORS)
    mbr[510:512] = b'\x55\xaa'

    with open(out, 'wb') as f:
        f.write(mbr)
        f.write(b'\0' * (P1_START * 512 - 512))
        with open(rootfs, 'rb') as src:
            while True:
                buf = src.read(CHUNK)
                if not buf:
                    break
                f.write(buf)

    print('%s: MBR + root.ext4 @ LBA %d -> %d bytes'
          % (out, P1_START, os.path.getsize(out)))


if __name__ == '__main__':
    main()
