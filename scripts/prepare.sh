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
# target/linux/generic/config-6.x explicitly disables the swconfig core, the
# RTL8367B PHY driver and the DSA core, which overrides .config - flip those
# lines so the switch driver is really built in.
# ---------------------------------------------------------------------------
say "enable switch drivers in the generic kernel config"
KCFG="$LEDE/target/linux/generic/config-6.18"
if [ ! -f "$KCFG" ]; then
	KCFG=$(ls "$LEDE"/target/linux/generic/config-6.* 2>/dev/null | head -1)
fi
[ -f "$KCFG" ] || { echo "no target/linux/generic/config-6.* in $LEDE" >&2; exit 1; }

sed \
	-e 's/^# CONFIG_SWCONFIG is not set/CONFIG_SWCONFIG=y/' \
	-e 's/^# CONFIG_RTL8366_SMI is not set/CONFIG_RTL8366_SMI=y/' \
	-e 's/^# CONFIG_RTL8367B_PHY is not set/CONFIG_RTL8367B_PHY=y/' \
	-e 's/^# CONFIG_NET_SWITCHDEV is not set/CONFIG_NET_SWITCHDEV=y/' \
	-e 's/^# CONFIG_NET_DSA is not set/CONFIG_NET_DSA=y/' \
	-e 's/^# CONFIG_NET_DSA_REALTEK is not set/CONFIG_NET_DSA_REALTEK=m/' \
	-e 's/^# CONFIG_NET_DSA_TAG_RTL8_4 is not set/CONFIG_NET_DSA_TAG_RTL8_4=m/' \
	"$KCFG" > "$KCFG.tmp" && mv "$KCFG.tmp" "$KCFG"
grep -E '^CONFIG_(SWCONFIG|RTL8366_SMI|RTL8367B_PHY|NET_DSA|NET_SWITCHDEV|NET_DSA_REALTEK|NET_DSA_TAG_RTL8_4)=' "$KCFG" || {
	echo "ERROR: could not enable the switch drivers in $KCFG" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# 5. RTL8367S driver backport
#
# The RTL8367S support (compatible "realtek,rtl8367s", cpu_port 7) is not in
# coolsnowwolf/lede yet - take the updated, GPL-licensed rtl8367b/rtl8367
# driver from the working NSY G68 Plus tree.
# ---------------------------------------------------------------------------
say "install RTL8367S driver backport"
KVER="${KCFG##*config-}"
BP_DIR="$LEDE/target/linux/generic/backport-$KVER"
[ -d "$BP_DIR" ] || BP_DIR=$(ls -d "$LEDE"/target/linux/generic/backport-6.* | tail -1)

PHY_DIR="$LEDE/target/linux/generic/files/drivers/net/phy"
INC_DIR="$LEDE/target/linux/generic/files/include/linux"
mkdir -p "$PHY_DIR" "$INC_DIR" "$BP_DIR"
install -m 0644 "$ROOT"/kernel/files/drivers/net/phy/rtl8367.c \
	"$ROOT"/kernel/files/drivers/net/phy/rtl8367b.c \
	"$ROOT"/kernel/files/drivers/net/phy/rtl8366_smi.c \
	"$ROOT"/kernel/files/drivers/net/phy/rtl8366_smi.h "$PHY_DIR/"
install -m 0644 "$ROOT/kernel/files/include/linux/rtl8367.h" "$INC_DIR/"
install -m 0644 "$ROOT/kernel/backport-$KVER/900-net-phy-add-rtl8367s.patch" "$BP_DIR/" \
	2>/dev/null || install -m 0644 "$ROOT"/kernel/backport-6.18/900-net-phy-add-rtl8367s.patch "$BP_DIR/"
echo "backport dir: $BP_DIR"

# ---------------------------------------------------------------------------
# 6. rootfs overlay (target base-files)
# ---------------------------------------------------------------------------
say "install rootfs overlay"
BASE="$LEDE/target/linux/rockchip/base-files"

# switch configuration (CPU port into the LAN VLAN): the rtl8367b swconfig
# driver does not do that itself
mkdir -p "$BASE/etc/uci-defaults"
install -m 0755 "$ROOT/files/99-jiyun-net" "$BASE/etc/uci-defaults/99-jiyun-net"

# Per-unit WLAN MACs: the first-boot "wifi config" (S18fanctrl) rewrites
# /etc/config/wireless, so uci-defaults is too early - rc.local runs at the
# very end of boot and applies them.
install -m 0755 "$ROOT/files/etc/jiyun-mac.sh" "$BASE/etc/jiyun-mac.sh"
install -m 0755 "$ROOT/files/etc/rc.local" "$BASE/etc/rc.local"

# MT7916 needs an EEPROM blob; without it mt7915 probe fails and no wlan phy
# is registered. This is the ART/Factory copy - the only variant that declares
# 2.4G+5G (see the porting notes).
mkdir -p "$BASE/lib/firmware/mediatek"
install -m 0644 "$ROOT/files/mt7916_eeprom.bin" \
	"$BASE/lib/firmware/mediatek/mt7916_eeprom.bin"

say "done"
