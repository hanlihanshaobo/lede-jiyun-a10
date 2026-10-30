local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local jsonc = require "luci.jsonc"
local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local uci = require "luci.model.uci".cursor()

-- Keep the last committed multiwifi config around for a coherent rollback.
-- This runs before Map:parse(), so on POST it captures the pre-edit file.
sys.call("mkdir -p /tmp/multiwifi && cp -f /etc/config/multiwifi /tmp/multiwifi/prev-multiwifi 2>/dev/null")

local m, s, o

-- Must stay in sync with make_net() in /usr/libexec/multiwifi-apply.
-- The key is "SSID|band", not the UCI section name: CBI-created sections are
-- anonymous internally (cfgXXXX) but `uci show` calls them @ssid[n], so the
-- two sides cannot agree on the section name. SSID+band is stable and unique
-- (duplicate SSIDs are rejected by the apply script).
-- mws_ + 6 hex keeps br-mws_xxxxxx below the 15-char interface limit.
local function net_for(section)
	local ssid = uci:get("multiwifi", section, "ssid") or ""
	local band = uci:get("multiwifi", section, "band") or "2g"
	local q = util.shellquote(tostring(ssid) .. "|" .. tostring(band))
	local h = sys.exec("printf '%s' " .. q .. " | md5sum | cut -c1-6")
	h = tostring(h or ""):gsub("%s+$", "")
	if h == "" then
		h = sys.exec("printf '%s' " .. q .. " | cksum | cut -d' ' -f1")
		h = string.format("%06x", tonumber(tostring(h or ""):gsub("%s+$", "")) or 0)
	end
	return "mws_" .. h
end

m = Map("multiwifi", translate("多 SSID 分流"),
	translate("每个 SSID 使用独立子网，并通过 PassWall2 的访问控制指定线路。"))
m.redirect = dispatcher.build_url("admin", "network", "multiwifi")

-- ---------------------------------------------------------------------------
-- Global
-- ---------------------------------------------------------------------------
s = m:section(NamedSection, "global", "global", translate("全局设置"))
s.addremove = false

o = s:option(Flag, "enabled", translate("启用本页配置"))
o.default = 1
o.rmempty = false
o.description = translate("关闭后保留本页的 SSID 配置，但会移除生成的网络/无线/防火墙/PassWall2 ACL；重新启用后重建。单行“启用”取消也是同样效果。")

o = s:option(Value, "subnet_base", translate("自动子网起始"))
o.default = "192.168.80.0/24"
o.rmempty = false
o.description = translate("留空子网的 SSID 会从这里按 /24 顺序分配。例如 192.168.80.0/24、192.168.81.0/24。")
o.validate = function(self, value)
	local a, b, c, d, mask = tostring(value or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)/(%d+)$")
	if not a or tonumber(mask) ~= 24 then
		return nil, translate("格式应为 x.x.x.0/24")
	end
	for _, n in ipairs({ a, b, c, d }) do
		if tonumber(n) > 255 then
			return nil, translate("IP 地址无效")
		end
	end
	return value
end

o = s:option(Value, "ssid_count", translate("WiFi 数量"))
o.default = 3
o.datatype = "range(1,32)"
o.rmempty = false
o.description = translate("输入要添加的行数，再点下方“添加 N 个 SSID”。只添加行，不会自动删除已有行；频段/线路再逐行设置。")

-- ---------------------------------------------------------------------------
-- Status / warnings
-- ---------------------------------------------------------------------------
s = m:section(SimpleSection, translate("运行状态"))
o = s:option(DummyValue, "_status")
o.rawhtml = true
o.cfgvalue = function()
	local out = {}
	local has_pw = fs.access("/etc/config/passwall2")

	if has_pw then
		out[#out + 1] = translate("PassWall2：已安装")
		local nodes = 0
		uci:foreach("passwall2", "nodes", function() nodes = nodes + 1 end)
		out[#out + 1] = string.format(translate("可用线路：%d 个"), nodes)
	else
		out[#out + 1] = "<span class='mw-err'>" .. translate("PassWall2：未安装") .. "</span>"
	end

	if has_pw and sys.call("pidof xray >/dev/null 2>&1 || pidof sing-box >/dev/null 2>&1") == 0 then
		out[#out + 1] = "<span class='mw-up'>" .. translate("PassWall2：运行中") .. "</span>"
	else
		out[#out + 1] = "<span class='mw-down'>" .. translate("PassWall2：未运行") .. "</span>"
	end

	if sys.call("pidof clash >/dev/null 2>&1 || pidof mihomo >/dev/null 2>&1 || pidof clash_tun >/dev/null 2>&1") == 0 then
		out[#out + 1] = "<span class='mw-err'>" ..
			translate("OpenClash 正在运行，请先停止，避免和 PassWall2 抢 nftables/DNS。") .. "</span>"
	else
		out[#out + 1] = translate("OpenClash：未运行（可以保留安装，但不要和 PassWall2 同时启动）")
	end

	local log = fs.readfile("/tmp/multiwifi-apply.log")
	if log and #log > 0 then
		out[#out + 1] = "<details><summary>" .. translate("上次应用日志") ..
			"</summary><pre class='mw-pre' style='max-height:320px'>" ..
			util.pcdata(log) .. "</pre></details>"
	end

	return table.concat(out, "<br/>")
end

-- ---------------------------------------------------------------------------
-- Usage notes (visible in LuCI)
-- ---------------------------------------------------------------------------
s = m:section(SimpleSection, translate("使用说明与注意事项"))
o = s:option(DummyValue, "_notes")
o.rawhtml = true
o.cfgvalue = function()
	return [=[
<style>
.mw-app { color: var(--text_color, inherit); }
.mw-pre {
	margin: 8px 0;
	padding: 8px 10px;
	background: var(--sectionbg_color2, rgba(127,127,127,.12));
	border: 1px solid var(--border_color, rgba(127,127,127,.18));
	border-radius: 6px;
	color: var(--text_color, inherit);
	white-space: pre-wrap;
	overflow: auto;
}
.mw-app code {
	padding: 0 .25em;
	border-radius: 3px;
	background: var(--inputbg_color, rgba(127,127,127,.12));
	color: var(--text_color, inherit);
}
.mw-up { color: #27ae60; font-weight: bold; }
.mw-down { color: var(--text_color, #888); opacity: .65; }
.mw-err { color: #e74c3c; }
#cbi-table-table .cbi-button { margin: 2px 6px 2px 0; }
#cbi-table-table, #cbi-multiwifi-ssid { overflow-x: auto; }
</style>
<div class="mw-app" style="line-height:1.75">
<p><b>工作方式：</b>一个 SSID = 一个独立 bridge/子网 = 一条 PassWall2 ACL。2.4G/5G 分开计数，每行选频段；同一 SSID 要双频请用“双频”一行，不要建两行同名。</p>
<pre class="mw-pre">SSID A ── br-mws_xxxxxx 192.168.80.1/24 ── PassWall2 ACL ── 香港节点
SSID B ── br-mws_yyyyyy 192.168.81.1/24 ── PassWall2 ACL ── 日本节点
SSID C ── br-mws_zzzzzz 192.168.90.1/24 ── PassWall2 ACL ── 直连</pre>
<ul style="margin:0 0 0 1.2em;list-style:disc">
<li><b>先决条件：</b>PassWall2 必须先打开一次、配置好节点并保持运行。本工具只写 ACL，不会替你启用 PassWall2 全局开关。</li>
<li><b>全局开关：</b>PassWall2 全局关闭时，本工具会追加一条“未匹配流量直连”ACL，避免 PassWall2 的默认 ACL 把 LAN/默认 SSID 也带到全局节点；全局开启时则保持跟随全局。</li>
<li><b>本机流量：</b>上面这条只覆盖客户端；路由器自己的 opkg/NTP/DDNS 仍受 PassWall2“本机代理”设置影响。全局关闭时如遇本机无网，请在 PassWall2 的“其他设置”里关闭本机代理。</li>
<li><b>OpenClash：</b>可以保留安装，但不要和 PassWall2 同时运行；页面顶部会检测并提示。</li>
<li><b>应用：</b>“保存并应用”才会重启无线/防火墙/PassWall2；“保存”只写配置不生效。建议从 LAN 口操作，改无线可能瞬断 WiFi。</li>
<li><b>回滚：</b>每次应用前会备份 network/dhcp/firewall/wireless/passwall2 和上一版 multiwifi；应用失败会自动回滚，也可以点“恢复上次应用的配置”手工回滚。</li>
<li><b>数量：</b>2.4G 建议不超过 4 个 SSID，5G 不超过 8 个；每个非直连 SSID 会多一套 core + dnsmasq，2GB 内存开 4-8 个没问题。</li>
<li><b>批量建行：</b>“WiFi 数量”只决定“添加 N 个 SSID”一次加几行；不会自动删除已有行，频段/线路再逐行设置。</li>
<li><b>子网：</b>留空自动分配 /24；手填必须是 <code>x.x.x.1/24</code>，且不能和 LAN/WAN 或已有 SSID 冲突。</li>
<li><b>原有 SSID：</b><code>default_radio0/1</code>（Dwrt-…）不由本页管理，保留原样。</li>
<li><b>IPv6：</b>新 SSID 默认关闭 DHCPv6/RA，避免 PassWall2 IPv6 规则不完整导致泄漏；需要 IPv6 请单独配置。</li>
<li><b>生成段：</b>network/dhcp/firewall/wireless/passwall2 里所有 <code>mws_*</code> 段由本页管理，不要手工改；取消“启用”或全局停用会移除这些段，但保留本页 SSID 配置。</li>
<li><b>BSS 没起来：</b>SSH 执行 <code>wifi down; wifi up</code>（会断开所有 WiFi 几秒）。</li>
<li><b>日志：</b>详细应用日志在页面顶部“运行状态”里展开，或看 <code>/tmp/multiwifi-apply.log</code>。</li>
</ul>
</div>
]=]
end

-- ---------------------------------------------------------------------------
-- SSID table
-- ---------------------------------------------------------------------------
s = m:section(TypedSection, "ssid", translate("SSID 与线路"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"
s.description = translate("每个 SSID 使用独立子网。频段选“双频”时，2.4G/5G 共用同一个子网和线路；只想开某个频段就单独选 2.4G 或 5G。")

o = s:option(Flag, "enabled", translate("启用"))
o.default = 1
o.rmempty = false

o = s:option(Value, "ssid", translate("SSID"))
o.rmempty = false
o.validate = function(self, value)
	value = tostring(value or "")
	if value == "" then
		return nil, translate("SSID 不能为空")
	end
	if #value > 32 then
		return nil, translate("SSID 最长 32 字节")
	end
	return value
end

o = s:option(ListValue, "band", translate("频段"))
o:value("2g", "2.4G")
o:value("5g", "5G")
o:value("both", translate("双频（同一子网）"))
o.default = "2g"
o.rmempty = false

o = s:option(ListValue, "encryption", translate("加密"))
o:value("psk2", "WPA2-PSK")
o:value("sae-mixed", "WPA2/WPA3 混合")
o:value("none", translate("开放网络"))
o.default = "psk2"
o.rmempty = false

o = s:option(Value, "key", translate("密码"))
o.password = true
o.rmempty = true
o.description = translate("WPA2/WPA3 为 8-63 位；开放网络留空。")
o.validate = function(self, value)
	value = tostring(value or "")
	if value ~= "" and (#value < 8 or #value > 63) then
		return nil, translate("密码长度需为 8-63 位")
	end
	return value
end

o = s:option(ListValue, "node", translate("PassWall2 线路"))
o:value("__direct__", translate("直连（不走代理）"))
o.default = "__direct__"
o.rmempty = false

if fs.access("/etc/config/passwall2") then
	local global_node = uci:get("passwall2", "@global[0]", "node")
	local global_remark
	if global_node then
		global_remark = uci:get("passwall2", global_node, "remarks")
	end
	if global_remark and global_remark ~= "" then
		o:value("__global__", string.format(translate("跟随全局（%s）"), global_remark))
	else
		o:value("__global__", translate("跟随 PassWall2 全局节点"))
	end

	uci:foreach("passwall2", "nodes", function(n)
		local label = n.remarks or n[".name"]
		local proto = n.protocol
		if proto == "_shunt" then
			label = label .. " [" .. translate("分流") .. "]"
		elseif proto == "_balancing" then
			label = label .. " [" .. translate("负载均衡") .. "]"
		elseif proto == "_urltest" then
			label = label .. " [" .. translate("自动测速") .. "]"
		elseif proto == "_iface" then
			label = label .. " [" .. translate("接口") .. "]"
		end
		if n.disabled == "1" then
			label = label .. " (" .. translate("已禁用") .. ")"
		end
		o:value(n[".name"], label)
	end)
end

o = s:option(Flag, "isolate", translate("客户端隔离"))
o.default = 1
o.rmempty = false
o.description = translate("开启后同一 SSID 内的客户端不能互访；不同 SSID 由独立防火墙 zone 隔离。")

o = s:option(Value, "subnet", translate("子网（可选）"))
o.placeholder = "192.168.80.1/24"
o.rmempty = true
o.description = translate("留空自动分配。填写时必须是 x.x.x.1/24，且不能与现有网络重复。")
o.validate = function(self, value)
	value = tostring(value or "")
	if value == "" then
		return value
	end
	local a, b, c, d, mask = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)/(%d+)$")
	if not a or tonumber(mask) ~= 24 or tonumber(d) ~= 1 then
		return nil, translate("格式应为 x.x.x.1/24")
	end
	for _, n in ipairs({ a, b, c, d }) do
		if tonumber(n) > 255 then
			return nil, translate("IP 地址无效")
		end
	end
	return value
end

o = s:option(DummyValue, "_state", translate("状态"))
o.rawhtml = true
o.cfgvalue = function(self, section)
	if self.map:get("global", "enabled") == "0" then
		return "<span class='mw-down'>" .. translate("全局停用") .. "</span>"
	end
	if self.map:get(section, "enabled") == "0" then
		return "<span class='mw-down'>" .. translate("已停用") .. "</span>"
	end
	local net = net_for(section)
	local ip = uci:get("network", net, "ipaddr")
	local raw = sys.exec("ubus call network.interface." .. net .. " status 2>/dev/null")
	local st = jsonc.parse(raw or "")
	local up = st and st.up
	local html = up and "<span class='mw-up'>UP</span>" or "<span class='mw-down'>DOWN</span>"
	if ip and ip ~= "" then
		html = html .. "<br/>" .. util.pcdata(ip) .. "/24"
	end
	return html
end

-- ---------------------------------------------------------------------------
-- Actions
--
-- Use a one-row Table rather than SimpleSection: a SimpleSection renders its
-- children with section "1" but a Map parses them with no section, so the
-- button names do not match. Table parses and renders both with section 1.
-- ---------------------------------------------------------------------------
local actions = { [1] = {} }
s = m:section(Table, actions, translate("操作"))
s.template = "cbi/tblsection"
s.description = translate("“保存并应用”会提交本页配置并立即生效；“保存”只写配置，不重启无线。下面的按钮用于批量启停、按数量建行或重试。")

o = s:option(Button, "_enable_all", " ")
o.inputtitle = translate("全部启用")
o.inputstyle = "apply"
o.write = function()
	m.uci:foreach("multiwifi", "ssid", function(x)
		m.uci:set("multiwifi", x[".name"], "enabled", "1")
	end)
	m.uci:set("multiwifi", "global", "enabled", "1")
	m.uci:commit("multiwifi")
	sys.call("/usr/libexec/multiwifi-apply apply >/dev/null 2>&1")
	http.redirect(m.redirect)
end

o = s:option(Button, "_add_rows", " ")
o.inputtitle = translate("添加 N 个 SSID")
o.inputstyle = "apply"
o.write = function()
	local n = tonumber(m:formvalue("cbid.multiwifi.global.ssid_count") or "")
	n = n and math.floor(n) or 0
	if n < 1 then n = 1 end
	if n > 32 then n = 32 end
	for i = 1, n do
		local sid = m.uci:add("multiwifi", "ssid")
		if sid then
			m.uci:set("multiwifi", sid, "enabled", "1")
			m.uci:set("multiwifi", sid, "band", "2g")
			m.uci:set("multiwifi", sid, "encryption", "psk2")
			m.uci:set("multiwifi", sid, "node", "__direct__")
			m.uci:set("multiwifi", sid, "isolate", "1")
		end
	end
	m.uci:commit("multiwifi")
	http.redirect(m.redirect)
end

o = s:option(Button, "_disable_all", " ")
o.inputtitle = translate("全部停用")
o.inputstyle = "reset"
o.write = function()
	m.uci:foreach("multiwifi", "ssid", function(x)
		m.uci:set("multiwifi", x[".name"], "enabled", "0")
	end)
	m.uci:set("multiwifi", "global", "enabled", "0")
	m.uci:commit("multiwifi")
	sys.call("/usr/libexec/multiwifi-apply apply >/dev/null 2>&1")
	http.redirect(m.redirect)
end

o = s:option(Button, "_reapply", " ")
o.inputtitle = translate("重新应用当前配置")
o.inputstyle = "apply"
o.write = function()
	m.uci:commit("multiwifi")
	sys.call("/usr/libexec/multiwifi-apply apply >/dev/null 2>&1")
	http.redirect(m.redirect)
end

o = s:option(Button, "_restore", " ")
o.inputtitle = translate("恢复上次应用的配置")
o.inputstyle = "reset"
o.write = function()
	m.uci:revert("multiwifi")
	sys.call("/usr/libexec/multiwifi-apply restore >/dev/null 2>&1")
	http.redirect(m.redirect)
end

-- The normal "Save & Apply" path commits multiwifi and then calls this hook.
m.on_after_commit = function(self)
	sys.call("/usr/libexec/multiwifi-apply apply >/dev/null 2>&1")
end

return m
