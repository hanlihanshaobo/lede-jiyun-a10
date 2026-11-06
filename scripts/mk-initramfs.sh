#!/bin/sh
# Build the minimal first-boot initramfs from the target rootfs staging dir.
#
# Usage: mk-initramfs.sh <target-rootfs-dir> <out.cpio.gz>
#
# The initramfs only needs busybox + e2fsprogs (resize2fs/e2fsck) and their
# musl libraries: it runs before the eMMC rootfs is mounted and resizes p1
# offline, then switch_root()s into the real system.
set -eu

TARGET="${1:?usage: $0 <target-rootfs-dir> <out.cpio.gz>}"
OUT="${2:?usage: $0 <target-rootfs-dir> <out.cpio.gz>}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ -d "$TARGET" ] || { echo "target rootfs not found: $TARGET" >&2; exit 1; }
[ -f "$TARGET/bin/busybox" ] || { echo "busybox not found in $TARGET" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/sbin" "$TMP/lib" "$TMP/usr/lib" \
	"$TMP/proc" "$TMP/sys" "$TMP/dev" "$TMP/mnt" "$TMP/tmp"

cp -L "$TARGET/bin/busybox" "$TMP/bin/busybox"
chmod 0755 "$TMP/bin/busybox"

for f in sbin/resize2fs sbin/e2fsck usr/sbin/resize2fs usr/sbin/e2fsck; do
	if [ -f "$TARGET/$f" ]; then
		cp -L "$TARGET/$f" "$TMP/sbin/$(basename "$f")"
	fi
done
[ -x "$TMP/sbin/resize2fs" ] || {
	echo "resize2fs not found in $TARGET (add the resize2fs package)" >&2
	exit 1
}

# Copy the libraries the binaries actually need.
for b in "$TMP/bin/busybox" "$TMP/sbin/resize2fs" "$TMP/sbin/e2fsck"; do
	[ -f "$b" ] || continue
	readelf -d "$b" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
done | sort -u | while read -r lib; do
	for d in lib usr/lib; do
		if [ -f "$TARGET/$d/$lib" ]; then
			cp -L "$TARGET/$d/$lib" "$TMP/lib/"
			break
		fi
	done
done

# musl dynamic loader (also covers libc.so when it is a symlink).
for f in "$TARGET"/lib/ld-musl-*.so.1; do
	[ -f "$f" ] && cp -L "$f" "$TMP/lib/"
done

cp "$HERE/initramfs-init" "$TMP/init"
chmod 0755 "$TMP/init"

# The kernel opens /dev/console before /init runs; devtmpfs is mounted later.
sudo mknod "$TMP/dev/console" c 5 1
sudo mknod "$TMP/dev/null" c 1 3
sudo chmod 600 "$TMP/dev/console"
sudo chmod 666 "$TMP/dev/null"

( cd "$TMP" && find . -print0 | cpio --null -o -H newc --owner root:root 2>/dev/null | gzip -9 ) > "$OUT"
ls -lh "$OUT"
