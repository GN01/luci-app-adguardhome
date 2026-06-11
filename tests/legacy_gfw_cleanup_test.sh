#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ -e "$ROOT_DIR/root/usr/share/AdGuardHome/gfw2adg.sh" ]; then
	echo "legacy gfw2adg.sh should be removed"
	exit 1
fi

if [ -e "$ROOT_DIR/root/usr/share/AdGuardHome/gfwipset2adg.sh" ]; then
	echo "legacy gfwipset2adg.sh should be removed"
	exit 1
fi

for file in adguardhome.nft.tpl firewall.start links.txt; do
	if [ -e "$ROOT_DIR/root/usr/share/AdGuardHome/$file" ]; then
		echo "unused $file should be removed"
		exit 1
	fi
done

if rg -n "gfw2adg|gfwipset2adg|autogfw|autogfwipset|gfwlist|gfwupstream" \
	"$ROOT_DIR/Makefile" \
	"$ROOT_DIR/README.md" \
	"$ROOT_DIR/luasrc" \
	"$ROOT_DIR/root/etc" \
	"$ROOT_DIR/root/usr/share/rpcd" \
	"$ROOT_DIR/root/usr/share/AdGuardHome" >/dev/null; then
	echo "legacy gfw references should be removed"
	exit 1
fi

if rg -n "adguardhome\\.nft\\.tpl|firewall\\.start|links\\.txt" \
	"$ROOT_DIR/Makefile" \
	"$ROOT_DIR/README.md" \
	"$ROOT_DIR/luasrc" \
	"$ROOT_DIR/root/etc" \
	"$ROOT_DIR/root/usr/share/rpcd" \
	"$ROOT_DIR/root/usr/share/AdGuardHome" >/dev/null; then
	echo "unused resource references should be removed"
	exit 1
fi

echo "legacy cleanup test passed"
