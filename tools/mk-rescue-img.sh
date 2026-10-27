#!/bin/bash
# ---------------------------------------------------------------------------
# Build a "rescue" eMMC image that fits into the 32 MiB window of the maskrom
# rockusb path.
#
# Why:
#   * the maskrom/usbplug path can only reach LBA < 65536 (32 MiB); anything
#     beyond that is silently dropped, even though "wl" reports 100 %,
#   * the full image is ~257 MiB, so it can never be written in one pass,
#   * but a rootfs without LuCI / python3 / nmap / ... fits in ~20 MiB.
#
# The stripping is done per package, using the file lists that opkg keeps in
# /usr/lib/opkg/info/*.list - that is precise, unlike guessing directory
# names.  Kernel modules, uci/ubus/netifd, dropbear and the uci-defaults
# (which set up the DSA ports and the MACs) are all kept, so the rescue
# system boots into a normal OpenWrt with an SSH shell.  From there the full
# image can be dd'ed from a running system.
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

# packages that are not needed to bring the router back; everything that is
# not listed here stays
DROP_RE='^(python3.*|python3|lua.*|luci.*|rpcd-mod-.*|rpcd-luci.*|ssr.*|nmap|3proxy|vsftpd|ddns.*|ntp.*|minidlna|transmission.*|aria2.*|opkg|ip-full|ip-tiny|iw.*|iperf.*|htop|nano|vim.*|luci-app-.*)$'

# kernel modules the rescue system needs: the DSA switch driver of the
# RTL8365MB and the MT7916 wifi - the dependency closure is resolved from
# modules.dep
KEEP_MODULES='(rtl8365mb|mt7915e|mt7916e|mt76-core|mt76-connac|dsa)'

# --- 1. split the image: MBR (1 MiB) + rootfs ------------------------------
say "split $SRC"
dd if="$SRC" of="$WORK/mbr.bin" bs=1M count=1 status=none
dd if="$SRC" of="$WORK/root-full.ext4" bs=1M skip=1 status=none

# --- 2. mount ---------------------------------------------------------------
say "mount rootfs"
sudo mkdir -p "$WORK/mnt"
sudo mount -o loop "$WORK/root-full.ext4" "$WORK/mnt"
MNT="$WORK/mnt"

echo "-- top level usage (KiB):"
sudo du -sk "$MNT"/* 2>/dev/null | sort -n | tail -10

# --- 3. strip package by package ------------------------------------------
say "strip packages matching: $DROP_RE"
sudo bash -c '
set -e
mnt="$1"
re="$2"
info="$mnt/usr/lib/opkg/info"
[ -d "$info" ] || exit 0
for list in "$info"/*.list; do
    [ -e "$list" ] || continue
    pkg=$(basename "$list" .list)
    if echo "$pkg" | grep -Eq "$re"; then
        echo "   drop $pkg"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rm -rf "$mnt/${f#/}"
        done < "$list"
        rm -f "$list"
    fi
done
# the opkg status db is not needed anymore (and it is big)
rm -f "$mnt/usr/lib/opkg/status"
' _ "$MNT" "$DROP_RE"

say "usage after stripping"
sudo du -sk "$MNT"/* 2>/dev/null | sort -n | tail -10
sudo du -sk "$MNT"/usr/* 2>/dev/null | sort -n | tail -8
echo "-- module directory:"
sudo du -sk "$MNT"/usr/lib/modules "$MNT"/lib/modules 2>/dev/null | sort -n | tail -4

# --- 3b. keep only the kernel modules we actually need ---------------------
# The kernel modules are the biggest chunk (~23 MiB).  A rescue system only
# needs the DSA switch driver (rtl8365mb) and the MT7916 wifi, plus whatever
# they depend on - the dependency closure is taken from modules.dep, so
# nothing is left dangling.
say "trim kernel modules to the closure of: $KEEP_MODULES"
sudo bash -c '
set -e
mnt="$1"
keep_re="$2"
for md in "$mnt"/usr/lib/modules/* "$mnt"/lib/modules/*; do
    [ -d "$md" ] || continue
    dep="$md/modules.dep"
    [ -f "$dep" ] || continue
    echo "   module dir: $md"
    # collect the wanted roots and their dependency closure
    awk -v re="$keep_re" "
        { split(\$0, a, \":\"); split(a[2], d, \" \");
          line=\$0; mod=a[1]
          if (mod ~ re) { print line }
        }" "$dep" > "$md/.keep"
    # expand: a kept module pulls in its dependencies
    changed=1
    while [ $changed -eq 1 ]; do
        changed=0
        while IFS= read -r line; do
            mod=${line%%:*}
            deps=${line#*:}
            for d in $deps; do
                grep -q "^$d:" "$md/.keep" || { echo "$d: " >> "$md/.keep"; changed=1; }
            done
        done < "$md/.keep"
    done
    # delete every module that is not in the closure
    find "$md" -name "*.ko" | while read -r ko; do
        rel=${ko#"$md"/}
        if ! grep -q "^$rel:" "$md/.keep"; then
            rm -f "$ko"
        fi
    done
    # rewrite modules.dep with the surviving entries
    grep -F -f <(cut -d: -f1 "$md/.keep" | sed "s/$/:/") "$dep" > "$dep.new" 2>/dev/null || true
    [ -s "$dep.new" ] && mv "$dep.new" "$dep" || rm -f "$dep.new"
    rm -f "$md/.keep"
    du -sk "$md"
done
' _ "$MNT" "$KEEP_MODULES"

say "usage after module trim"
sudo du -sk "$MNT"/* 2>/dev/null | sort -n | tail -10

# --- 4. copy the stripped tree out ----------------------------------------
say "copy the stripped tree out"
sudo mkdir -p "$WORK/tree"
sudo cp -a "$MNT/." "$WORK/tree/"
sudo umount "$MNT"

USED_KB=$(sudo du -sk "$WORK/tree" | cut -f1)
say "stripped tree: ${USED_KB} KiB"

# --- 5. pack it into a fresh ext4 -----------------------------------------
# +2 MiB for the metadata, at least 24 MiB, and never more than what the
# maskrom window can hold (minus the 1 MiB MBR).
SIZE_MB=$((USED_KB / 1024 + 2))
[ "$SIZE_MB" -lt 24 ] && SIZE_MB=24
MAX_MB=$(( (WINDOW / 1024 / 1024) - 1 ))
if [ "$SIZE_MB" -gt "$MAX_MB" ]; then
    echo "ERROR: stripped rootfs still needs ${SIZE_MB} MiB, maskrom window allows ${MAX_MB} MiB" >&2
    echo "-- biggest leftovers:" >&2
    sudo du -sk "$WORK/tree"/usr/* 2>/dev/null | sort -n | tail -12 >&2
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
