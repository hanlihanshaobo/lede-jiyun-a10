module("luci.controller.macsplit", package.seeall)

function index()
	entry({"admin", "network", "macsplit"},
		cbi("macsplit/main"),
		_("按 MAC 分流"), 61)
end
