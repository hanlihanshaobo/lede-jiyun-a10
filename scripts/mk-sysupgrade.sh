#!/bin/sh
# Assemble the Jiyun A10 in-system upgrade package (podkop profile).
#
# The result is an uncompressed tar; CI appends fwtool metadata afterwards so
# sysupgrade's generic device check accepts it.  Keeping it uncompressed lets
# BusyBox tar stop at the tar EOF marker and ignore the metadata footer.
#
#     usage: ./scripts/mk-sysupgrade.sh <root.ext4> <kernel.fit> <out.tar>
set -eu

ROOTFS="${1:-}"
FIT="${2:-}"
OUT="${3:-}"
[ -n "$ROOTFS" ] && [ -n "$FIT" ] && [ -n "$OUT" ] || {
	sed -n '2,10p' "$0"
	exit 1
}

for f in "$ROOTFS" "$FIT"; do
	[ -f "$f" ] || { echo "not a file: $f" >&2; exit 1; }
done

BOARD="jiyun_a10"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DIR="$TMP/sysupgrade-$BOARD"
mkdir -p "$DIR"

{
	echo "BOARD=$BOARD"
	echo "ROOTFS_SIZE=$(wc -c < "$ROOTFS" | tr -d ' ')"
	echo "FIT_SIZE=$(wc -c < "$FIT" | tr -d ' ')"
} > "$DIR/CONTROL"

cp "$FIT" "$DIR/kernel"
cp "$ROOTFS" "$DIR/root"

rm -f "$OUT"
tar -C "$TMP" -cf "$OUT" "sysupgrade-$BOARD"
ls -lh "$OUT"
