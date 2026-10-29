#!/bin/bash
# ---------------------------------------------------------------------------
# Layer the Jiyun A10 support on top of a freshly cloned LEDE tree.
#
# CI calls this after `git clone`, and a local developer calls the same script
# so both produce an identical tree:
#
#     git clone --depth 1 --branch master https://github.com/coolsnowwolf/lede lede
#     ./scripts/prepare.sh lede
#     cp configs/config.seed lede/.config && (cd lede && make defconfig && make -j$(nproc))
#
# Everything injected here is a file from this repository; nothing is patched
# in place except the generic kernel config fragment (see below).
#
#     usage: ./scripts/prepare.sh <lede-dir>
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LEDE="${1:-}"

[ -n "$LEDE" ] || { sed -n '2,17p' "$0"; exit 1; }
LEDE="$(cd "$LEDE" 2>/dev/null && pwd)" || { echo "no such directory: $1" >&2; exit 1; }
[ -f "$LEDE/rules.mk" ] || { echo "$LEDE is not a LEDE/OpenWrt tree" >&2; exit 1; }

say() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. device tree
# ---------------------------------------------------------------------------
say "install device tree"
DTS_DIR="$LEDE/target/linux/rockchip/files/arch/arm64/boot/dts/rockchip"
mkdir -p "$DTS_DIR"
install -m 0644 "$ROOT/files/rk3568-jiyun-a10.dts" "$DTS_DIR/rk3568-jiyun-a10.dts"

# ---------------------------------------------------------------------------
# 2. device recipe (appended to armv8.mk, idempotent)
# ---------------------------------------------------------------------------
say "append device recipe to armv8.mk"
ARMV8_MK="$LEDE/target/linux/rockchip/image/armv8.mk"
if grep -q "Device/jiyun_a10" "$ARMV8_MK"; then
	echo "already present, skipping"
else
	cat "$ROOT/files/armv8-jiyun-a10.mk" >> "$ARMV8_MK"
fi

# ---------------------------------------------------------------------------
# 3. image helper used by Build/jiyun-a10-emmc-img
# ---------------------------------------------------------------------------
say "install image helper"
install -m 0755 "$ROOT/files/mk-emmc-img.py" "$LEDE/scripts/mk-emmc-img.py"

# ---------------------------------------------------------------------------
# 4. kernel config fragment
#
# target/linux/generic/config-6.x sets the DSA core to "not set", which
# overrides .config and leaves every switch port dead. Flip exactly the four
# DSA symbols.
#
# The swconfig trio (SWCONFIG / RTL8366_SMI / RTL8367B_PHY) is deliberately not
# touched: the board runs the mainline DSA driver (kmod-dsa-rtl8365mb, see the
# DTS), so the out-of-tree rtl8367b swconfig driver is not needed and is left
# off. Nothing is injected into target/linux/generic/files either - the only
# generic patch that used to carry this board was the RTL8367S backport
# (900-net-phy-add-rtl8367s.patch), which had to be re-checked on every kernel
# bump and was a standing "does not apply" risk.
# ---------------------------------------------------------------------------
say "enable DSA in the generic kernel config"
KCFG="$LEDE/target/linux/generic/config-6.18"
if [ ! -f "$KCFG" ]; then
	KCFG=$(ls "$LEDE"/target/linux/generic/config-6.* 2>/dev/null | head -1)
fi
[ -f "$KCFG" ] || { echo "no target/linux/generic/config-6.* in $LEDE" >&2; exit 1; }

sed \
	-e 's/^# CONFIG_NET_SWITCHDEV is not set/CONFIG_NET_SWITCHDEV=y/' \
	-e 's/^# CONFIG_NET_DSA is not set/CONFIG_NET_DSA=y/' \
	-e 's/^# CONFIG_NET_DSA_REALTEK is not set/CONFIG_NET_DSA_REALTEK=m/' \
	-e 's/^# CONFIG_NET_DSA_TAG_RTL8_4 is not set/CONFIG_NET_DSA_TAG_RTL8_4=m/' \
	"$KCFG" > "$KCFG.tmp" && mv "$KCFG.tmp" "$KCFG"
grep -E '^CONFIG_(NET_DSA|NET_SWITCHDEV|NET_DSA_REALTEK|NET_DSA_TAG_RTL8_4)=' "$KCFG" || {
	echo "ERROR: could not enable DSA in $KCFG" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# 5. drop generic patches that cannot apply here
#
# A generic patch that stops applying takes the whole build down inside
# toolchain/kernel-headers, ~30 minutes in, before anything board specific is
# compiled (#47-#51). LEDE master moves daily, so build.yml pins the tree; this
# is the list of series that still has to go because the hardware is not on
# this board.
#
# The MxL862xx switch spans BOTH generic series: backport-6.18 carries the
# driver (762/764-780) and pending-6.18 the follow-ups (760-0x) that patch the
# files the backport creates. Dropping one half only moves the error one patch
# down the list (#49 -> #50 -> #51), so both halves go, matched by name and
# then by the directory they touch.
#
# The series is also load bearing for other patches: target/linux/rockchip/
# patches-6.18/0130 (Motorcomm YT921x) inserts its DSA tag numbers *after* the
# MXL862 defines, so it cannot apply once the series is gone (#52). That driver
# is not on this board either, so anything still referring to it goes too.
# ---------------------------------------------------------------------------
say "drop patches for hardware this board does not have"
shopt -s nullglob

KVER="${KCFG##*config-}"
BP_DIR="$LEDE/target/linux/generic/backport-$KVER"
[ -d "$BP_DIR" ] || BP_DIR=$(ls -d "$LEDE"/target/linux/generic/backport-6.* | tail -1)
# derived from BP_DIR, not KVER, so the pair stays in step when the fallback
# above picks a different series
PEND_DIR="${BP_DIR%backport-*}pending-${BP_DIR##*backport-}"
echo "generic patch dirs: $BP_DIR $PEND_DIR"

for d in "$BP_DIR" "$PEND_DIR"; do
	for f in "$d"/*[mM]x[lL]862xx*.patch; do
		echo "removing $(basename "$d")/$(basename "$f") (MxL862xx DSA series; not on this board)"
		rm -f "$f"
	done
	# a follow-up patch may not carry "mxl" in its file name but still edits
	# drivers/net/dsa/mxl862xx/ -> "No file to patch" once the driver is gone
	for f in "$d"/*.patch; do
		if grep -qE '^(\+\+\+|---) [ab]/drivers/net/dsa/mxl862xx/' "$f"; then
			echo "removing $(basename "$d")/$(basename "$f") (touches the mxl862xx driver)"
			rm -f "$f"
		fi
	done
done

# target patches that only made sense on top of the removed series: 0130
# (Motorcomm YT921x) adds DSA_TAG_PROTO_YT921X right after the MXL862 tag
# values, so both of its include/net/dsa.h hunks are rejected once they are
# gone. Match on the dependency, not on the file name, so a rebased/renamed
# patch is caught as well.
RK_PDIR="$LEDE/target/linux/rockchip/patches-$KVER"
[ -d "$RK_PDIR" ] || RK_PDIR=$(ls -d "$LEDE"/target/linux/rockchip/patches-6.* 2>/dev/null | tail -1)
if [ -n "${RK_PDIR:-}" ] && [ -d "$RK_PDIR" ]; then
	for f in "$RK_PDIR"/*.patch; do
		if grep -q 'MXL862' "$f"; then
			echo "removing $(basename "$RK_PDIR")/$(basename "$f") (context depends on the MxL862xx tag ids)"
			rm -f "$f"
		fi
	done
fi

# ---------------------------------------------------------------------------
# 6. rootfs overlay (target base-files)
# ---------------------------------------------------------------------------
say "install rootfs overlay"
BASE="$LEDE/target/linux/rockchip/base-files"

# network defaults: br-lan over the DSA ports lan1/2/3, wan, CID-derived MACs
mkdir -p "$BASE/etc/uci-defaults"
install -m 0755 "$ROOT/files/99-jiyun-net" "$BASE/etc/uci-defaults/99-jiyun-net"

# branding defaults: hostname + default LuCI theme (first boot only)
install -m 0755 "$ROOT/files/99-jiyun-branding" "$BASE/etc/uci-defaults/99-jiyun-branding"

# one-time first-boot rootfs resize to fill the eMMC partition
install -m 0755 "$ROOT/files/99-jiyun-resize" "$BASE/etc/uci-defaults/99-jiyun-resize"

# LuCI overview: hide the DSA CPU/conduit port (eth0), show lan1-3/wan only.
# This must go into the global files/ overlay (applied after all packages),
# not target base-files: luci-mod-status is installed later and would win.
mkdir -p "$LEDE/files/www/luci-static/resources/view/status/include"
install -m 0644 "$ROOT/files/www/luci-static/resources/view/status/include/15_ports.js" \
	"$LEDE/files/www/luci-static/resources/view/status/include/15_ports.js"

# Per-unit WLAN MACs: the first-boot "wifi config" (S18fanctrl) rewrites
# /etc/config/wireless, so uci-defaults is too early - rc.local runs at the
# very end of boot and applies them.
install -m 0755 "$ROOT/files/etc/jiyun-mac.sh" "$BASE/etc/jiyun-mac.sh"
install -m 0644 "$ROOT/files/etc/jiyun-factory-mac.sh" "$BASE/etc/jiyun-factory-mac.sh"
install -m 0755 "$ROOT/files/etc/rc.local" "$BASE/etc/rc.local"

# MT7916 needs an EEPROM blob; without it mt7915 probe fails and no wlan phy
# is registered. This is the ART/Factory copy - the only variant that declares
# 2.4G+5G (see the porting notes).
mkdir -p "$BASE/lib/firmware/mediatek"
install -m 0644 "$ROOT/files/mt7916_eeprom.bin" \
	"$BASE/lib/firmware/mediatek/mt7916_eeprom.bin"

# ---------------------------------------------------------------------------
# 7. extra feed: QModem (the app users still call "luci-app-modem")
#
# FUjr/modem_feeds was renamed to FUjr/QModem; the current LuCI package is
# luci-app-qmodem-next. Upstream ships the feed commented out in
# feeds.conf.default, and the CI runs "feeds update -a"/"feeds install -a"
# before this script, so add + install the feed here. make defconfig runs
# afterwards and will see the packages.
# ---------------------------------------------------------------------------
say "add QModem feed"
(
	cd "$LEDE"
	[ -f feeds.conf ] || cp feeds.conf.default feeds.conf
	if ! grep -q '^src-git qmodem ' feeds.conf; then
		echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf
	fi
	./scripts/feeds update qmodem
	./scripts/feeds install -a -p qmodem
)

say "done"
