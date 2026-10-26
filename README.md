# lede-jiyun-a10

OpenWrt (Lean LEDE) adaptation for the **Jiyun A10** router (Rockchip RK3568B2),
built in the cloud with GitHub Actions.

Upstream source is **not vendored** here: the workflow clones
[`coolsnowwolf/lede`](https://github.com/coolsnowwolf/lede) and layers the files
below on top, so upstream updates are trivial.

## Layout

```
.github/workflows/build.yml     Cloud build: build -> pack-emmc / pack-spi -> release
scripts/prepare.sh              layer everything below onto a cloned LEDE tree
files/rk3568-jiyun-a10.dts      Device tree (DSA switch + PCIe + gmac)
files/armv8-jiyun-a10.mk        Device/image recipe (DEVICE_PACKAGES, IMAGE/emmc.img)
files/99-jiyun-net              uci-defaults: br-lan over lan1/2/3, wan, CID-derived MACs
files/etc/jiyun-mac.sh          per-unit WLAN MACs, runs from rc.local
files/etc/rc.local              invokes jiyun-mac.sh at the end of boot
files/mt7916_eeprom.bin         MT7916 calibration (ART/Factory copy: 2.4G+5G)
files/stock_fit_header.bin      stock FIT header template for mkfit.py
files/stock_loader.bin          stock loader partition (GPT header + idbloader)
files/stock_uboot.bin           stock u-boot FIT (U-Boot + ATF + OP-TEE + MCU)
files/mk-emmc-img.py            MBR + root.ext4 -> eMMC flashing image
configs/config.seed             seed .config (target/device, BTF off, MMC)
tools/mkfit.py                  repack kernel+DTB into the stock (data-position) FIT
tools/mk-spi-img.py             loader + u-boot + FIT -> SPI NOR flashing image
tools/extract_stock_eeprom.py   pull the EEPROM out of a SPI NOR backup
tools/rkdeveloptool             macOS build
kernel/                         RTL8367S driver backport (compiled in; the DSA driver is what runs)
```

## Local build

LEDE only cross-compiles from Linux; install the usual host dependencies first
(<https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem>).

```sh
git clone --depth 1 -b master https://github.com/coolsnowwolf/lede lede
./scripts/prepare.sh lede                     # DTS, recipe, drivers, board files
cp configs/config.seed lede/.config
(cd lede && make defconfig && make -j"$(nproc)")
```

The workflow runs exactly these steps, so a local build and a CI build produce
the same tree.

## CI

Push to `main`, run the workflow manually (Actions → *Build Jiyun A10 OpenWrt* →
*Run workflow*), or wait for the weekly schedule.

`workflow_dispatch` takes a `packages` input; push and schedule default to
`emmc`. The two packages are built by independent jobs and uploaded as
independent artifacts:

| `packages` | Artifacts |
|------------|-----------|
| `emmc` (default) | `jiyun-a10-emmc` |
| `spi` | `jiyun-a10-spi` |
| `both` | both |

1. **build** — clones LEDE, installs feeds, runs `scripts/prepare.sh`, builds the
   kernel + rootfs, and uploads only what the selected packages need (an
   eMMC-only run skips the 40 MB kernel `Image`).
2. **pack-emmc** — verifies and uploads `jiyun-a10-emmc.img`.
3. **pack-spi** — repacks `Image` + `rockchip.dtb` into a FIT with the stock FIT
   header, wraps it together with the stock loader/u-boot, and uploads
   `jiyun-a10-spi.img`.

> **The SPI package carries the kernel.** Rebuild it (`packages: both`) whenever
> the kernel, the DTS, the device recipe or the upstream LEDE revision changes.
> A newer eMMC rootfs flashed against an older SPI package will have kmods that
> do not match the running kernel. `output/kernel.sha256` from two runs tells you
> whether the kernel actually changed.

## Flash packages

Every successful build publishes to the rolling
[`latest` release](https://github.com/hanlihanshaobo/lede-jiyun-a10/releases/latest),
which always keeps the newest of both files:

```sh
curl -LO https://github.com/hanlihanshaobo/lede-jiyun-a10/releases/latest/download/jiyun-a10-spi.img
curl -LO https://github.com/hanlihanshaobo/lede-jiyun-a10/releases/latest/download/jiyun-a10-emmc.img
```

A run that only rebuilds the eMMC package overwrites that asset and leaves the
SPI asset in place, so the download links never break.

The build produces exactly two files, which are all that is needed to bring up a
device with **both SPI NOR and eMMC blank** (maskrom is then the only entry
point):

| Artifact | Content | Where to write |
|----------|---------|----------------|
| `jiyun-a10-spi.img` | loader `0x0` + u-boot `0x100000` + FIT `0x300000` (8.6 MB) | SPI NOR, `wl 0` |
| `jiyun-a10-emmc.img` | MBR + root.ext4 `@ LBA 2048` (257 MB) | eMMC, `wl 0` |

```sh
RKD=./tools/rkdeveloptool
$RKD ld && $RKD cs 9 && $RKD wl 0 jiyun-a10-spi.img   # 1. maskrom: whole boot chain
# power-cycle, hold RESET -> loader mode
$RKD ld && $RKD cs 1 && $RKD wl 0 jiyun-a10-emmc.img  # 2. loader mode: rootfs
```

Step 1 in one write is what makes a blank device recoverable: the 8.6 MB package
fits the maskrom 32 MB write window, so a loader is installed even though there
was none, and step 2 then runs in loader mode (no 32 MB limit, 257 MB is fine).

Step 1 replaces the `Kernel` partition, i.e. only the kernel changes on a normal
upgrade; the loader/u-boot bytes are identical to the stock ones.

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
  `NET_DSA`/`NET_SWITCHDEV`/RTL8366 symbols, so `scripts/prepare.sh` flips them.
  `NET_DSA`/`NET_SWITCHDEV`/RTL8366 symbols, so the workflow `sed`s them out.
- **BTF must be off** (`# CONFIG_KERNEL_DEBUG_INFO_BTF is not set`), otherwise
  `cfg80211` fails module BTF validation and the whole wireless stack refuses to
  load.
