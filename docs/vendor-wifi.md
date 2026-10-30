# 闭源 WiFi 驱动移植 — 评估与计划

## 结论先行

原厂 WiFi 驱动是 **二进制 ko**，只面向 **Linux 5.10.160**（原厂内核），
不能在当前的 6.18.55 上加载。要“移植”只有两条真正可行的路：

- **A. 做一版 5.10 内核的 OpenWrt**，让原厂 ko 直接跑（工作量在“给 RK3568 拉一套 5.10 内核 + 板级 DTS + 原厂驱动依赖的 cfg80211 配置”）；
- **B. 拿联发科 mt_wifi 源码，回移到 6.18**（cfg80211/nl80211 从 5.10 到 6.18 变化很大，属于月级工程）。

当前开源 `mt7915` 驱动在这块板上 2.4G/5G 都正常，闭源驱动的主要收益只有厂商私有特性/工具，
所以除非有明确的功能刚需，不建议走 B。

## 已确认的事实

| 项 | 值 |
|---|---|
| 原厂内核 | `Linux version 5.10.160 (root@ubuntu) ... #3739 SMP Fri Aug 2 06:26:35 CST 2024` |
| 原厂 vermagic | `5.10.160 SMP mod_unload aarch64` |
| 原厂 WiFi 驱动 | `mt_wifi.ko`（MT7915/MT7916 厂商驱动，二进制；md5 `bc1bb1d8…`） |
| 当前 OpenWrt 内核 | 6.18.55（LEDE rockchip target） |
| 当前开源驱动 | `kmod-mt7915e`（mt76），两频段正常 |

## 路径 A：5.10 内核 + 原厂 ko

需要：

1. 一套 5.10.y 内核 + RK3568 支持 + 本板 DTS（`rk3568-jiyun-a10.dts` 可直接用，但要 5.10 的 pinctrl/驱动 API 兼容）；
2. 原厂 ko 依赖的内核配置（`CONFIG_CFG80211`、`CONFIG_MAC80211`、`CONFIG_WIRELESS_EXT`、`CONFIG_MODVERSIONS=n` 等），
   最好直接从原厂 `stock_kernel.config` 抄；
3. 原厂 ko、firmware、用户态工具（`mtwifi` 脚本 / `iwpriv` / `mt76` 厂商工具）；
4. 5.10 的 cfg80211 版本必须与 ko 的 vermagic 匹配（同一 5.10.160 + 同 config hash 最稳）。

风险：LEDE 的 rockchip target 只维护 6.18，拉 5.10 等于自建一个 target；而且原厂 ko 的
符号依赖（`cfg80211_*`、`mac80211_*` 的具体 ABI）很难在非原厂 config 下完全对齐。

## 路径 B：源码回移到 6.18

需要联发科的 `mt_wifi` 源码（mtk-openwrt-feeds / 厂商 SDK）。它面向 5.4/5.10，
回移到 6.18 要处理：

- `cfg80211_ops` / `ieee80211_ops` 的函数签名与字段变化；
- `net_device`、`skb`、`timer`、`workqueue` 等内核 API；
- PCIe 枚举、DMA、MSI 的中断/资源接口；
- 授权（闭源驱动通常不允许再分发，仓库里只能放补丁/脚本，不能放源码）。

## 需要你确认

1. **为什么要闭源驱动？** 性能 / 6GHz / WPA3 / 厂商私有功能（EasyMesh、Band Steering）/ 稳定性？
2. 目标内核：接受 **5.10**（路径 A，能直接用原厂 ko），还是坚持 **6.18**（路径 B，月级工程）？
3. 是否能拿到：
   - 原厂 eMMC rootfs 备份（含 `mt_wifi.ko`、firmware、`mtwifi` 工具）；
   - 联发科 `mt_wifi` 源码/feed 及其授权。
