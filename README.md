# lede-jiyun-a10

OpenWrt (Lean LEDE) adaptation for the **Jiyun A10** router (Rockchip RK3568B2),
built in the cloud with GitHub Actions.

Upstream source is **not vendored** here: the workflow clones
[`coolsnowwolf/lede`](https://github.com/coolsnowwolf/lede) and layers the files
below on top, so upstream updates are trivial.

## Layout

```
.github/workflows/build.yml     Cloud build: build -> assemble, caches the LEDE tree
files/rk3568-jiyun-a10.dts      Device tree (DSA switch + PCIe + gmac)
files/armv8-jiyun-a10.mk        Device/image recipe (DEVICE_PACKAGES, IMAGE_SIZE)
files/99-jiyun-net              uci-defaults: br-lan over lan1/2/3, wan, CID-derived MACs
files/etc/jiyun-mac.sh          per-unit WLAN MACs, runs from rc.local
files/etc/rc.local              invokes jiyun-mac.sh at the end of boot
files/mt7916_eeprom.bin         MT7916 calibration (ART/Factory copy: 2.4G+5G)
files/stock_fit_header.bin      stock FIT header template for mkfit.py
configs/config.seed             seed .config (target/device, BTF off, MMC)
tools/mkfit.py                  repack kernel+DTB into the stock (data-position) FIT
tools/extract_stock_eeprom.py   pull the EEPROM out of a SPI NOR backup
tools/rkdeveloptool             macOS build
kernel/                         optional swconfig driver backport (not used by DSA path)
```

## Build

Push to `main`, run the workflow manually (Actions → *Build Jiyun A10 OpenWrt* →
*Run workflow*), or wait for the weekly schedule.

Two jobs:

1. **build** — clones LEDE, installs feeds, injects DTS/recipe/config, builds the
   kernel + image and uploads `output/` (kernel `Image`, `rockchip.dtb`,
   `root.ext4`).
2. **assemble** — repacks `Image` + `rockchip.dtb` into `jiyun-a10-openwrt.fit`
   with the stock FIT header, then uploads the final artifact.

README-only changes are ignored (`paths-ignore`), so docs don't trigger a build.

## Device notes

| Item | Value |
|------|-------|
| SoC | Rockchip RK3568B2 (4x Cortex-A55) |
| DRAM | ~2 GB |
| Boot | SPI NOR W25Q256JW 32 MB — `Kernel` partition holds a FIT (kernel + DTB) |
| Rootfs | eMMC `mmcblk0p1` (ext4), 256 MB image |
| Switch | Realtek RTL8367S, MDIO 0x1d, CPU port 7, driven by `kmod-dsa-rtl8365mb` |
| Ports | LAN = switch ports 0/1/3, WAN = port 4 (port 2 unpopulated) |
| WiFi | MediaTek MT7916 x2 (PCIe `01:00.0` = 2.4G, `02:00.0` = 5G) |
| Debug UART | 1500000 8N1 |
| Management | 192.168.10.1 / `password`, SSID `LEDE` |

## Gotchas worth remembering

- **EEPROM choice**: only the ART/Factory copy declares 2.4G+5G. The array inside
  the vendor `mt_wifi.ko` and the mt76 default file both declare 6G+5G and make
  the 2.4 GHz radio disappear (`freqlist` starts at 5.955 GHz, hostapd logs
  `Could not determine operating frequency`).
- **First-boot wifi config**: `S18fanctrl` runs `/sbin/wifi config` and rewrites
  `/etc/config/wireless`, so WLAN MACs must be applied from `rc.local`, not from
  `/etc/uci-defaults`; hostapd needs `wifi down/up` (a SIGHUP won't change BSSID).
- **FIT format**: the 2017.09 u-boot only understands `data-position`; `mkimage -E`
  emits `data-offset`, hence `tools/mkfit.py` patches the stock header.
- **Kernel config fragments**: `target/linux/generic/config-6.18` disables
  `NET_DSA`/`NET_SWITCHDEV`/RTL8366 symbols, so the workflow `sed`s them out.
- **BTF must be off** (`# CONFIG_KERNEL_DEBUG_INFO_BTF is not set`), otherwise
  `cfg80211` fails module BTF validation and the whole wireless stack refuses to
  load.
