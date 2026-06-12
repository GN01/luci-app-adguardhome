#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE_LUA="$ROOT_DIR/luasrc/model/cbi/AdGuardHome/base.lua"
MANUAL_LUA="$ROOT_DIR/luasrc/model/cbi/AdGuardHome/manual.lua"
DEFAULT_CONFIG="$ROOT_DIR/root/etc/config/AdGuardHome"
MAKEFILE="$ROOT_DIR/Makefile"
ZH_CN="$ROOT_DIR/po/zh-cn/AdGuardHome.po"
ZH_HANS="$ROOT_DIR/po/zh_Hans/AdGuardHome.po"

grep -q "PKG_VERSION:=1.0.2" "$MAKEFILE" || {
	echo "PKG_VERSION should be 1.0.2"
	exit 1
}

grep -q "LUCI_VERSION:=1.0.2" "$MAKEFILE" || {
	echo "LUCI_VERSION should be 1.0.2"
	exit 1
}

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

if grep -q 'uci:set("AdGuardHome", section, "whitelist_ipset_domains", value:gsub' "$BASE_LUA"; then
	echo "TextValue gsub result should be assigned before uci:set"
	exit 1
fi

grep -q 'fs.readfile("/etc/ssrplus/white.list")' "$BASE_LUA" || {
	echo "LuCI whitelist domains should default to /etc/ssrplus/white.list when no plugin value is saved"
	exit 1
}

grep -q 'upstream_dns_custom_rules' "$BASE_LUA" || {
	echo "LuCI should expose custom domain upstream DNS rules"
	exit 1
}

grep -q '#\[/.lan/\]127.0.0.1:1745' "$BASE_LUA" || {
	echo "LuCI custom upstream rules should include the .lan dnsmasq example"
	exit 1
}

if rg -n "ucitracktest|AdGlucitest" "$BASE_LUA" "$MANUAL_LUA"; then
	echo "LuCI pages should not use hidden ucitracktest state"
	exit 1
fi

for po in "$ZH_CN" "$ZH_HANS"; do
	grep -q 'msgid "Base Setting"' "$po" || {
		echo "$po should translate Base Setting"
		exit 1
	}
	grep -q 'msgstr "基础设置"' "$po" || {
		echo "$po should translate Base Setting to Chinese"
		exit 1
	}
	grep -q 'msgid "Open Web Interface"' "$po" || {
		echo "$po should translate Open Web Interface"
		exit 1
	}
	grep -q 'msgstr "打开 Web 管理界面"' "$po" || {
		echo "$po should translate Open Web Interface to Chinese"
		exit 1
	}
done

echo "LuCI compatibility test passed"
