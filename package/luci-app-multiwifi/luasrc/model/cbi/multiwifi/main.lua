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

-- Upgrade/migration for existing installs whose /etc/config/multiwifi was
-- preserved across sysupgrade and therefore lacks the new sections.
local function ensure_ui_sections()
	if not fs.access("/etc/config/multiwifi") then
		return
	end
	local changed = false
	local function ensure(name, stype, defaults)
		if not uci:get("multiwifi", name) then
			uci:set("multiwifi", name, stype)
			for k, v in pairs(defaults or {}) do
				uci:set("multiwifi", name, k, v)
			end
			changed = true
		end
	end
	ensure("global", "global", { enabled = "1", subnet_base = "192.168.80.0/24" })
	ensure("template", "template", {
		ssid_prefix = "WiFi", ssid_start = "1",
		count_24 = "1", count_5g = "1",
		encryption = "psk2", isolate = "1",
		node = "__direct__", replace_rows = "1",
	})
	ensure("preset_ui", "preset_ui", {})
	ensure("import_ui", "import_ui", {})
	if changed then
		uci:commit("multiwifi")
	end
end
ensure_ui_sections()

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

-- Count associated stations for one row. `ubus call network.wireless
-- status` exposes each BSS with its section name and stations[] array.
local function clients_for(net)
	local raw = sys.exec("ubus call network.wireless status 2>/dev/null")
	local st = jsonc.parse(raw or "")
	local n = 0
	if st then
		for _, radio in pairs(st) do
			for _, iface in ipairs(radio.interfaces or {}) do
				local sec = iface.section or ""
				if sec == net .. "_24" or sec == net .. "_5" then
					n = n + #(iface.stations or {})
				end
			end
		end
	end
	return n
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
			nodes[#nodes + 1] = { name = n[".name"], label = label }
		end)
		table.sort(nodes, function(a, b) return a.label < b.label end)
		for _, n in ipairs(nodes) do
			o:value(n.name, n.label)
		end
	else
		o:value("__global__", translate("跟随 PassWall2 全局节点"))
	end
end

-- Fields that make up a template snapshot (shared by presets).
local TEMPLATE_FIELDS = {
	"ssid_prefix", "ssid_start", "count_24", "count_5g",
	"key", "encryption", "isolate", "node", "node_pool", "replace_rows",
}

-- Copy template values from one UCI section to another.
-- The ucode uci cursor in Lean 25.12 has no add_list(), so list options are
-- written with set_list().
local function copy_template(src, dst)
	for _, f in ipairs(TEMPLATE_FIELDS) do
		local v = m.uci:get("multiwifi", src, f)
		m.uci:delete("multiwifi", dst, f)
		if v ~= nil then
			if type(v) == "table" then
				if #v > 0 then
					m.uci:set_list("multiwifi", dst, f, v)
				end
			else
				m.uci:set("multiwifi", dst, f, v)
			end
		end
	end
end

m = Map("multiwifi", translate("多 SSID 分流"),
	translate("每个 SSID 使用独立子网，并通过 PassWall2 的访问控制指定线路。"))
m.redirect = dispatcher.build_url("admin", "network", "multiwifi")
-- This firmware ships luci-mod-admin-full without the generic
-- /admin/uci/apply endpoint, so the JS-side "apply" XHR would 404 and the
-- multiwifi staging file would never be committed.  Commit here instead:
-- apply_on_parse=false makes CBI commit the config and run on_after_commit
-- synchronously for "Save & Apply".
m.apply_on_parse = false

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

-- ---------------------------------------------------------------------------
-- Batch template
-- ---------------------------------------------------------------------------
s = m:section(NamedSection, "template", "template", translate("批量 WiFi 模板"))
s.addremove = false
s.description = translate("这里填一次，点“按模板生成 SSID”批量建行。生成后每行仍可单独改 SSID、频段和线路；密码、加密、隔离统一使用模板值。")

o = s:option(Value, "ssid_prefix", translate("SSID 前缀"))
o.default = "WiFi"
o.rmempty = false
o.description = translate("生成名称：前缀-序号，例如 WiFi-1、WiFi-2。")
o.validate = function(self, value)
	value = tostring(value or "")
	if value == "" then
		return nil, translate("前缀不能为空")
	end
	if #value > 24 then
		return nil, translate("前缀最长 24 字节")
	end
	return value
end

o = s:option(Value, "ssid_start", translate("起始序号"))
o.default = 1
o.datatype = "range(1,99)"
o.rmempty = false

o = s:option(Value, "count_24", translate("2.4G 数量"))
o.default = 1
o.datatype = "range(0,16)"
o.rmempty = false
o.description = translate("0 表示不生成 2.4G；建议不超过 4 个。")

o = s:option(Value, "count_5g", translate("5G 数量"))
o.default = 1
o.datatype = "range(0,16)"
o.rmempty = false
o.description = translate("0 表示不生成 5G；建议不超过 8 个。")

o = s:option(Value, "key", translate("全局密码"))
o.password = true
o.rmempty = true
o.description = translate("WPA2/WPA3 为 8-63 位；所有生成的 SSID 共用。开放网络可留空。")
o.validate = function(self, value)
	value = tostring(value or "")
	if value ~= "" and (#value < 8 or #value > 63) then
		return nil, translate("密码长度需为 8-63 位")
	end
	return value
end

o = s:option(ListValue, "encryption", translate("全局加密"))
o:value("psk2", "WPA2-PSK")
o:value("sae-mixed", "WPA2/WPA3 混合")
o:value("none", translate("开放网络"))
o.default = "psk2"
o.rmempty = false

o = s:option(Flag, "isolate", translate("客户端隔离"))
o.default = 1
o.rmempty = false
o.description = translate("所有生成的 SSID 共用；同一 SSID 内客户端不能互访。")

o = s:option(ListValue, "node", translate("模板默认线路"))
o.default = "__direct__"
o.rmempty = false
add_node_options(o)
o.description = translate("生成时每行先写入这条线路，之后可在表格里逐行改。")

o = s:option(DynamicList, "node_pool", translate("线路池（可选）"))
o.rmempty = true
o.description = translate("在这里加入多条线路，生成时按顺序循环分配；线路池为空时使用上面的默认线路。")
add_node_options(o, translate("直连"))

o = s:option(Flag, "replace_rows", translate("覆盖已有 SSID 行"))
o.default = 1
o.rmempty = false
o.description = translate("生成前删除现有 SSID 行；取消勾选则追加。")

-- ---------------------------------------------------------------------------
-- Presets: snapshots of the template above (家用/访客/…)
-- ---------------------------------------------------------------------------
s = m:section(NamedSection, "preset_ui", "preset_ui", translate("模板预设"))
s.addremove = false
s.description = translate("把上面的模板另存为预设，或把某个预设载入模板。预设只保存模板字段，不会生成 SSID。")

local preset_names = {}
uci:foreach("multiwifi", "preset", function(p)
	preset_names[#preset_names + 1] = { id = p[".name"], name = p.name or p[".name"] }
end)

o = s:option(ListValue, "select", translate("预设"))
for _, p in ipairs(preset_names) do
	o:value(p.id, p.name)
end
if #preset_names == 0 then
	o:value("__none__", translate("（暂无预设）"))
end

o = s:option(Value, "name", translate("新预设名称"))
o.rmempty = true
o.datatype = "maxlength(16)"

o = s:option(Button, "_preset_load", " ")
o.inputtitle = translate("载入模板")
o.inputstyle = "apply"
o.write = function()
	local id = m.uci:get("multiwifi", "preset_ui", "select") or ""
	if id ~= "" and id ~= "__none__" then
		copy_template(id, "template")
		m.uci:commit("multiwifi")
	end
	http.redirect(m.redirect)
end

o = s:option(Button, "_preset_save", " ")
o.inputtitle = translate("另存为预设")
o.inputstyle = "apply"
o.write = function()
	local name = tostring(m.uci:get("multiwifi", "preset_ui", "name") or "")
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then
		return
	end
	local sid = m.uci:add("multiwifi", "preset")
	if sid then
		m.uci:set("multiwifi", sid, "name", name)
		copy_template("template", sid)
		m.uci:set("multiwifi", "preset_ui", "select", sid)
		m.uci:commit("multiwifi")
	end
	http.redirect(m.redirect)
end

o = s:option(Button, "_preset_del", " ")
o.inputtitle = translate("删除预设")
o.inputstyle = "remove"
o.write = function()
	local id = m.uci:get("multiwifi", "preset_ui", "select") or ""
	if id ~= "" and id ~= "__none__" then
		m.uci:delete("multiwifi", id)
		m.uci:delete("multiwifi", "preset_ui", "select")
		m.uci:commit("multiwifi")
	end
	http.redirect(m.redirect)
end

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
-- SSID table
-- ---------------------------------------------------------------------------
s = m:section(TypedSection, "ssid", translate("SSID 与线路"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"
s.description = translate("此处只保留 SSID/频段/线路/启用；密码、加密、隔离统一由上面的批量模板决定。频段选“双频”时，2.4G/5G 共用同一个子网和线路。")

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

o = s:option(ListValue, "node", translate("PassWall2 线路"))
o.default = "__direct__"
o.rmempty = false
add_node_options(o)

o = s:option(Button, "_test", " ")
o.inputtitle = translate("测试")
o.inputstyle = "action"
o.forcewrite = true
o.write = function(self, section)
	local net = net_for(section)
	-- result is picked up by the _testres DummyValue below
	local rc = sys.call("/usr/libexec/multiwifi-apply test %s >/dev/null 2>&1" %
		{ util.shellquote(net) })
	local result = (rc == 0) and "ok" or "fail"
	local f = io.open("/tmp/multiwifi-test-" .. section, "w")
	if f then
		f:write(result .. " " .. os.time())
		f:close()
	end
end

o = s:option(DummyValue, "_testres", translate("线路测试"))
o.rawhtml = true
o.cfgvalue = function(self, section)
	local f = io.open("/tmp/multiwifi-test-" .. section, "r")
	if not f then
		return "<span class='mw-test'>" .. translate("未测试") .. "</span>"
	end
	local content = f:read("*l") or ""
	f:close()
	local result, ts = content:match("^(%S+)%s+(%S+)$")
	if not result then
		return "<span class='mw-test'>" .. translate("未测试") .. "</span>"
	end
	local age = os.time() - tonumber(ts)
	local when = ""
	if age < 60 then
		when = string.format(translate("%d 秒前"), age)
	elseif age < 3600 then
		when = string.format(translate("%d 分钟前"), math.floor(age / 60))
	else
		when = string.format(translate("%d 小时前"), math.floor(age / 3600))
	end
	if result == "ok" then
		return "<span class='mw-ok'>" .. translate("通") .. "</span> <span class='mw-test'>" .. when .. "</span>"
	end
	return "<span class='mw-fail'>" .. translate("不通") .. "</span> <span class='mw-test'>" .. when .. "</span>"
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
	local html
	if up then
		local clients = clients_for(net)
		html = "<span class='mw-up'>UP</span> <span class='mw-clients'>" ..
			string.format(translate("%d 台"), clients) .. "</span>"
	else
		html = "<span class='mw-down'>DOWN</span>"
	end
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
s.description = translate("“保存并应用”会提交本页配置并立即生效；“保存”只写配置，不重启无线。下面的按钮用于按模板生成、批量启停或重试。")

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

o = s:option(Button, "_generate", " ")
o.inputtitle = translate("按模板生成 SSID")
o.inputstyle = "apply"
o.write = function()
	local function tv(k)
		return m.uci:get("multiwifi", "template", k)
	end

	local prefix = tostring(tv("ssid_prefix") or "WiFi"):gsub("%s+$", "")
	if prefix == "" then prefix = "WiFi" end
	local start = tonumber(tv("ssid_start")) or 1
	local n24 = tonumber(tv("count_24")) or 0
	local n5 = tonumber(tv("count_5g")) or 0
	local key = tostring(tv("key") or "")
	local enc = tostring(tv("encryption") or "psk2")
	local isolate = tostring(tv("isolate") or "1")
	local node = tostring(tv("node") or "__direct__")
	-- Flag default 1 is removed from UCI by CBI, so only an explicit "0"
	-- means "append"; nil/empty means the default checked state.
	local replace = tv("replace_rows") ~= "0"

	start = math.floor(start)
	if start < 1 then start = 1 end
	n24 = math.floor(n24)
	n5 = math.floor(n5)
	if n24 < 0 then n24 = 0 end
	if n5 < 0 then n5 = 0 end
	if n24 > 16 then n24 = 16 end
	if n5 > 16 then n5 = 16 end
	if n24 + n5 > 32 then n5 = 32 - n24 end

	local pool = tv("node_pool")
	if type(pool) ~= "table" then
		pool = pool and { pool } or {}
	end
	local pool_n = #pool

	if replace then
		local old = {}
		m.uci:foreach("multiwifi", "ssid", function(x)
			old[#old + 1] = x[".name"]
		end)
		for _, sid in ipairs(old) do
			m.uci:delete("multiwifi", sid)
		end
	end

	local seq = start
	local idx = 1
	local function add_row(band)
		local sid = m.uci:add("multiwifi", "ssid")
		if not sid then return end
		local use_node = node
		if pool_n > 0 then
			use_node = pool[(idx - 1) % pool_n + 1]
			if not use_node or use_node == "" then use_node = node end
		end
		m.uci:set("multiwifi", sid, "enabled", "1")
		m.uci:set("multiwifi", sid, "ssid", prefix .. "-" .. seq)
		m.uci:set("multiwifi", sid, "band", band)
		m.uci:set("multiwifi", sid, "encryption", enc)
		m.uci:set("multiwifi", sid, "node", use_node)
		m.uci:set("multiwifi", sid, "isolate", isolate)
		if enc ~= "none" and key ~= "" then
			m.uci:set("multiwifi", sid, "key", key)
		else
			m.uci:delete("multiwifi", sid, "key")
		end
		seq = seq + 1
		idx = idx + 1
	end

	local i
	for i = 1, n24 do add_row("2g") end
	for i = 1, n5 do add_row("5g") end
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

-- ---------------------------------------------------------------------------
-- Export / import the multiwifi config (template + presets + SSID rows) as a
-- single base64 blob; handy for cloning several A10 units.
-- ---------------------------------------------------------------------------
s = m:section(NamedSection, "import_ui", "import_ui", translate("导出 / 导入"))
s.addremove = false
s.description = translate("导出内容包含模板、预设和 SSID 行（含密码），生成的是设备间通用的配置文本。")

o = s:option(DummyValue, "_export", translate("配置内容"))
o.rawhtml = true
o.cfgvalue = function()
	local raw = sys.exec("uci -q export multiwifi 2>/dev/null") or ""
	if raw == "" then
		return ""
	end
	-- drop the import_ui block: otherwise the previous import text would be
	-- embedded in every new export and grow recursively
	local out, skip = {}, false
	for line in raw:gmatch("[^\n]+") do
		if line:match("^config%s") then
			skip = line:match("^config%s+import_ui") ~= nil
		end
		if not skip then
			out[#out + 1] = line
		end
	end
	raw = table.concat(out, "\n")
	local b64 = sys.exec("printf '%s' " .. util.shellquote(raw) ..
		" | base64 2>/dev/null | tr -d '\\n'") or ""
	b64 = tostring(b64):gsub("%s+", "")
	return "<textarea readonly rows='4' style='width:100%%;font-size:85%%' onclick='this.select()'>" ..
		util.pcdata(b64) .. "</textarea>"
end

o = s:option(TextValue, "text", translate("导入配置"))
o.rows = 4
o.wrap = "off"
o.rmempty = true
o.description = translate("粘贴导出的配置文本，点“导入”。会覆盖本页的模板/预设/SSID 行，但不会自动应用。")

o = s:option(Button, "_do_import", " ")
o.inputtitle = translate("导入")
o.inputstyle = "apply"
o.write = function()
	local blob = tostring(m.uci:get("multiwifi", "import_ui", "text") or "")
	blob = blob:gsub("%s+", "")
	if blob == "" then
		return
	end
	local f = sys.exec("printf '%s' " .. util.shellquote(blob) ..
		" | base64 -d 2>/dev/null") or ""
	f = tostring(f):gsub("^%s+", ""):gsub("%s+$", "")
	if not f:match("^package%s+multiwifi") and not f:match("^config%s") then
		return
	end
	fs.writefile("/tmp/multiwifi-import", f .. "\n")
	sys.call("uci -q import multiwifi < /tmp/multiwifi-import 2>/dev/null")
	fs.unlink("/tmp/multiwifi-import")
	-- The export deliberately omits import_ui (to avoid recursive base64).
	-- Recreate the UI-only sections so the page still renders them.
	sys.call("uci -q get multiwifi.import_ui >/dev/null 2>&1 || uci -q set multiwifi.import_ui=import_ui")
	sys.call("uci -q get multiwifi.preset_ui >/dev/null 2>&1 || uci -q set multiwifi.preset_ui=preset_ui")
	sys.call("uci -q commit multiwifi 2>/dev/null")
	http.redirect(m.redirect)
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
.mw-clients { color: var(--active_color, #5ea69b); }
.mw-ok { color: #27ae60; }
.mw-fail { color: #e74c3c; font-weight: bold; }
.mw-test { font-size: 90%; }
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
<li><b>批量模板：</b>前缀+起始序号+2.4G/5G 数量，密码/加密/隔离/默认线路一次设置；线路池可让生成的 SSID 按顺序轮换线路；默认覆盖已有行，可取消。</li>
<li><b>预设：</b>把当前模板“另存为预设”（家用/访客/…），以后一键载入，不用重新填。</li>
<li><b>线路测试：</b>先“保存并应用”，再点每行“测试”；它会在该 SSID 的子网里模拟客户端，走该行 ACL 测 DNS+HTTP，结果在“线路测试”列。</li>
<li><b>每行只改：</b>SSID、频段、线路、启用；密码/加密/隔离不再逐行重复填。</li>
<li><b>子网：</b>统一从“自动子网起始”顺序分配 /24；不能和 LAN/WAN 或已有 SSID 冲突。</li>
<li><b>原有 SSID：</b><code>default_radio0/1</code>（Dwrt-…）不由本页管理，保留原样。</li>
<li><b>IPv6：</b>新 SSID 默认关闭 DHCPv6/RA，避免 PassWall2 IPv6 规则不完整导致泄漏；需要 IPv6 请单独配置。</li>
<li><b>生成段：</b>network/dhcp/firewall/wireless/passwall2 里所有 <code>mws_*</code> 段由本页管理，不要手工改；取消“启用”或全局停用会移除这些段，但保留本页 SSID 配置。</li>
<li><b>BSS 没起来：</b>SSH 执行 <code>wifi down; wifi up</code>（会断开所有 WiFi 几秒）。</li>
<li><b>日志：</b>详细应用日志在页面顶部“运行状态”里展开，或看 <code>/tmp/multiwifi-apply.log</code>。</li>
</ul>
</div>
]=]
end

-- The normal "Save & Apply" path commits multiwifi and then calls this hook.
m.on_after_commit = function(self)
	sys.call("/usr/libexec/multiwifi-apply apply >/dev/null 2>&1")
end

return m
