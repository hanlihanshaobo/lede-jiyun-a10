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
# 0. kernel series
#
# Upstream ships 7.3 as the *testing* series and still keeps rockchip on 6.18
# (KERNEL_PATCHVER in target/linux/rockchip/Makefile).  This board is built on
# 7.3, so bump the target here; every path below derives from $KVER instead of
# hardcoding a series, so the next bump is this one variable.
#
# Override with JIYUN_KVER=6.18 to build the old series again (the 6.18 tree
# then needs the MxL862xx patch-series workaround that used to live in this
# script - see the git history for "drop patches for hardware this board does
# not have").
# ---------------------------------------------------------------------------
KVER="${JIYUN_KVER:-7.3}"
say "target kernel series: $KVER"

if [ ! -f "$LEDE/include/kernel-$KVER" ]; then
	echo "ERROR: upstream tree has no include/kernel-$KVER - pin a newer LEDE_REF" >&2
	exit 1
fi

RK_MK="$LEDE/target/linux/rockchip/Makefile"
if ! grep -q "^KERNEL_PATCHVER:=$KVER\$" "$RK_MK"; then
	sed "s/^KERNEL_PATCHVER:=.*/KERNEL_PATCHVER:=$KVER/" "$RK_MK" > "$RK_MK.tmp" &&
		mv "$RK_MK.tmp" "$RK_MK"
fi
grep -q "^KERNEL_PATCHVER:=$KVER\$" "$RK_MK" || {
	echo "ERROR: could not set KERNEL_PATCHVER:=$KVER in $RK_MK" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# 0b. arm64 UAPI fix for 7.3
#
# 7.3 changed the 128-bit members of the arm64 UAPI to the __u128 typedef from
# <linux/types.h>.  User space that reaches <asm/ptrace.h> through
# <asm/bpf_perf_event.h> (libbpf does) then fails to build with
#
#   asm/ptrace.h:96:9: error: unknown type name '__u128'
#
# (the same change broke iptables/ebtables on 7.3, which bundle an old
# linux/types.h).  This has to be a *generic* patch, not a target patch: the
# toolchain kernel headers - the ones libbpf compiles against - are built with
# the generic series only, before any target patch exists.
# ---------------------------------------------------------------------------
if [ "${KVER%%.*}" -ge 7 ] && [ -d "$LEDE/target/linux/generic/hack-$KVER" ]; then
	say "install arm64 UAPI __u128 workaround"
	install -m 0644 "$ROOT/kernel/patches/0001-arm64-uapi-uint128.patch" \
		"$LEDE/target/linux/generic/hack-$KVER/0001-arm64-uapi-uint128.patch"
else
	say "no generic/hack-$KVER, skipping the arm64 UAPI workaround"
fi

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
# Upstream still only ships target/linux/rockchip/patches-6.18. When the
# directory for the kernel being built does not exist yet, seed it from that
# series minus the patches that do not apply to the newer kernel. Verified with
# `patch -p1 --dry-run` against linux-7.3.1:
#
#   0130-net-dsa-add-motorcomm-yt921x   DSA tag ids sit next to the MxL862
#                                      ones; that switch is not on this board
#   039-*  inno-usb2 clkout/RK3528      RK3528-only, and the 7.3 phy file
#                                      already carries the usbgrf rework
#   106-nanopi-r4s-sd-power-cycle       R4S DTS changed upstream
#   113-...stmmac-SGMII-QSGMII          6/14 hunks, not this board
#   700-...stmmac-disable-VLAN-hw-filter include/linux/stmmac.h moved
#
# Once upstream adds patches-$KVER the copy is skipped and only the patches
# installed below are added on top.
RK_PATCH_DIR="$LEDE/target/linux/rockchip/patches-$KVER"
if [ -d "$RK_PATCH_DIR" ]; then
	say "target patch dir $RK_PATCH_DIR (upstream)"
else
	say "seed $RK_PATCH_DIR from patches-6.18"
	SRC_PATCH_DIR="$LEDE/target/linux/rockchip/patches-6.18"
	[ -d "$SRC_PATCH_DIR" ] || {
		echo "ERROR: neither patches-$KVER nor patches-6.18 in $LEDE/target/linux/rockchip" >&2
		exit 1
	}
	mkdir -p "$RK_PATCH_DIR"
	shopt -s nullglob
	for f in "$SRC_PATCH_DIR"/*.patch; do
		case "$(basename "$f")" in
		0130-*|039-*|106-nanopi-r4s-sd-power-cycle*|113-*|700-*)
			echo "skipping $(basename "$f") (does not apply to $KVER)"
			;;
		*)
			cp "$f" "$RK_PATCH_DIR/"
			;;
		esac
	done
	shopt -u nullglob
fi

say "install rtl8365mb LED patch"
install -m 0644 "$ROOT/kernel/patches/910-rtl8365mb-led.patch" \
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
# package/kernel/mt76/Makefile) and only its own patch directory is applied.
# Patching the kernel tree here has no effect.
#
# The package picks that directory from the kernel config: 6.12 and newer
# (including 7.3) use the "else" branch, which is patches-6.18 today.  Look
# for a series matching the kernel first so a future package bump that adds
# patches-$KVER is picked up automatically.
say "install mt7916 LED mux patch"
MT76_PATCH_DIR=
for cand in "patches-$KVER" patches-6.18 patches-6.x; do
	if [ -d "$LEDE/package/kernel/mt76/$cand" ]; then
		MT76_PATCH_DIR="$LEDE/package/kernel/mt76/$cand"
		break
	fi
done
if [ -z "$MT76_PATCH_DIR" ]; then
	echo "ERROR: no usable patch dir in $LEDE/package/kernel/mt76 (layout changed)" >&2
	exit 1
fi
echo "mt76 patch dir: ${MT76_PATCH_DIR#$LEDE/}"
install -m 0644 "$ROOT/kernel/patches/200-mt7916-led-mux.patch" \
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
# target/linux/generic/config-<ver> sets the DSA core to "not set", which
# overrides .config and leaves every switch port dead. Flip exactly the DSA
# symbols.
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
KCFG="$LEDE/target/linux/generic/config-$KVER"
if [ ! -f "$KCFG" ]; then
	KCFG=$(ls "$LEDE"/target/linux/generic/config-[0-9]* 2>/dev/null | head -1)
fi
[ -f "$KCFG" ] || { echo "no target/linux/generic/config-* in $LEDE" >&2; exit 1; }

# Set a symbol whether the fragment currently says "is not set" or does not
# mention it at all. A plain sed only works while upstream keeps writing the
# "is not set" line; NET_DSA_REALTEK_MDIO already disappeared from config-7.3
# (the 7.3 driver split), so append as a fallback.
enable_sym() {
	local sym="$1" val="$2"
	sed -e "/^# CONFIG_${sym} is not set\$/d" -e "/^CONFIG_${sym}=/d" \
		"$KCFG" > "$KCFG.tmp" && mv "$KCFG.tmp" "$KCFG"
	printf 'CONFIG_%s=%s\n' "$sym" "$val" >> "$KCFG"
}

enable_sym NET_SWITCHDEV y
enable_sym NET_DSA y
enable_sym NET_DSA_REALTEK m
# 7.3 split the Realtek DSA driver: realtek_dsa.ko carries the core, the
# RTL8365MB subdriver and the MDIO transport are separate objects. The board
# talks to the RTL8367S over MDIO (see the DTS), so that transport is required.
enable_sym NET_DSA_REALTEK_MDIO y
enable_sym NET_DSA_TAG_RTL8_4 m

grep -E '^CONFIG_(NET_DSA|NET_SWITCHDEV|NET_DSA_REALTEK|NET_DSA_REALTEK_MDIO|NET_DSA_TAG_RTL8_4)=' "$KCFG" || {
	echo "ERROR: could not enable DSA in $KCFG" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# 4b. kmod-phy-realtek -> kmod-phy-package (7.3)
#
# 7.3 moved the shared PHY helpers into drivers/net/phy/phy_package.c
# (CONFIG_PHY_PACKAGE, selected by REALTEK_PHY).  Upstream added the
# kmod-phy-package definition and taught kmod-phy-micrel to depend on it, but
# not kmod-phy-realtek.  Without that dependency kmod-phy-package is never
# selected, phy_package.ko is not built, and the package stage fails with:
#
#   Package kmod-phy-realtek is missing dependencies for the following
#   libraries: phy_package.ko
#
# Add the same versioned dependency upstream uses for micrel/marvell.
# ---------------------------------------------------------------------------
say "make kmod-phy-realtek depend on kmod-phy-package"
NETDEV_MK="$LEDE/package/kernel/linux/modules/netdevices.mk"
if ! grep -q '^define KernelPackage/phy-package$' "$NETDEV_MK"; then
	echo "no KernelPackage/phy-package in this tree, nothing to do"
else
	python3 - "$NETDEV_MK" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

start = src.index("define KernelPackage/phy-realtek\n")
end = src.index("\nendef", start)
block = src[start:end]

if "kmod-phy-package" in block:
    print("kmod-phy-realtek already depends on kmod-phy-package")
    sys.exit(0)

old = "DEPENDS:=+kmod-libphy +kmod-hwmon-core"
new = old + " +(LINUX_6_18||LINUX_7_3):kmod-phy-package"
if old not in block:
    sys.exit("ERROR: unexpected kmod-phy-realtek DEPENDS in " + path)

open(path, "w").write(src[:start] + block.replace(old, new, 1) + src[end:])
print("patched kmod-phy-realtek DEPENDS")
PY
fi

# ---------------------------------------------------------------------------
# 5. generic patch series
#
# 6.18 needed the MxL862xx series dropped: it stopped applying and took the
# kernel-headers step down ~30 minutes into the build (#47-#52), and its DSA
# tag ids were load bearing for target patch 0130.
#
# The 7.3 series imported in LEDE f61f09e is self-consistent (upstream
# replayed it with zero fuzz) and applies as shipped, so nothing is removed
# here - dropping half of it would break the 795-0x mtk_ppe patches that
# reference the MxL862xx tag ids. If a future pin breaks a generic patch, the
# "Preflight kernel patches" CI step reports it in minutes.
# ---------------------------------------------------------------------------
say "generic patch series: using upstream as shipped"

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
# parameters added by kernel/patches/200-mt7916-led-mux.patch.
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
