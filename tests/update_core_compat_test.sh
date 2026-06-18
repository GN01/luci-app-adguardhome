#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/share/AdGuardHome/update_core.sh"

grep -q 'command -v apk' "$SCRIPT" || {
	echo "update_core should support apk-based systems"
	exit 1
}

if grep -q 'Archt="$(opkg info kernel' "$SCRIPT"; then
	echo "GET_Arch should not rely only on opkg"
	exit 1
fi

grep -q '"x86_64"|"amd64"|"x86")' "$SCRIPT" || {
	echo "GET_Arch should map apk x86_64 to AdGuardHome amd64"
	exit 1
}

grep -q 'rm -rf /var/run/update_core_error' "$SCRIPT" || {
	echo "update_core should remove update_core_error with rm -rf"
	exit 1
}

echo "update_core compatibility test passed"
