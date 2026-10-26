#!/usr/bin/env python3
"""Build the SPI NOR flashing image: boot chain + kernel FIT in one file.

Layout (the stock SPI NOR partition map, so the stock boot flow is untouched):

    0x000000  loader  1 MiB   stock loader partition (GPT header + idbloader)
    0x100000  uboot   2 MiB   stock u-boot FIT (U-Boot + ATF + OP-TEE + MCU)
    0x300000  FIT     5.8MB   OpenWrt kernel + DTB, see tools/mkfit.py

Everything before 0x300000 is the untouched stock bootloader; only the
"Kernel" partition is replaced. 8.6 MiB total, which fits the 32 MiB maskrom
write window, so a completely blank device can be flashed in one go.

    usage: mk-spi-img.py <loader> <uboot> <fit> <out.img>
"""

import os
import sys

LOADER_OFF = 0x000000
UBOOT_OFF = 0x100000
FIT_OFF = 0x300000
SPI_SIZE = 32 << 20


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)

    loader, uboot, fit, out = sys.argv[1:5]

    for path, off in ((loader, LOADER_OFF), (uboot, UBOOT_OFF), (fit, FIT_OFF)):
        size = os.path.getsize(path)
        if off + size > SPI_SIZE:
            sys.exit("%s does not fit at 0x%06x" % (path, off))

    total = FIT_OFF + os.path.getsize(fit)
    img = bytearray(b'\xff' * total)          # NOR erase state
    for path, off in ((loader, LOADER_OFF), (uboot, UBOOT_OFF), (fit, FIT_OFF)):
        with open(path, 'rb') as f:
            img[off:off + os.path.getsize(path)] = f.read()

    with open(out, 'wb') as f:
        f.write(img)

    print('%s: loader@0x0 + uboot@0x100000 + fit@0x300000 -> %d bytes (%.1f MiB)'
          % (out, total, total / 1048576.0))


if __name__ == '__main__':
    main()
