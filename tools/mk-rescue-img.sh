#!/bin/bash
# ---------------------------------------------------------------------------
# Build a "rescue" eMMC image that fits into the 32 MiB window of the maskrom
# rockusb path.
#
# Why:
#   * the maskrom/usbplug path can only reach LBA < 65536 (32 MiB); anything
#     beyond that is silently dropped, even though "wl" reports 100 %,
#   * the full image is ~257 MiB, so it can never be written in one go,
#   * but a *stripped* rootfs (no LuCI, no python3, no nmap/3proxy/vsftpd,
#     no docs) fits in ~20 MiB.
#
# The rescue image boots exactly like the full one (same kernel from the SPI
# NOR FIT, same uci-defaults, same wifi calibration) and gives us an SSH
# shell - which is all we need to dd the full image from a running system.
#
#   usage: mk-rescue-img.sh <emmc.img> <out-rescue.img>
#
# Layout of the result: same as the normal image - 512 byte MBR (p1 @ LBA
# 2048) + ext4 rootfs - but the whole file must stay below 32 MiB so that
# maskrom can write it in one pass.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SRC="${1:?usage: $0 <emmc.img> <out-rescue.img>}"
OUT="${2:?usage: $0 <emmc.img> <out-rescue.img>}"

WINDOW=$((32 * 1024 * 1024))          # maskrom can only reach the first 32 MiB
WORK="$(mktemp -d /tmp/rescue.XXXXXX)"
trap 'sudo umount "$WORK/mnt" 2>/dev/null || true; sudo rm -rf "$WORK"' EXIT

say() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

# --- 1. split the image: MBR (1 MiB) + rootfs ------------------------------
say "split $SRC"
dd if="$SRC" of="$WORK/mbr.bin" bs=1M count=1 status=none
dd if="$SRC" of="$WORK/root-full.ext4" bs=1M skip=1 status=none
ls -l "$WORK/mbr.bin" "$WORK/root-full.ext4"

# --- 2. mount and strip -----------------------------------------------------
say "mount rootfs and drop the fat"
sudo mkdir -p "$WORK/mnt"
sudo mount -o loop "$WORK/root-full.ext4" "$WORK/mnt"

echo "-- top level usage (KiB):"
sudo du -sk "$WORK/mnt"/* 2>/dev/null | sort -n | tail -12

# the globs have to be expanded by the privileged shell, they live inside
# the mounted tree
sudo bash -c '
set -e
mnt="$1"
for p in \
    www \
    usr/lib/lua usr/share/lua \
    usr/lib/python3 usr/lib/python3.* usr/libexec/python3 \
    usr/bin/python3 usr/bin/python3.* \
    usr/share/man usr/share/doc usr/share/nmap \
    usr/bin/nmap usr/bin/3proxy usr/sbin/nmap usr/sbin/3proxy \
    usr/share/vsftpd usr/share/ddns-scripts \
    usr/lib/opkg
do
    [ -e "$mnt/$p" ] || continue
    echo "   drop $p"
    rm -rf "$mnt/$p"
done
' _ "$WORK/mnt"

say "copy the stripped tree out"
sudo mkdir -p "$WORK/tree"
sudo cp -a "$WORK/mnt/." "$WORK/tree/"
sudo umount "$WORK/mnt"

USED_KB=$(sudo du -sk "$WORK/tree" | cut -f1)
say "stripped tree: ${USED_KB} KiB"

# --- 3. pack it into a fresh ext4 -----------------------------------------
# +2 MiB for the metadata, at least 24 MiB, and never more than what the
# maskrom window can hold (minus the 1 MiB MBR).
SIZE_MB=$((USED_KB / 1024 + 2))
[ "$SIZE_MB" -lt 24 ] && SIZE_MB=24
MAX_MB=$(( (WINDOW / 1024 / 1024) - 1 ))
if [ "$SIZE_MB" -gt "$MAX_MB" ]; then
    echo "ERROR: stripped rootfs still needs ${SIZE_MB} MiB, maskrom window allows ${MAX_MB} MiB" >&2
    exit 1
fi

say "create ext4 (${SIZE_MB} MiB) and wrap it into an MBR image"
sudo mke2fs -q -t ext4 -b 4096 -L rootfs -d "$WORK/tree" "$WORK/root-small.ext4" "${SIZE_MB}M"
python3 "$ROOT/files/mk-emmc-img.py" "$WORK/root-small.ext4" "$OUT"

SIZE=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")
say "rescue image: $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$WINDOW" ]; then
    echo "ERROR: $SIZE bytes does not fit into the maskrom window ($WINDOW bytes)" >&2
    exit 1
fi
echo "OK: fits into the 32 MiB maskrom window, it can be written in one pass"
