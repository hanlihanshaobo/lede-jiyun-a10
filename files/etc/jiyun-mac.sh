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

# SSID: Dwrt-<last 6 hex digits of the LAN/base MAC>-2.4G / -5G.
# The base MAC is derived from the eMMC CID, so the suffix is unique per unit
# and stable across reboots and reflashes; both bands share it, only the band
# suffix differs.
suffix="$(printf '%s' "$base" | tr -d ':' | tr 'a-f' 'A-F' | tail -c 6)"
[ -n "$suffix" ] || exit 0
ssid24="Dwrt-${suffix}-2.4G"
ssid5="Dwrt-${suffix}-5G"

changed=0
[ "$(uci -q get wireless.default_radio0.macaddr)" = "$w24" ] || {
	uci set wireless.default_radio0.macaddr="$w24"; changed=1; }
[ "$(uci -q get wireless.default_radio1.macaddr)" = "$w5" ] || {
	uci set wireless.default_radio1.macaddr="$w5"; changed=1; }
[ "$(uci -q get wireless.default_radio0.ssid)" = "$ssid24" ] || {
	uci set wireless.default_radio0.ssid="$ssid24"; changed=1; }
[ "$(uci -q get wireless.default_radio1.ssid)" = "$ssid5" ] || {
	uci set wireless.default_radio1.ssid="$ssid5"; changed=1; }
[ "$changed" = 1 ] || exit 0

uci commit wireless
logger -t jiyun-mac "WLAN MACs/SSIDs set: $w24/$ssid24, $w5/$ssid5"
# hostapd cannot change its BSSID on SIGHUP - a full restart is required
wifi down
sleep 2
wifi up
