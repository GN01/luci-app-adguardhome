#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/share/AdGuardHome/whitelist_ipset2adg.sh"
TMP_DIR="${TMPDIR:-/tmp}/whitelist-ipset-test.$$"
CONFIG="$TMP_DIR/AdGuardHome.yaml"
CONFIG_DEFAULT="$TMP_DIR/AdGuardHome-default.yaml"
DEFAULT_DOMAINS="$TMP_DIR/ssr-white.list"
IPSET_LOG="$TMP_DIR/ipset.log"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

cat > "$CONFIG" <<'YAML'
dns:
  upstream_dns:
    - 223.5.5.5
  upstream_dns_file: "/opt/adguardhome/conf/adguard_upstream_dns_file.txt"
  ipset_file: /etc/AdGuardHome/whitelist_ipset.txt
  ipset: []
  filtering_enabled: true
YAML

WHITELIST_IPSET_DOMAINS="
# manual source
example.com
.wild.example
[/split.example/]https://223.5.5.5/dns-query
/kept.example/otherset
example.com
bad value
203.0.113.5
" \
WHITELIST_IPSET_CONFIG="$CONFIG" \
WHITELIST_IPSET_NO_RELOAD="1" \
WHITELIST_IPSET_TEST_IPSET_LOG="$IPSET_LOG" \
sh "$SCRIPT"

EXPECTED="$TMP_DIR/expected.txt"
cat > "$EXPECTED" <<'EOF_EXPECTED'
  ipset:
    - example.com/whitelist
    - kept.example/whitelist
    - split.example/whitelist
    - wild.example/whitelist
EOF_EXPECTED

sed -n '/^  ipset:/,/^  filtering_enabled:/p' "$CONFIG" | sed '$d' > "$TMP_DIR/ipset.yaml"
diff -u "$EXPECTED" "$TMP_DIR/ipset.yaml"

grep -q 'upstream_dns_file: "/opt/adguardhome/conf/adguard_upstream_dns_file.txt"' "$CONFIG"
if grep -q "ipset_file:" "$CONFIG"; then
	echo "ipset_file should be removed"
	exit 1
fi
if grep -q "destroy whitelist" "$IPSET_LOG"; then
	echo "existing whitelist ipset should not be destroyed"
	exit 1
fi
grep -q "create whitelist hash:net timeout 86400" "$IPSET_LOG"

WHITELIST_IPSET_CONFIG="$CONFIG" \
WHITELIST_IPSET_NO_RELOAD="1" \
sh "$SCRIPT" del

grep -q '  ipset: \[\]' "$CONFIG"
if grep -q "ipset_file:" "$CONFIG"; then
	echo "ipset_file should stay removed"
	exit 1
fi
grep -q 'upstream_dns_file: "/opt/adguardhome/conf/adguard_upstream_dns_file.txt"' "$CONFIG"

cat > "$CONFIG_DEFAULT" <<'YAML'
dns:
  upstream_dns:
    - 223.5.5.5
  ipset: []
  filtering_enabled: true
YAML

cat > "$DEFAULT_DOMAINS" <<'EOF_DEFAULT_DOMAINS'
ssrplus.example.com
.ssrplus-wild.example
EOF_DEFAULT_DOMAINS

WHITELIST_IPSET_CONFIG="$CONFIG_DEFAULT" \
WHITELIST_IPSET_DEFAULT_FILE="$DEFAULT_DOMAINS" \
WHITELIST_IPSET_NO_RELOAD="1" \
WHITELIST_IPSET_TEST_IPSET_LOG="$IPSET_LOG" \
sh "$SCRIPT"

grep -q '    - ssrplus.example.com/whitelist' "$CONFIG_DEFAULT"
grep -q '    - ssrplus-wild.example/whitelist' "$CONFIG_DEFAULT"

echo "whitelist_ipset2adg smoke test passed"
