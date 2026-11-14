local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local uci = require "luci.model.uci".cursor()

local m, s, o

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function ensure_sections()
	if not fs.access("/etc/config/macsplit") then
		return
	end
	local changed = false
	if not uci:get("macsplit", "global") then
		uci:set("macsplit", "global", "global")
		uci:set("macsplit", "global", "enabled", "0")
		uci:set("macsplit", "global", "interface", "lan")
		uci:set("macsplit", "global", "unmatched_direct", "1")
		changed = true
	end
	if changed then
		uci:commit("macsplit")
	end
end
ensure_sections()

-- "AA-BB-CC-DD-EE-FF", "aabbccddeeff" and "aa:bb:..." all map to
-- "aa:bb:cc:dd:ee:ff"; returns nil for anything that is not 12 hex digits.
local function norm_mac(v)
	v = tostring(v or ""):lower():gsub("[^0-9a-f]", "")
	if #v ~= 12 then
		return nil
	end
	return ("%s:%s:%s:%s:%s:%s"):format(
		v:sub(1, 2), v:sub(3, 4), v:sub(5, 6),
		v:sub(7, 8), v:sub(9, 10), v:sub(11, 12))
end

local function lan_device()
	local dev = uci:get("network", "lan", "device") or ""
	if dev == "" or dev:find("%s") then
		return "br-lan"
	end
	return dev
end

-- MAC -> { ip=..., host=..., online=bool }
local leases_cache
local function leases()
	if leases_cache then
		return leases_cache
	end
	local out = {}
	if fs.access("/tmp/dhcp.leases") then
		for line in io.lines("/tmp/dhcp.leases") do
			local _, mac, ip, host = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
			mac = mac and norm_mac(mac)
			if mac then
				out[mac] = {
					ip = ip,
					host = (host ~= "*" and host ~= "") and host or nil,
				}
			end
		end
	end
	local f = io.popen("ip neigh show dev %s 2>/dev/null" %
		util.shellquote(lan_device()))
	if f then
		for line in f:lines() do
			local ip, mac, state = line:match("^(%S+)%s+lladdr%s+(%S+)%s+(%S+)")
			mac = mac and norm_mac(mac)
			if mac and state ~= "FAILED" and state ~= "INCOMPLETE" then
				local e = out[mac] or {}
				e.ip = e.ip or ip
				e.online = (state == "REACHABLE" or state == "DELAY"
					or state == "PROBE" or state == "PERMANENT")
				out[mac] = e
			end
		end
		f:close()
	end
	leases_cache = out
	return out
end

local function add_node_options(o, first_label)
	o:value("__direct__", first_label or translate("直连（不走代理）"))
	if fs.access("/etc/config/passwall2") then
		local global_node = uci:get("passwall2", "@global[0]", "node")
		local global_remark = global_node and uci:get("passwall2", global_node, "remarks")
		if global_remark and global_remark ~= "" then
			o:value("__global__", string.format(translate("跟随全局（%s）"), global_remark))
		else
			o:value("__global__", translate("跟随 PassWall2 全局节点"))
		end
		local nodes = {}
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
			nodes[#nodes + 1] = { id = n[".name"], label = label }
		end)
		table.sort(nodes, function(a, b)
			return tostring(a.label):lower() < tostring(b.label):lower()
		end)
		for _, n in ipairs(nodes) do
			o:value(n.id, n.label)
		end
	end
end

m = Map("macsplit", translate("按 MAC 分流"),
	translate("同一局域网内按客户端 MAC 指定 PassWall2 线路，有线、无线客户端都适用。"))
m.redirect = dispatcher.build_url("admin", "network", "macsplit")
-- This firmware has no generic /admin/uci/apply endpoint, so let CBI commit
-- and run on_after_commit synchronously on "Save & Apply".
m.apply_on_parse = false

-- ---------------------------------------------------------------------------
-- Global
-- ---------------------------------------------------------------------------
s = m:section(NamedSection, "global", "global", translate("全局设置"))
s.addremove = false

o = s:option(Flag, "enabled", translate("启用本页配置"))
o.default = 0
o.rmempty = false
o.description = translate("默认停用。勾选并“保存并应用”后才会写入 PassWall2 ACL；取消勾选会移除本页生成的所有 ACL。")

o = s:option(Value, "interface", translate("生效接口"))
o.default = "lan"
o.rmempty = false
o.description = translate("PassWall2 ACL 绑定的网络接口，默认 lan（即 br-lan）。有线口和无线 SSID 都在这个桥上。")

o = s:option(Flag, "unmatched_direct", translate("未匹配流量直连"))
o.default = 1
o.rmempty = false
o.description = translate("PassWall2 全局关闭时，追加一条 catch-all 直连 ACL，避免默认 ACL 把其它 LAN 客户端带到全局节点。全局开启时不影响。")

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------
s = m:section(TypedSection, "rule", translate("MAC 规则"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"
s.description = translate("一条规则 = 一个 MAC + 一条线路。同一 MAC 只能出现一次；同一线路的多个 MAC 会合并成一条 ACL，只启动一个代理实例。")

o = s:option(Flag, "enabled", translate("启用"))
o.default = 1
o.rmempty = false

o = s:option(Value, "mac", translate("MAC 地址"))
o.rmempty = false
o.placeholder = "aa:bb:cc:dd:ee:ff"
o.validate = function(self, value)
	local mac = norm_mac(value)
	if not mac then
		return nil, translate("MAC 格式应为 aa:bb:cc:dd:ee:ff")
	end
	return mac
end

o = s:option(Value, "name", translate("备注"))
o.rmempty = true
o.datatype = "maxlength(24)"

o = s:option(ListValue, "node", translate("PassWall2 线路"))
o.default = "__direct__"
o.rmempty = false
add_node_options(o)

local function test_result(section)
	local f = io.open("/tmp/macsplit-test-" .. section, "r")
	if not f then
		return nil
	end
	local content = f:read("*l") or ""
	f:close()
	local result, ts = content:match("^(%S+)%s+(%S+)$")
	if not result then
		return nil
	end
	local age = os.time() - tonumber(ts)
	local when
	if age < 60 then
		when = string.format(translate("%d 秒前"), age)
	elseif age < 3600 then
		when = string.format(translate("%d 分钟前"), math.floor(age / 60))
	else
		when = string.format(translate("%d 小时前"), math.floor(age / 3600))
	end
	return result, when
end

o = s:option(Button, "_test", " ")
o.inputtitle = translate("测试")
o.inputstyle = "action"
o.forcewrite = true
o.write = function(self, section)
	-- Runs with a spoofed MAC on a temporary veth; see macsplit-apply test.
	local rc = sys.call("/usr/libexec/macsplit-apply test %s >/dev/null 2>&1" %
		{ util.shellquote(section) })
	local f = io.open("/tmp/macsplit-test-" .. section, "w")
	if f then
		f:write(((rc == 0) and "ok" or "fail") .. " " .. os.time())
		f:close()
	end
end

o = s:option(DummyValue, "_testres", translate("测试结果"))
o.rawhtml = true
o.cfgvalue = function(self, section)
	local result, when = test_result(section)
	if not result then
		return "<span class='ms-test'>" .. translate("未测试") .. "</span>"
	end
	if result == "ok" then
		return "<span class='ms-ok'>" .. translate("通") .. "</span> <span class='ms-test'>" .. when .. "</span>"
	end
	return "<span class='ms-fail'>" .. translate("不通") .. "</span> <span class='ms-test'>" .. when .. "</span>"
end

o = s:option(DummyValue, "_state", translate("状态"))
o.rawhtml = true
o.cfgvalue = function(self, section)
	local mac = norm_mac(uci:get("macsplit", section, "mac"))
	if not mac then
		return "<span class='ms-err'>" .. translate("MAC 无效") .. "</span>"
	end
	local e = leases()[mac]
	if not e then
		return "<span class='ms-down'>" .. translate("未上线") .. "</span>"
	end
	local html = ""
	if e.online then
		html = "<span class='ms-up'>" .. translate("在线") .. "</span>"
	elseif e.ip then
		html = "<span class='ms-down'>" .. translate("有租约") .. "</span>"
	else
		html = "<span class='ms-down'>" .. translate("未上线") .. "</span>"
	end
	if e.ip then
		html = html .. " <span class='ms-ip'>" .. util.pcdata(e.ip) .. "</span>"
	end
	if e.host then
		html = html .. " <span class='ms-host'>" .. util.pcdata(e.host) .. "</span>"
	end
	return html
end

-- ---------------------------------------------------------------------------
-- Online devices quick add
-- ---------------------------------------------------------------------------
s = m:section(SimpleSection, translate("在线设备"))
s.description = translate("从 DHCP 租约和邻居表里选一台设备，点“添加为规则”即可新建一行（默认直连，再改线路）。")

local devices = {}
for mac, e in pairs(leases()) do
	devices[#devices + 1] = { mac = mac, ip = e.ip, host = e.host }
end
table.sort(devices, function(a, b)
	local function key(x)
		local ip = x.ip or ""
		local a1, a2, a3, a4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		if a1 then
			return string.format("%03d.%03d.%03d.%03d", a1, a2, a3, a4)
		end
		return "999." .. tostring(x.mac)
	end
	return key(a) < key(b)
end)

local quick = { add = {} }
s = m:section(Table, quick)
s.template = "cbi/tblsection"
s.anonymous = true

o = s:option(ListValue, "_pick", translate("设备"))
-- A Table section has a plain data source (no UCI), so the default
-- AbstractValue.write() -> map:set() would fail; the button below reads the
-- value from the form and writes UCI itself.
o.write = function() end
o.remove = function() end
if #devices == 0 then
	o:value("__none__", translate("（暂无在线设备）"))
end
for _, d in ipairs(devices) do
	local label = d.mac
	if d.ip then label = label .. "  " .. d.ip end
	if d.host then label = label .. "  " .. d.host end
	o:value(table.concat({ d.mac, d.ip or "", d.host or "" }, "|"), label)
end

o = s:option(Button, "_add", " ")
o.inputtitle = translate("添加为规则")
o.inputstyle = "add"
o.write = function()
	local pick = m:formvalue("cbid.table.add._pick") or ""
	local mac = norm_mac(pick:match("^([^|]+)"))
	if not mac then
		http.redirect(m.redirect)
		return
	end
	local exists = false
	uci:foreach("macsplit", "rule", function(r)
		if norm_mac(r.mac) == mac then
			exists = true
		end
	end)
	if not exists then
		local sid = uci:add("macsplit", "rule")
		if sid then
			uci:set("macsplit", sid, "enabled", "1")
			uci:set("macsplit", sid, "mac", mac)
			uci:set("macsplit", sid, "node", "__direct__")
			local host = pick:match("^[^|]*|[^|]*|(.+)$")
			if host and host ~= "" then
				uci:set("macsplit", sid, "name", host)
			end
			uci:commit("macsplit")
		end
	end
	http.redirect(m.redirect)
end

o = s:option(Button, "_refresh", " ")
o.inputtitle = translate("刷新")
o.inputstyle = "action"
o.write = function()
	http.redirect(m.redirect)
end

-- ---------------------------------------------------------------------------
-- Notes
-- ---------------------------------------------------------------------------
s = m:section(SimpleSection, translate("使用说明与注意事项"))
o = s:option(DummyValue, "_notes")
o.rawhtml = true
o.cfgvalue = function()
	return [=[
<style>
.ms-pre {
	margin: 8px 0;
	padding: 8px 10px;
	background: var(--sectionbg_color2, rgba(127,127,127,.12));
	border: 1px solid var(--border_color, rgba(127,127,127,.18));
	border-radius: 6px;
	color: var(--text_color, inherit);
	white-space: pre-wrap;
	overflow: auto;
}
.ms-app code {
	padding: 0 .25em;
	border-radius: 3px;
	background: var(--inputbg_color, rgba(127,127,127,.12));
	color: var(--text_color, inherit);
}
.ms-up { color: #27ae60; font-weight: bold; }
.ms-down { color: var(--text_color, #888); opacity: .65; }
.ms-err { color: #e74c3c; }
.ms-ok { color: #27ae60; font-weight: bold; }
.ms-fail { color: #e74c3c; font-weight: bold; }
.ms-test { font-size: 90%; }
.ms-ip { color: var(--active_color, #5ea69b); }
.ms-host { opacity: .7; }
.ms-status { line-height: 1.7; }
.ms-status > div { margin: 2px 0; }
.cbi-tblsection .cbi-button { margin: 2px 6px 2px 0; }
.cbi-tblsection { overflow-x: auto; }
#cbi-table-table tr.cbi-section-table-titles { display: none; }
#cbi-table-table td.cbi-value-field { padding: 2px 6px; }
</style>
<div class="ms-app" style="line-height:1.75">
<p><b>原理：</b>PassWall2 的访问控制支持 <code>mac:</code> 源，会生成 <code>ether saddr</code> 的 nft 规则。所以不需要给每个客户端单独划子网，同一个 LAN 里按二层 MAC 就能把不同设备分到不同线路，有线和无线一样生效。</p>
<pre class="ms-pre">电视    aa:bb:cc:00:00:01 ── ACL ── 香港节点
手机    aa:bb:cc:00:00:02 ── ACL ── 日本节点
其它设备（未匹配）        ── ACL ── 直连</pre>
<ul style="margin:0 0 0 1.2em;list-style:disc">
<li><b>先决条件：</b>PassWall2 要先配置好节点并保持运行；本页只写 ACL，不会替你打开 PassWall2 全局开关。</li>
<li><b>合并：</b>同一线路的多个 MAC 会合并成一条 ACL，只启动一个 core/dnsmasq 实例，不会按 MAC 数量翻倍。</li>
<li><b>默认停用：</b>本页默认不启用；勾选“启用本页配置”并“保存并应用”后生效。</li>
<li><b>未匹配直连：</b>PassWall2 全局关闭时，会追加一条 <code>macsplit_unmatched_direct</code>，把不在本页规则里的 LAN 客户端保持直连；全局开启时不加这条。这条只覆盖客户端，路由器本机流量仍受 PassWall2“本机代理”设置影响。</li>
<li><b>与多 SSID 分流同用：</b>两个页面都会追加“未匹配直连”ACL。应用时会自动把这类 catch-all 移到 ACL 列表最后，避免它挡住后面新增的规则；但建议只在一个页面里开启“未匹配直连”。</li>
<li><b>测试：</b>“测试”会用该 MAC 在临时 netns/veth 里发 DNS+HTTP 请求，走这条 ACL；测试期间该 MAC 的真实设备可能瞬断，建议在设备离线时测。</li>
<li><b>状态：</b>“在线/有租约”来自 DHCP 租约和邻居表；静态 IP 设备只要和路由器有 ARP/NDP 记录也能显示。</li>
<li><b>应用：</b>“保存并应用”才会重启 PassWall2 并重建 ACL；“保存”只写配置不生效。每次应用前会备份 PassWall2 配置，失败自动回滚。</li>
<li><b>日志：</b><code>/tmp/macsplit-apply.log</code>。</li>
</ul>
</div>
]=]
end

-- The normal "Save & Apply" path commits macsplit and then calls this hook.
m.on_after_commit = function(self)
	sys.call("/usr/libexec/macsplit-apply apply >/dev/null 2>&1")
end

return m
