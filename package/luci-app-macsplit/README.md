# luci-app-macsplit

给同一个局域网里的每个 MAC 单独指定一条 PassWall2 线路，有线和无线客户端都生效。
不用改 WiFi、不用划子网，也不需要理解 SSID/桥接。

## 原理

PassWall2 的访问控制（ACL）源支持 `mac:`，最终生成 nftables 的 `ether saddr` 匹配：

```text
电视    aa:bb:cc:00:00:01 ── ACL(mode=1) ── 香港节点
手机    aa:bb:cc:00:00:02 ── ACL(mode=1) ── 日本节点
其它设备（未匹配）        ── ACL(mode=0) ── 直连
```

二层匹配，换 IP、DHCP 续租都不影响；同一线路的多个 MAC 会合并成一条 ACL，
只启动一个 core/dnsmasq 实例。

## 入口

LuCI：**网络 → 按 MAC 分流**

## 用法

1. “添加”一行，填 MAC（`aa:bb:cc:dd:ee:ff`，也接受 `aabbccddeeff` / `AA-BB-...`）
2. 选“代理线路”（直连 / 跟随全局 / 任意 PassWall2 节点）
3. “保存并应用”

也可以从页面下方“在线设备”里选一台设备点“添加”，自动带出 MAC、IP 和主机名。

## 配置

```uci
config rule
	option enabled '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option name '电视'
	option node '__direct__'      # 或 PassWall2 节点名
```

生成的 ACL 段名：

| 线路 | ACL 段名 |
|---|---|
| 直连 | `macsplit_direct` |
| 跟随全局 | `macsplit_global` |
| 普通节点 | `macsplit_<6位md5>` |
| 未匹配直连 | `macsplit_unmatched_direct` |

所有 `macsplit_*` ACL 都由本页管理；删掉/停用所有规则并应用后会全部移除。

## 应用流程

1. 校验 MAC / 线路
2. 备份 `/etc/config/passwall2` 和 `/etc/config/macsplit`
3. 按线路分组，合并同一线路的 MAC
4. 写入 ACL（`sources` 为 MAC 列表，`interface` 自动取 LAN）
5. PassWall2 全局关闭时追加 `macsplit_unmatched_direct`
6. `uci commit passwall2` → 重启 PassWall2
7. 失败自动回滚

日志：`/tmp/macsplit-apply.log`

## 注意

- PassWall2 要先配好节点并保持运行；本页只负责把 MAC 绑到线路上。
- 没有全局开关：页面上有启用的规则就生效，全部删掉/停用后自动清理。
- “未匹配直连”只在 PassWall2 全局关闭时追加，保证其它设备不被带到全局节点。
- 与 `luci-app-multiwifi` 同用时，两边都会追加“未匹配直连”catch-all；应用时会自动把
  这类 ACL 移到列表最后，避免挡住后面新增的规则。
- 修改后必须“保存并应用”才会重建 ACL；“保存”只写配置。
