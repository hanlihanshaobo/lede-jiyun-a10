# lede-jiyun-a10

OpenWrt (Lean LEDE) adaptation for the **Jiyun A10** router (Rockchip RK3568B2),
built in the cloud with GitHub Actions.

Upstream source is **not vendored** here: the workflow clones
[`coolsnowwolf/lede`](https://github.com/coolsnowwolf/lede) and layers the files
below on top, so upstream updates are trivial.

## Layout

```
.github/workflows/build.yml     Cloud build: build -> pack-emmc / pack-spi -> artifacts
.github/workflows/build-podkop.yml  Slim Podkop variant (separate config/workflow)
scripts/prepare.sh              layer everything below onto a cloned LEDE tree
scripts/mk-sysupgrade.sh        root.ext4 + kernel FIT -> in-system upgrade tar
files/rk3568-jiyun-a10.dts      Device tree (DSA switch + PCIe + gmac)
files/armv8-jiyun-a10.mk        Device/image recipe (DEVICE_PACKAGES, IMAGE/emmc.img)
files/lib/upgrade/platform.sh   sysupgrade hook: eMMC rootfs + SPI Kernel FIT
files/99-jiyun-net              uci-defaults: br-lan over lan1/2/3, wan, CID-derived MACs
files/etc/jiyun-mac.sh          per-unit WLAN MACs, runs from rc.local
files/etc/rc.local              invokes jiyun-mac.sh at the end of boot
files/mt7916_eeprom.bin         MT7916 calibration (ART/Factory copy: 2.4G+5G)
files/stock_fit_header.bin      stock FIT header template for mkfit.py
files/stock_loader.bin          stock loader partition (GPT header + idbloader)
files/stock_uboot.bin           stock u-boot FIT (U-Boot + ATF + OP-TEE + MCU)
files/mk-emmc-img.py            MBR + root.ext4 -> eMMC flashing image
package/luci-app-multiwifi/     Multi-SSID + PassWall2 routing app (installed by prepare.sh)
package/luci-app-macsplit/      Per-MAC PassWall2 routing app (wired + wireless, installed by prepare.sh)
package/podkop/                 Podkop daemon + sing-box procd service (config-selected)
package/luci-app-podkop/        Podkop LuCI app (config-selected)
configs/config.seed             seed .config (target/device, BTF off, MMC)
configs/config.podkop.seed      slim variant: no QModem/SSR+/OpenClash/eMMC health/Vlmcsd/vsftpd, + Podkop
scripts/mkfit.py                repack kernel+DTB into the stock (data-position) FIT
scripts/mk-spi-img.py           loader + u-boot + FIT -> SPI NOR flashing image
kernel/patches/                 our kernel patches (RTL8367S LED regs, MT7916 LED mux);
                                900-net-phy-add-rtl8367s is reference only, NOT injected - DSA runs
```

## Local build

LEDE only cross-compiles from Linux; install the usual host dependencies first
(<https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem>).

```sh
git clone --depth 1 -b master https://github.com/coolsnowwolf/lede lede
./scripts/prepare.sh lede                     # main profile: DTS, recipe, drivers, board files
cp configs/config.seed lede/.config
(cd lede && make defconfig && make -j"$(nproc)")

# slim Podkop profile instead:
JIYUN_PROFILE=podkop ./scripts/prepare.sh lede
cp configs/config.podkop.seed lede/.config
(cd lede && make defconfig && make -j"$(nproc)")
```

The workflow runs exactly these steps, so a local build and a CI build produce
the same tree.

## CI

Push to `main`, run the workflow manually (Actions → *Build Jiyun A10 OpenWrt* →
*Run workflow*), or wait for the weekly schedule.

`workflow_dispatch` takes a `packages` input; push and schedule default to
`both`. Every build is downloaded from the Actions run page (*Summary* →
*Artifacts*); this repository no longer publishes GitHub Releases. The two
packages are built by independent jobs and uploaded as independent artifacts:

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

## Podkop variant

`build-podkop.yml` builds a second, independent profile from
`configs/config.podkop.seed` and `Device/jiyun_a10_podkop`:

* removed: QModem, ShadowSocksR Plus+, OpenClash, eMMC health, Vlmcsd KMS,
  vsftpd, multi-SSID routing (`luci-app-multiwifi`) and per-MAC routing
  (`luci-app-macsplit`);
* kept: PassWall2 (nftables transparent proxy), ZeroTier, Disk Man, themes;
* added: `podkop` + `luci-app-podkop` (and its sing-box/nft-tproxy/bind-dig
  runtime dependencies).

The packages are vendored under `package/` (like `luci-app-emmc-health`), so
any `.config` can select them; `config.podkop.seed` is just the config that
does.  The LuCI app ships `en`, `ru` and `zh-cn` (简体中文); the seed selects
`luci-i18n-podkop-zh-cn`, so after flashing choose *System → System → Language
→ 简体中文* to switch the UI.

Podkop requires the **service** form of sing-box (`/etc/init.d/sing-box`,
`/etc/config/sing-box`, `/etc/sing-box/config.json`), not just the binary.
Lean's `sing-box` package only installs `/usr/bin/sing-box` because PassWall2
invokes it directly, so `package/podkop/` ships the official OpenWrt init
script and UCI defaults; Podkop sets `enabled/user/conffile` and starts the
service itself.

Podkop's upstream Makefile declares a package conflict with
`luci-app-passwall2`. This variant keeps PassWall2 installed and removes only
that conflict word in `prepare.sh`; the two daemons both own nftables/dnsmasq
state, so **run only one at a time**.

Every run uploads a single `build-output-podkop` Actions artifact
(*Actions → Build Jiyun A10 Podkop → run → Summary → Artifacts*). It contains:

| File | Content |
|------|---------|
| `jiyun-a10-podkop-emmc.img` | MBR + root.ext4 (USB `wl 0`) |
| `jiyun-a10-podkop-spi.img` | loader + u-boot + FIT (USB `wl 0`) |
| `jiyun-a10-podkop-sysupgrade.tar` | in-system upgrade: eMMC rootfs **and** SPI `Kernel` FIT |

The sysupgrade tar is an uncompressed tar with fwtool metadata appended:
`sysupgrade-jiyun_a10/{CONTROL,kernel,root}`. `files/lib/upgrade/platform.sh`
writes the FIT to SPI NOR `Kernel` first, then streams the ext4 onto
`/dev/mmcblk0p1`, extracts the saved config onto the new rootfs, and leaves the
first-boot initramfs to grow p1 to the full eMMC. The initramfs uses
`resize2fs -f` because the freshly written rootfs has been mounted rw and the
default resize2fs check refuses to grow it; the hook keeps a stage-2 log at
eMMC LBA 1020 (`dd if=/dev/mmcblk0 bs=512 skip=1020 count=8 | strings`).

The hook is only installed in the Podkop image. For the **first** upgrade from
an older build that still has the generic `platform.sh`, copy the hook first;
afterwards LuCI's *System → Backup / Flash Firmware* works directly:

```sh
ssh root@192.168.68.1 'cat > /tmp/platform.sh' < files/lib/upgrade/platform.sh
ssh root@192.168.68.1 'cp /lib/upgrade/platform.sh /lib/upgrade/platform.sh.old;
  cp /tmp/platform.sh /lib/upgrade/platform.sh'
ssh root@192.168.68.1 'cat > /tmp/podkop-sysupgrade.tar' < jiyun-a10-podkop-sysupgrade.tar
ssh root@192.168.68.1 'sysupgrade -v /tmp/podkop-sysupgrade.tar'
```

(Dropbear on OpenWrt has no sftp-server, so `scp` fails; pipe the files through
`ssh ... 'cat > ...'`.)

## Flash packages

There are no GitHub Releases anymore. Download the latest run's artifacts from
*Actions → Build Jiyun A10 OpenWrt → run → Summary → Artifacts*:

- `jiyun-a10-emmc` — zip containing `jiyun-a10-emmc.img`
- `jiyun-a10-spi` — zip containing `jiyun-a10-spi.img`

The build produces exactly two files, which are all that is needed to bring up a
device with **both SPI NOR and eMMC blank** (maskrom is then the only entry
point):

| Artifact | Content | Where to write |
|----------|---------|----------------|
| `jiyun-a10-spi.img` | loader `0x0` + u-boot `0x100000` + FIT `0x300000` (8.6 MB) | SPI NOR, `wl 0` |
| `jiyun-a10-emmc.img` | MBR + root.ext4 `@ LBA 2048` (257 MB) | eMMC, `wl 0` |

```sh
RKD=rkdeveloptool
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
| Kernel | Linux 7.3.1 (`KERNEL_PATCHVER:=7.3`; upstream still ships rockchip on 6.18, so `prepare.sh` bumps the target and seeds `patches-7.3`) |
| Rootfs | eMMC `mmcblk0p1` (ext4), 256 MB image; the first-boot online resize aborts at 377.8 MB on kernel 6.18 (`make_ext4fs` GDT layout, not re-checked on 7.3) — use the top-level `scripts/expand_emmc_offline.sh` (offline resize + p1 stream) until the image recipe is fixed |
| Switch | Realtek RTL8367S, MDIO 0x1d, CPU port 7, driven by `kmod-dsa-rtl8365mb` |
| Ports | LAN = switch ports 0/1/3, WAN = port 4 (port 2 unpopulated) |
| WiFi | MediaTek MT7916 x2 (PCIe `01:00.0` = 2.4G, `02:00.0` = 5G) |
| Debug UART | 1500000 8N1 |
| Management | 192.168.68.1 / `password`, hostname `Dwrt` |
| WiFi SSID | `Dwrt-<last 6 hex of each radio BSSID>-2.4G` / `-5G` (default theme `luci-theme-design`) |

## Gotchas worth remembering

- **EEPROM choice**: only the ART/Factory copy declares 2.4G+5G. The array inside
  the vendor `mt_wifi.ko` and the mt76 default file both declare 6G+5G and make
  the 2.4 GHz radio disappear (`freqlist` starts at 5.955 GHz, hostapd logs
  `Could not determine operating frequency`).
- **First-boot wifi config**: `S18fanctrl` runs `/sbin/wifi config` and rewrites
  `/etc/config/wireless`, so WLAN MACs must be applied from `rc.local`, not from
  `/etc/uci-defaults`; hostapd needs `wifi down/up` (a SIGHUP won't change BSSID).
- **FIT format**: the 2017.09 u-boot only understands `data-position`; `mkimage -E`
  emits `data-offset`, hence `scripts/mkfit.py` patches the stock header.
- **eMMC rootfs expansion**: the 256 MB rootfs is created by `make_ext4fs` with only
  15 reserved GDT blocks, so the kernel 6.18 online resize aborts at 377.8 MB with
  `reserve_backup_gdb: reserved block 16 not at offset 15` (7.3 not re-checked
  yet). Use the top-level `scripts/expand_emmc_offline.sh` (offline `resize2fs` +
  stream to `mmcblk0p1`, MBR untouched); a 7 GB rootfs image or an initramfs
  offline resize is the long-term fix. `mke2fs` only reserves 4 GB online, so it
  is not enough for 7 GB.
- **Kernel config fragments**: `target/linux/generic/config-<ver>` disables
  `NET_DSA`/`NET_SWITCHDEV`/`NET_DSA_REALTEK*` symbols, so `scripts/prepare.sh`
  flips them (it also has to append `NET_DSA_REALTEK_MDIO`, which is not in the
  7.3 fragment at all).
- **Rockchip target patches**: upstream has no `target/linux/rockchip/patches-7.3`
  yet, so `prepare.sh` seeds it from `patches-6.18` and skips the patches that
  are not usable on 7.3.1 (`0130`, `039-*`, `106-nanopi-r4s-sd-power-cycle`,
  `113`, `700`, `803-807`; reasons in the script). Our own patches go on top.
  The order matters: target patches are applied *after* generic
  backport/pending/hack, so a patch that applies to a pristine 7.3.1 tree can
  still fail here (`039-2`).
- **7.3 build fixes**: `kernel/patches/` also carries the non-board fixes a 7.3
  build needs - arm64 UAPI `__u128` (generic hack), `kmod-phy-realtek` ->
  `kmod-phy-package` (netdevices.mk), and mac80211 backports 6.18.39
  (`mac_pton`, `struct class.namespace`, `strncpy`). See the 7.3 section of the
  porting notes for the full story.
- **BTF must be off** (`# CONFIG_KERNEL_DEBUG_INFO_BTF is not set`), otherwise
  `cfg80211` fails module BTF validation and the whole wireless stack refuses to
  load.
