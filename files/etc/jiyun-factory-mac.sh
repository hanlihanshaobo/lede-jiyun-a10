#!/bin/sh
# ---------------------------------------------------------------------------
# Per-unit factory MACs from the stock WayOS configuration.
#
# The board has no MAC EEPROM and no programmed eFuse/OTP; the only per-unit
# MACs live in the SPI NOR "Config_new" partition (mtd5), written by the
# vendor firmware:
#
#     "wayos.pa3" + 3 bytes + gzip stream  ->  14035 key=value pairs
#     mac_deflan / mac_defwan / mac_defwl / mac_defwl_5g
#
# Reading it needs the SFC/mtd support that landed with the 2026-10-29 DTS
# change; before that the MACs had to be derived from the eMMC CID.
#
# Both callers fall back to the CID scheme when the partition is missing,
# erased or does not contain the keys, so a full-chip erase still boots with
# unique (but locally administered) MACs.
# ---------------------------------------------------------------------------

JIYUN_WAYOS_CFG=/tmp/.jiyun-wayos-cfg

# Decompress the vendor config once per boot (384 KiB partition, ~240 KiB of
# text; the gzip stream is followed by padding, so ignore gzip's exit status).
jiyun_wayos_cfg() {
	[ -c /dev/mtd5 ] || return 1
	if [ ! -s "$JIYUN_WAYOS_CFG" ]; then
		dd if=/dev/mtd5 bs=4096 2>/dev/null | tail -c +13 | \
			gzip -dc 2>/dev/null > "$JIYUN_WAYOS_CFG"
	fi
	[ -s "$JIYUN_WAYOS_CFG" ]
}

# jiyun_wayos_get <key> -> value (empty when unavailable)
jiyun_wayos_get() {
	jiyun_wayos_cfg || return 1
	sed -n "s/^$1=//p" "$JIYUN_WAYOS_CFG" | head -1
}
