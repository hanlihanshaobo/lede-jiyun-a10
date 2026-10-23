#!/bin/sh
# Applied from /etc/rc.local, i.e. after S18fanctrl's first-boot "wifi config"
# has (re)generated /etc/config/wireless - doing it in /etc/uci-defaults would
# be overwritten.  Idempotent: only reloads the radios when a value changes.

. /lib/functions/system.sh

base="$(uci -q get network.dev_eth0.macaddr)"
[ -n "$base" ] || exit 0

w24="$(macaddr_add "$base" -5)"
w5="$(macaddr_add "$base" 3)"
[ -n "$w24" ] && [ -n "$w5" ] || exit 0

changed=0
[ "$(uci -q get wireless.default_radio0.macaddr)" = "$w24" ] || {
	uci set wireless.default_radio0.macaddr="$w24"; changed=1; }
[ "$(uci -q get wireless.default_radio1.macaddr)" = "$w5" ] || {
	uci set wireless.default_radio1.macaddr="$w5"; changed=1; }
[ "$changed" = 1 ] || exit 0

uci commit wireless
logger -t jiyun-mac "WLAN MACs set: $w24 / $w5"
wifi reload
