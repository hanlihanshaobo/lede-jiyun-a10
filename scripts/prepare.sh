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
# 1b. RTL8367S switch LED registers
#
# The mainline rtl8365mb DSA driver never touches the switch LED registers, so
# the RTL8367S stays at its power-on default and every port LED is permanently
# on.  The vendor driver programmed 0x1b03=0x222 (all groups Link/Act),
# 0x1b24=0x1f1f (groups 0/1 -> ports 0-4) and enabled OCP 0xa442 bit 5 on each
# PHY.  Carry the same setup as a small kernel patch.
# ---------------------------------------------------------------------------
say "install rtl8365mb LED patch"
RK_PATCH_DIR="$LEDE/target/linux/rockchip/patches-6.18"
mkdir -p "$RK_PATCH_DIR"
install -m 0644 "$ROOT/kernel/backport-6.18/910-rtl8365mb-led.patch" \
	"$RK_PATCH_DIR/910-rtl8365mb-led.patch"

# MT7916 LED mux: when mt76 is built as an external module (OpenWrt),
# CONFIG_MT76_LEDS is not set in the kernel config, so
# mt7915_init_led_mux() bails out and the LED engine output never reaches
# the module LED pins (the right-hand M.2 LED stays dark).  Drop that guard
# and add a led_active_low module parameter (the A10's panel LED is wired
# active low).
#
# NOTE: mt76 is NOT built from the kernel tree on this target: it comes
# from the `mt76` package (github.com/openwrt/mt76, pinned in
# package/kernel/mt76/Makefile) and only its own patches-6.18 directory
# is applied.  Patching the kernel tree here has no effect.
say "install mt7916 LED mux patch"
MT76_PATCH_DIR="$LEDE/package/kernel/mt76/patches-6.18"
if [ ! -d "$MT76_PATCH_DIR" ]; then
	echo "ERROR: $MT76_PATCH_DIR not found (mt76 package layout changed)" >&2
	exit 1
fi
install -m 0644 "$ROOT/kernel/backport-6.18/200-mt7916-led-mux.patch" \
	"$MT76_PATCH_DIR/200-mt7916-led-mux.patch"

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

# LED defaults: left = wlan0 traffic, middle = sys (boot heartbeat -> solid),
# right = wlan1/M.2 traffic.  Exposed in LuCI -> System -> LED Configuration.
install -m 0755 "$ROOT/files/99-jiyun-led" "$BASE/etc/uci-defaults/99-jiyun-led"

# The MT7916 panel LED is active low and its blink has to come from the LED
# core (the MT7916 hardware blink engine is irregular); both are module
# parameters added by kernel/backport-6.18/200-mt7916-led-mux.patch.
mkdir -p "$BASE/etc/modprobe.d"
install -m 0644 "$ROOT/files/etc/modprobe.d/mt7915e.conf" \
	"$BASE/etc/modprobe.d/mt7915e.conf"

# Activity LED daemon: left = wlan0+wlan1 traffic, right = M.2 slot traffic.
# The middle sys LED stays with the UCI/led-init configuration.
mkdir -p "$BASE/usr/sbin" "$BASE/etc/init.d" "$BASE/etc/rc.d"
install -m 0755 "$ROOT/files/usr/sbin/jiyun-ledd" "$BASE/usr/sbin/jiyun-ledd"
install -m 0755 "$ROOT/files/etc/init.d/jiyun-ledd" "$BASE/etc/init.d/jiyun-ledd"
ln -sf ../init.d/jiyun-ledd "$BASE/etc/rc.d/S99jiyun-ledd"

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

# ---------------------------------------------------------------------------
# 8. PassWall2 app
#
# PassWall2 itself comes from its upstream feed. Lean's packages feed already
# has xray-core / sing-box / tcping / geoview / chinadns-ng, so the full
# passwall-packages feed is NOT installed; only its v2ray-geodata source is
# pulled in §9 (PassWall2 hard-depends on v2ray-geoip/v2ray-geosite, which
# Lean does not ship).
# ---------------------------------------------------------------------------
say "add PassWall2 feed"
(
	cd "$LEDE"
	[ -f feeds.conf ] || cp feeds.conf.default feeds.conf
	if ! grep -q '^src-git passwall2 ' feeds.conf; then
		echo 'src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main' >> feeds.conf
	fi
	./scripts/feeds update passwall2
	./scripts/feeds install -a -p passwall2
)

# ---------------------------------------------------------------------------
# 9. eMMC health UI + PassWall2 geo data
#
# luci-app-emmc-health is vendored from adminchenyu/eMMC-Health v1.1.3 (the
# only eMMC life/Pre-EOL LuCI UI; upstream depends on luci-js-deps which is
# not in Lean's luci feed, so the vendored Makefile uses mmc-utils directly).
#
# PassWall2 needs v2ray-geoip/v2ray-geosite; Lean's packages feed has the
# cores but not the geodata. Install only the v2ray-geodata source from the
# passwall-packages feed so xray-core/sing-box/tcping/geoview/chinadns-ng
# keep coming from Lean and no duplicate package names are installed.
# ---------------------------------------------------------------------------
say "install luci-app-emmc-health"
rm -rf "$LEDE/package/luci-app-emmc-health"
cp -a "$ROOT/package/luci-app-emmc-health" "$LEDE/package/"

say "add PassWall2 geo-data feed"
(
	cd "$LEDE"
	[ -f feeds.conf ] || cp feeds.conf.default feeds.conf
	if ! grep -q '^src-git passwall_packages ' feeds.conf; then
		echo 'src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main' >> feeds.conf
	fi
	./scripts/feeds update passwall_packages
	./scripts/feeds install -p passwall_packages v2ray-geodata
	# Lean's net/xray-core currently pins 26.10.29, whose upstream
	# codeload tag does not exist (and whose mirror entry is missing),
	# so the build dies at the download step.  Use the passwall feed's
	# xray-core (26.10.31) instead: it is the core luci-app-passwall2 is
	# developed against and its codeload tarball/hash are valid.
	rm -rf "$LEDE/package/feeds/packages/xray-core"
	rm -rf "$LEDE/package/feeds/passwall_packages/xray-core"
	./scripts/feeds install -p passwall_packages xray-core
)

# ---------------------------------------------------------------------------
# 10. luci-app-multiwifi as a rootfs overlay
#
# make defconfig did not pick this package up reliably when it was copied
# into package/ (the CI assertion failed), so ship it the same way as the
# other board files: put the pure Lua/shell files into the global files/
# overlay. PassWall2 (the runtime dependency) is already selected above.
# The source package remains in package/luci-app-multiwifi for standalone
# builds, but the image does not depend on it being selected by Kconfig.
# ---------------------------------------------------------------------------
say "install luci-app-multiwifi overlay"
mkdir -p \
	"$LEDE/files/usr/lib/lua/luci/controller" \
	"$LEDE/files/usr/lib/lua/luci/model/cbi/multiwifi" \
	"$LEDE/files/usr/libexec" \
	"$LEDE/files/etc/config"
install -m 0644 "$ROOT/package/luci-app-multiwifi/luasrc/controller/multiwifi.lua" \
	"$LEDE/files/usr/lib/lua/luci/controller/multiwifi.lua"
install -m 0644 "$ROOT/package/luci-app-multiwifi/luasrc/model/cbi/multiwifi/main.lua" \
	"$LEDE/files/usr/lib/lua/luci/model/cbi/multiwifi/main.lua"
install -m 0755 "$ROOT/package/luci-app-multiwifi/root/usr/libexec/multiwifi-apply" \
	"$LEDE/files/usr/libexec/multiwifi-apply"
install -m 0644 "$ROOT/package/luci-app-multiwifi/root/etc/config/multiwifi" \
	"$LEDE/files/etc/config/multiwifi"

say "done"
