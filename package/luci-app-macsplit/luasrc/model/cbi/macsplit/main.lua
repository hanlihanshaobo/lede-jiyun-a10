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
	translate("给每个 MAC 单独指定一条 PassWall2 线路。有线、无线客户端都生效，不用改 WiFi 或子网。"))
m.redirect = dispatcher.build_url("admin", "network", "macsplit")
-- This firmware has no generic /admin/uci/apply endpoint, so let CBI commit
-- and run on_after_commit synchronously on "Save & Apply".
m.apply_on_parse = false

-- ---------------------------------------------------------------------------
-- Rules: one MAC -> one line
-- ---------------------------------------------------------------------------
s = m:section(TypedSection, "rule", translate("MAC 规则"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"
s.description = translate("点“添加”手动填 MAC，或从下面“在线设备”里一键添加。同一线路的多个 MAC 会自动合并成一条 ACL。")

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

o = s:option(ListValue, "node", translate("代理线路"))
o.default = "__direct__"
o.rmempty = false
add_node_options(o)

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
	local html
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

s = m:section(SimpleSection, translate("在线设备"))
s.description = translate("从当前在线设备里选一台，点“添加”就会新建一条规则（默认直连，再改代理线路）。")

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
	o:value("__none__", translate("（暂无在线设备，可直接点上面的“添加”手填 MAC）"))
end
for _, d in ipairs(devices) do
	local label = d.mac
	if d.ip then label = label .. "  " .. d.ip end
	if d.host then label = label .. "  " .. d.host end
	o:value(table.concat({ d.mac, d.ip or "", d.host or "" }, "|"), label)
end

o = s:option(Button, "_add", " ")
o.inputtitle = translate("添加")
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

-- ---------------------------------------------------------------------------
-- Notes
-- ---------------------------------------------------------------------------
s = m:section(SimpleSection, translate("使用说明"))
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
.ms-ip { color: var(--active_color, #5ea69b); }
.ms-host { opacity: .7; }
.cbi-tblsection .cbi-button { margin: 2px 6px 2px 0; }
.cbi-tblsection { overflow-x: auto; }
#cbi-table-table tr.cbi-section-table-titles { display: none; }
#cbi-table-table td.cbi-value-field { padding: 2px 6px; }
</style>
<div class="ms-app" style="line-height:1.75">
<p><b>怎么用：</b>“添加”一行 → 填 MAC → 选“代理线路” → “保存并应用”。就这么简单。</p>
<pre class="ms-pre">电视    aa:bb:cc:00:00:01 ── 香港节点
手机    aa:bb:cc:00:00:02 ── 日本节点
其它设备（未匹配）        ── 直连</pre>
<ul style="margin:0 0 0 1.2em;list-style:disc">
<li><b>只需要 PassWall2：</b>先在 PassWall2 里配好节点并保持运行；本页只负责把 MAC 绑到线路上。</li>
<li><b>不碰 WiFi/子网：</b>不改无线、不改网段，有线无线都按 MAC 命中；换 IP、DHCP 续租都不影响。</li>
<li><b>合并：</b>同一线路的多个 MAC 只生成一条 ACL，只启动一个代理实例。</li>
<li><b>未匹配直连：</b>PassWall2 全局关闭时，其它设备自动直连，不会被带到全局节点。</li>
<li><b>生效：</b>“保存并应用”才会写入 ACL 并重启 PassWall2；“保存”只写配置。</li>
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
