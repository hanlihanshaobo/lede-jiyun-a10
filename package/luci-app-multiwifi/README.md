# luci-app-multiwifi

在 OpenWrt / Lean LEDE 上按 SSID 分流：

- 每个逻辑 SSID 一个独立 bridge + `/24` 子网 + DHCP + firewall zone
- 每个 SSID 绑定一条 PassWall2 访问控制（ACL）规则
- 2.4G / 5G 可以分别配置任意数量的 SSID
- “双频”一行表示同一个 SSID 同时开 2.4G/5G，共用一个子网和线路
- 保留原有 `default_radio0/1`（`jiyun-mac.sh` 管理的默认 SSID）不动

## 入口

LuCI：**网络 → 多 SSID 分流**

## 生成规则

以 UCI section `cfgxxxxxx` 为例，脚本生成：

| 配置 | 名称 |
|---|---|
| network interface | `mws_<6位md5>` |
| bridge | `br-mws_<6位md5>` |
| DHCP | `mws_<6位md5>` |
| firewall zone | `mws_<6位md5>` |
| forwarding | `mws_<6位md5>_fwd` |
| wifi-iface 2.4G | `mws_<6位md5>_24` |
| wifi-iface 5G | `mws_<6位md5>_5` |
| PassWall2 ACL | `mws_<6位md5>` |

名称控制在 15 字符以内，避免 Linux 网卡名限制。

## 应用流程

1. 校验 SSID / 频段 / 密码 / 节点 / 子网
2. 自动分配 `192.168.80.0/24` 起的空闲 `/24`（可手工指定 `x.x.x.1/24`）
3. 备份 network/dhcp/firewall/wireless/passwall2 到 `/etc/multiwifi/backup/`
4. 只增删改 `mws_*` 段，不碰用户已有配置
5. `uci commit` → `wifi reload` → `network reload` → `fw4 reload` → `passwall2 restart`
6. 失败自动回滚

日志：`/tmp/multiwifi-apply.log`，页面顶部可直接展开查看。

## 注意

- 只有“启用”的行会生成 network/wireless/firewall/ACL；取消勾选或全局停用会移除这些生成段，但保留 `/etc/config/multiwifi` 里的 SSID 配置，方便下次再开。
- PassWall2 必须先完成初始化（至少打开一次并配置节点），并保持运行；本工具只写 ACL，不会替你启用 PassWall2 全局开关。
- PassWall2 全局关闭时，会额外生成一条 `mws_unmatched_direct`（mode=0）ACL，把未匹配流量保持直连，避免 PassWall2 默认 ACL 把 LAN/默认 SSID 带到全局节点；PassWall2 全局开启时不加这条。这条只覆盖客户端，路由器本机流量仍受 PassWall2“本机代理”设置影响。
- 每个非“直连”的 SSID 会在 PassWall2 里生成一条 `acl_rule`，并启动对应的 core/dnsmasq 实例；4-8 个 SSID 在 2GB 内存的 A10 上没问题，不建议开几十个。
- 2.4G 建议不超过 4 个 BSS，5G 建议不超过 8 个 BSS（beacon/airtime 限制）。
- OpenClash 可以保留安装，但不要和 PassWall2 同时运行；页面会检测并提示。
- 本工具默认关闭新 SSID 的 IPv6（DHCPv6/RA disabled），避免 PassWall2 IPv6 规则不完整导致泄漏。
- 修改无线配置可能瞬断 WiFi；建议从 LAN 口操作。页面提供“恢复上次应用的配置”。
- 如果新增 BSS 没出现，SSH 执行 `wifi down; wifi up`（会断开所有 WiFi 几秒）。

## CLI

```sh
/usr/libexec/multiwifi-apply apply
/usr/libexec/multiwifi-apply restore
cat /tmp/multiwifi/status
```
