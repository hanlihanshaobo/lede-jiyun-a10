module("luci.controller.multiwifi", package.seeall)

function index()
	entry({"admin", "network", "multiwifi"}, cbi("multiwifi/main"), _("多 SSID 分流"), 60)
end
