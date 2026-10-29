#!/bin/sh
# Applied from /etc/rc.local, i.e. after S18fanctrl's first-boot "wifi config"
# has (re)generated /etc/config/wireless - doing it in /etc/uci-defaults would
# be overwritten.  Idempotent: only reloads the radios when a value changes.

. /lib/functions/system.sh
. /etc/jiyun-factory-mac.sh

base="$(uci -q get network.dev_eth0.macaddr)"
[ -n "$base" ] || exit 0

# Prefer the factory WLAN MACs from Config_new (mac_defwl / mac_defwl_5g);
# derive from the base when the partition is gone (LAN-5 / LAN+3 on the two
# units we checked).
w24="$(jiyun_wayos_get mac_defwl)"
[ -n "$w24" ] || w24="$(macaddr_add "$base" -5)"
w5="$(jiyun_wayos_get mac_defwl_5g)"
[ -n "$w5" ] || w5="$(macaddr_add "$base" 3)"
[ -n "$w24" ] && [ -n "$w5" ] || exit 0

# SSID: Dwrt-<last 6 hex digits of each radio's BSSID>-2.4G / -5G.
# The two radios have different MACs (factory mac_defwl/mac_defwl_5g, or the
# CID-derived fallbacks), so each SSID gets its own suffix matching the BSSID
# that hostapd actually advertises.
suffix24="$(printf '%s' "$w24" | tr -d ':' | tr 'a-f' 'A-F' | tail -c 6)"
suffix5="$(printf '%s' "$w5" | tr -d ':' | tr 'a-f' 'A-F' | tail -c 6)"
[ -n "$suffix24" ] && [ -n "$suffix5" ] || exit 0
ssid24="Dwrt-${suffix24}-2.4G"
ssid5="Dwrt-${suffix5}-5G"

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
