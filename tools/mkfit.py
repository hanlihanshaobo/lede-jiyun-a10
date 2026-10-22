#!/usr/bin/env python3
"""
Build the SPI NOR bootstrap FIT for the Jiyun A10 (Rockchip RK3568).

Why not just use "mkimage -f x.its out.fit"?
    The stock u-boot of this router (2017.09-dirty Rockchip SDK) only
    understands the *old* external-data FIT format, i.e. the image nodes
    carry a "data-position" property.  A current mkimage with "-E" emits
    "data-offset" instead, and the SDK u-boot would then fail with
    "Could not find kernel subimage data!".

    So we take the *stock* FIT header as a template (identical property
    layout, only the sizes/hashes/positions differ) and patch it in place.
    The result is byte-for-byte the same kind of FIT the stock firmware
    uses, just with our kernel and our mainline device tree.

FIT layout (identical to the stock one):
    0x0000  FIT header (1536 bytes, DTB)
    0x0800  device tree blob
    0x1c600 (or right after the dtb)  LZMA compressed kernel

Usage:
    mkfit.py <template-header.bin> <Image> <dtb> <out.fit>
"""

import hashlib
import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9

FDT_DATA_POS = 0x800          # where the device tree blob is placed
DATA_ALIGN = 0x200            # Rockchip aligns the data to 512 bytes


class Fdt:
    """Minimal flattened device tree parser/patcher (big endian, like dtc)."""

    def __init__(self, blob):
        self.blob = bytearray(blob)
        (magic, self.totalsize, self.off_struct, self.off_strings,
         self.off_rsvmap, self.version, self.last_comp, self.boot_cpuid,
         self.size_strings, self.size_struct) = struct.unpack_from(">10I", self.blob, 0)
        if magic != FDT_MAGIC:
            raise ValueError("not a DTB (magic %#x)" % magic)
        self.props = {}   # "/images/kernel/data-size" -> (abs_offset, length)

    def _strings(self, off):
        end = self.blob.index(b"\0", self.off_strings + off)
        return self.blob[self.off_strings + off:end].decode()

    def parse(self):
        pos = self.off_struct
        path = []
        end = self.off_struct + self.size_struct
        while pos < end:
            (token,) = struct.unpack_from(">I", self.blob, pos)
            pos += 4
            if token == FDT_BEGIN_NODE:
                z = self.blob.index(b"\0", pos)
                name = self.blob[pos:z].decode()
                pos = (z + 4) & ~3
                if name:
                    path.append(name)
                else:
                    path.append("")
            elif token == FDT_END_NODE:
                if path:
                    path.pop()
            elif token == FDT_PROP:
                length, nameoff = struct.unpack_from(">II", self.blob, pos)
                pos += 8
                name = self._strings(nameoff)
                value_off = pos
                p = "/" + "/".join(p for p in path if p)
                self.props["%s/%s" % (p, name)] = (value_off, length)
                pos = (pos + length + 3) & ~3
            elif token == FDT_NOP:
                pass
            elif token == FDT_END:
                break
            else:
                raise ValueError("bad FDT token %d at %d" % (token, pos))

    def get_u32(self, path):
        off, length = self.props[path]
        if length != 4:
            raise ValueError("%s is not a u32" % path)
        return struct.unpack_from(">I", self.blob, off)[0]

    def set_u32(self, path, value):
        off, length = self.props[path]
        if length != 4:
            raise ValueError("%s is not a u32" % path)
        struct.pack_into(">I", self.blob, off, value)

    def get_bytes(self, path):
        off, length = self.props[path]
        return bytes(self.blob[off:off + length])

    def set_bytes(self, path, value):
        off, length = self.props[path]
        if len(value) != length:
            raise ValueError("%s: expected %d bytes, got %d" % (path, length, len(value)))
        self.blob[off:off + length] = value

    def set_totalsize(self, value):
        struct.pack_into(">I", self.blob, 4, value)


def lzma_alone(data):
    """Compress like the Rockchip SDK does: raw .lzma (alone) stream."""
    import lzma
    filt = [{"id": lzma.FILTER_LZMA1, "preset": 9 | lzma.PRESET_EXTREME}]
    raw = lzma.compress(data, format=lzma.FORMAT_ALONE,
                        filters=filt)
    # FORMAT_ALONE already writes the 13 byte header with an unknown size
    return raw


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    tmpl, kern_img, dtb_file, out = sys.argv[1:5]

    with open(tmpl, "rb") as f:
        header = f.read()
    with open(kern_img, "rb") as f:
        kernel = f.read()
    with open(dtb_file, "rb") as f:
        dtb = f.read()

    kern_lzma = lzma_alone(kernel)

    fdt = Fdt(header)
    fdt.parse()

    dtb_pos = FDT_DATA_POS
    kern_pos = (dtb_pos + len(dtb) + DATA_ALIGN - 1) & ~(DATA_ALIGN - 1)

    fdt.set_u32("/images/fdt/data-size", len(dtb))
    fdt.set_u32("/images/fdt/data-position", dtb_pos)
    fdt.set_bytes("/images/fdt/hash/value", hashlib.sha256(dtb).digest())

    fdt.set_u32("/images/kernel/data-size", len(kern_lzma))
    fdt.set_u32("/images/kernel/data-position", kern_pos)
    fdt.set_bytes("/images/kernel/hash/value", hashlib.sha256(kern_lzma).digest())

    total = kern_pos + len(kern_lzma)
    fdt.set_totalsize(len(fdt.blob))       # the header itself (1536)

    out_blob = bytearray(fdt.blob)
    out_blob += b"\0" * (dtb_pos - len(out_blob))
    out_blob += dtb
    out_blob += b"\0" * (kern_pos - len(out_blob))
    out_blob += kern_lzma

    with open(out, "wb") as f:
        f.write(out_blob)

    print("FIT written: %s (%d bytes)" % (out, len(out_blob)))
    print("  header      : %d bytes" % len(fdt.blob))
    print("  dtb         : offset %#x  %d bytes" % (dtb_pos, len(dtb)))
    print("  kernel(lzma): offset %#x  %d bytes (uncompressed %d)" %
          (kern_pos, len(kern_lzma), len(kernel)))
    print("  total       : %d bytes" % total)


if __name__ == "__main__":
    main()
