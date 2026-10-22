# lede-jiyun-a10

OpenWrt (Lean LEDE) adaptation for the **Jiyun A10** router (Rockchip RK3568B2),
built in the cloud with GitHub Actions.

## Layout

```
.github/workflows/build.yml   Cloud build (clones upstream LEDE, injects support, builds)
files/rk3568-jiyun-a10.dts    Device tree
files/armv8-jiyun-a10.mk      Device/image recipe appended to rockchip/image/armv8.mk
configs/config.seed           Seed .config (target + device selection)
```

The upstream source is **not vendored** here; the workflow clones
`coolsnowwolf/lede` and layers the files above on top, so upgrades are trivial.

## Build

Push to `main`, run the workflow manually (Actions -> Build Jiyun A10 OpenWrt ->
Run workflow), or wait for the weekly schedule. Firmware is uploaded as the
`jiyun-a10-openwrt` artifact.

## Device notes

| Item | Value |
|------|-------|
| SoC | Rockchip RK3568B2 (4x Cortex-A55) |
| DRAM | ~2 GB |
| Boot storage | SPI NOR W25Q256JW 32 MB (`sfc_nor`) |
| Data storage | eMMC BWZT85 6.96 GB (`mmcblk0`) |
| Switch | Realtek RTL8367S, 5-port, CPU on `gmac1` (RGMII) |
| WiFi | MediaTek MT7916 (PCIe 14c3:7906/790a) |
| Debug UART | 1500000 8N1 |
| Stock firmware | Jiyun-A10-24.03.30V (Linux 5.10.160) |

## TODO before first flash

- Confirm exact GPIOs for LEDs/buttons, RTL8367S port map and MT7916 PCIe resets
  from the stock DTB (current DTS values are partially inferred).
- Keep a full SPI NOR backup of the stock firmware before flashing.

## Push

```sh
git remote add origin https://github.com/hanlihanshaobo/lede-jiyun-a10.git
git add -A
git commit -m "Jiyun A10: cloud build scaffold + DTS"
git push -u origin main
```
