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

-- Last apply result, written by /usr/libexec/macsplit-apply:
--   "ok|fail <epoch> <message>"
local function last_result()
	local f = io.open("/tmp/macsplit/last-result", "r")
	if not f then
		return nil
	end
	local line = f:read("*l") or ""
	f:close()
	local st, ts, msg = line:match("^(%S+)%s+(%S+)%s*(.*)$")
	if not st or not ts then
		return nil
	end
	return st, tonumber(ts), msg
end

local function passwall_running()
	if not fs.access("/etc/config/passwall2") then
		return false, false
	end
	-- A PassWall2 with only "direct" ACLs has no xray process but is still
	-- running (app.sh + chinadns + dnsmasq + the "inet passwall2" nft table).
	local running = sys.call(
		"pidof xray >/dev/null 2>&1 || pidof sing-box >/dev/null 2>&1 || " ..
		"nft list tables 2>/dev/null | grep -q 'table inet passwall2'") == 0
	return true, running
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

m = Map("macsplit", translate("多设备分流"),
	translate("给每个设备（MAC）单独指定一条 PassWall2 线路。有线、无线客户端都生效，不用改 WiFi 或子网。"))
m.redirect = dispatcher.build_url("admin", "network", "macsplit")
-- This firmware has no generic /admin/uci/apply endpoint, so let CBI commit
-- and run on_after_commit synchronously on "Save & Apply".
m.apply_on_parse = false

-- ---------------------------------------------------------------------------
-- Status line: PassWall2 / interface / last apply result
-- ---------------------------------------------------------------------------
s = m:section(SimpleSection, translate("运行状态"))
o = s:option(DummyValue, "_status")
o.rawhtml = true
o.cfgvalue = function()
	local out = { "<div class='ms-status'>" }
	local function line(html)
		out[#out + 1] = "<div>" .. html .. "</div>"
	end

	local has_pw, running = passwall_running()
	if not has_pw then
		line("<span class='ms-err'>PassWall2：未安装</span>")
	elseif running then
		line("<span class='ms-up'>PassWall2：运行中</span> · 生效接口 <code>" ..
			util.pcdata(lan_device()) .. "</code>")
	else
		line("<span class='ms-err'>PassWall2：未运行</span> · 规则不会生效，请先在 PassWall2 里启动")
	end

	local st, ts, msg = last_result()
	if st then
		local when = os.date("%H:%M", ts)
		if st == "ok" then
			line("<span class='ms-up'>上次应用：成功</span> " .. when ..
				" <span class='ms-test'>" .. util.pcdata(msg or "") .. "</span>")
		else
			line("<span class='ms-err'>上次应用：失败</span> " .. when ..
				" <span class='ms-test'>" .. util.pcdata(msg or "") .. "</span>")
		end
	else
		line("<span class='ms-down'>上次应用：无记录（设备重启后显示未知，但配置仍已保存）</span>")
	end

	out[#out + 1] = "<div class='ms-actions'>" ..
		"<a class='btn cbi-button cbi-button-apply' href='" ..
		dispatcher.build_url("admin", "network", "macsplit", "reapply") ..
		"'>" .. translate("重新应用") .. "</a> " ..
		"<a class='btn cbi-button cbi-button-link' href='" ..
		dispatcher.build_url("admin", "services", "passwall2") ..
		"'>" .. translate("PassWall2 设置") .. "</a></div>"
	out[#out + 1] = "</div>"
	return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Rules: one MAC -> one line
-- ---------------------------------------------------------------------------
local rule_count = 0
uci:foreach("macsplit", "rule", function()
	rule_count = rule_count + 1
end)

s = m:section(TypedSection, "rule",
	translate("MAC 规则") .. (rule_count > 0 and string.format("（%d）", rule_count) or ""))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"
if rule_count == 0 then
	s.description = translate("还没有规则：在下面选一台在线设备点“添加选中设备”，或点表格下方的“添加”手动填 MAC。")
else
	s.description = translate("一条规则 = 一个 MAC + 一条线路；同一线路的多个 MAC 会自动合并成一条 ACL。")
end

o = s:option(Flag, "enabled", translate("启用"))
o.default = 1
o.rmempty = false

o = s:option(Value, "mac", translate("MAC 地址"))
o.rmempty = false
o.placeholder = "aa:bb:cc:dd:ee:ff"
o.validate = function(self, value, section)
	local mac = norm_mac(value)
	if not mac then
		return nil, translate("MAC 格式应为 aa:bb:cc:dd:ee:ff")
	end
	local dup = false
	uci:foreach("macsplit", "rule", function(r)
		if r[".name"] ~= section and norm_mac(r.mac) == mac then
			dup = true
		end
	end)
	if dup then
		return nil, translate("这个 MAC 已经有一条规则了")
	end
	return mac
end

o = s:option(Value, "name", translate("备注"))
o.rmempty = true
o.datatype = "maxlength(24)"
o.placeholder = translate("可留空")

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
		html = html .. "<br/><span class='ms-host'>" .. util.pcdata(e.host) .. "</span>"
	end
	return html
end

-- ---------------------------------------------------------------------------
-- Online devices quick add
-- ---------------------------------------------------------------------------
local existing = {}
uci:foreach("macsplit", "rule", function(r)
	local mm = norm_mac(r.mac)
	if mm then
		existing[mm] = true
	end
end)

local devices = {}
for mac, e in pairs(leases()) do
	if not existing[mac] then
		devices[#devices + 1] = { mac = mac, ip = e.ip, host = e.host }
	end
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
s.description = translate("列表是当前快照；新上线的设备刷新页面后才会出现，离线的设备请直接点表格下方的“添加”。")

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
	o:value("__none__", translate("（没有可添加的在线设备）"))
end
for _, d in ipairs(devices) do
	local label = d.mac
	if d.ip then label = label .. "  " .. d.ip end
	if d.host then label = label .. "  " .. d.host end
	o:value(table.concat({ d.mac, d.ip or "", d.host or "" }, "|"), label)
end

o = s:option(Button, "_add", " ")
o.inputtitle = translate("添加选中设备")
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
				-- the name field is maxlength(24); truncate so a long
				-- hostname cannot block the next save
				uci:set("macsplit", sid, "name", host:sub(1, 24))
			end
			uci:commit("macsplit")
		end
	end
	http.redirect(m.redirect)
end

o = s:option(Button, "_refresh", " ")
o.inputtitle = translate("刷新列表")
o.inputstyle = "action"
o.write = function()
	http.redirect(m.redirect)
end

-- ---------------------------------------------------------------------------
-- Notes
-- ---------------------------------------------------------------------------
s = m:section(SimpleSection)
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
.ms-err { color: #e74c3c; font-weight: bold; }
.ms-ip { color: var(--active_color, #5ea69b); }
.ms-host { opacity: .7; font-size: 90%; display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ms-test { font-size: 90%; opacity: .8; }
.ms-status { line-height: 1.7; }
.ms-status > div { margin: 2px 0; }
.ms-actions { margin-top: 6px; }
.cbi-tblsection .cbi-button { margin: 2px 6px 2px 0; }
.cbi-tblsection { overflow-x: auto; }
/* button-only tables: no header row; the rules table keeps its header */
.cbi-tblsection:not(#cbi-macsplit-rule) tr.cbi-section-table-titles { display: none; }
.cbi-tblsection:not(#cbi-macsplit-rule) td.cbi-value-field { padding: 2px 6px; }
/* Rules table: the design theme turns it into display:block (scroll wrapper)
   and forces th widths to auto !important, which made the tiny "启用" column
   eat the space the MAC/line columns need. Restore a real fixed table and
   pin every column. */
#cbi-macsplit-rule table.cbi-section-table { display: table !important; table-layout: fixed !important; width: 100% !important; min-width: 720px; }
#cbi-macsplit-rule .cbi-section-table-row > td { padding-left: 4px; padding-right: 4px; }
#cbi-macsplit-rule .cbi-input-text, #cbi-macsplit-rule select { font-size: 90%; }
#cbi-macsplit-rule .cbi-section-table-titles .cbi-section-table-cell:nth-child(1),
#cbi-macsplit-rule .cbi-section-table-row > td:nth-child(1) { width: 50px !important; }
#cbi-macsplit-rule .cbi-section-table-titles .cbi-section-table-cell:nth-child(2),
#cbi-macsplit-rule .cbi-section-table-row > td:nth-child(2) { width: 168px !important; }
#cbi-macsplit-rule .cbi-section-table-titles .cbi-section-table-cell:nth-child(3),
#cbi-macsplit-rule .cbi-section-table-row > td:nth-child(3) { width: 130px !important; }
#cbi-macsplit-rule .cbi-section-table-titles .cbi-section-table-cell:nth-child(4),
#cbi-macsplit-rule .cbi-section-table-row > td:nth-child(4) { width: 185px !important; }
#cbi-macsplit-rule .cbi-section-table-titles .cbi-section-table-cell:nth-child(6),
#cbi-macsplit-rule .cbi-section-table-row > td:nth-child(6) { width: 78px !important; }
#cbi-macsplit-rule td:nth-child(6) .cbi-button { margin: 0; padding: 2px 6px; }
/* narrow screens: the optional remark column is the first thing to drop */
@media (max-width: 900px) {
	#cbi-macsplit-rule .cbi-section-table-titles .cbi-section-table-cell:nth-child(3),
	#cbi-macsplit-rule .cbi-section-table-row > td:nth-child(3) { display: none; }
}
#cbi-macsplit-rule .cbi-input-text, #cbi-macsplit-rule select { width: 100%; box-sizing: border-box; }
#cbi-macsplit-rule td:nth-child(2) input { font-family: ui-monospace, Menlo, Consolas, monospace; }
</style>
<div class="ms-app" style="line-height:1.75">
<details>
<summary><b>使用说明与注意事项</b></summary>
<p><b>怎么用：</b>“添加”一行 → 填 MAC → 选“代理线路” → “保存并应用”。就这么简单。</p>
<pre class="ms-pre">电视    aa:bb:cc:00:00:01 ── 香港节点
手机    aa:bb:cc:00:00:02 ── 日本节点
其它设备（未匹配）        ── 直连</pre>
<ul style="margin:0 0 0 1.2em;list-style:disc">
<li><b>只需要 PassWall2：</b>先在 PassWall2 里配好节点并保持运行；本页只负责把 MAC 绑到线路上。</li>
<li><b>不碰 WiFi/子网：</b>不改无线、不改网段，有线无线都按 MAC 命中；换 IP、DHCP 续租都不影响。</li>
<li><b>合并：</b>同一线路的多个 MAC 只生成一条 ACL，只启动一个代理实例。</li>
<li><b>未匹配直连：</b>PassWall2 全局关闭时，其它设备自动直连，不会被带到全局节点。</li>
<li><b>生效：</b>“保存并应用”才会写入 ACL 并重启 PassWall2（配置没变化时会跳过重启）；“保存”只写配置。</li>
<li><b>日志：</b><code>/tmp/macsplit-apply.log</code>。</li>
</ul>
</details>
</div>
]=]
end

-- The normal "Save & Apply" path commits macsplit and then calls this hook.
m.on_after_commit = function(self)
	sys.call("/usr/libexec/macsplit-apply apply >/dev/null 2>&1")
end

return m
