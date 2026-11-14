module("luci.controller.macsplit", package.seeall)

function action_reapply()
	luci.sys.call("/usr/libexec/macsplit-apply apply force >/dev/null 2>&1")
	luci.http.redirect(luci.dispatcher.build_url("admin", "network", "macsplit"))
end

function index()
	entry({"admin", "network", "macsplit"},
		cbi("macsplit/main"),
		_("多设备分流"), 61)
	entry({"admin", "network", "macsplit", "reapply"},
		call("action_reapply")).leaf = true
end
