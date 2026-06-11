#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE_LUA="$ROOT_DIR/luasrc/model/cbi/AdGuardHome/base.lua"
DEFAULT_CONFIG="$ROOT_DIR/root/etc/config/AdGuardHome"

grep -q "option upxflag 'off'" "$DEFAULT_CONFIG" || {
	echo "upxflag should default to off"
	exit 1
}

grep -q 'o.default = "off"' "$BASE_LUA" || {
	echo "LuCI upxflag default should be off"
	exit 1
}

grep -q 'o:value("off", translate("none"))' "$BASE_LUA" || {
	echo "LuCI upxflag none option should use off"
	exit 1
}

if grep -q 'o:value("https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/[^"]*")' "$BASE_LUA"; then
	echo "DynamicList default URLs should use value and label for old LuCI compatibility"
	exit 1
fi

echo "LuCI compatibility test passed"
