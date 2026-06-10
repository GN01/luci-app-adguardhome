#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh"
TMP_DIR="${TMPDIR:-/tmp}/custom-ipset-test.$$"
CONFIG="$TMP_DIR/AdGuardHome.yaml"
OUTPUT="$TMP_DIR/custom_ipset.txt"
URL_FILE="$TMP_DIR/source.txt"
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
  ipset: []
YAML

cat > "$URL_FILE" <<'EOF_DATA'
# remote source
[/remote.example/]https://dns.example/dns-query
/already.example/oldset
192.0.2.1
EOF_DATA

CUSTOM_IPSET_NAME="testset" \
CUSTOM_IPSET_FILE="$OUTPUT" \
CUSTOM_IPSET_DOMAINS="
# manual source
example.com
.wild.example
[/split.example/]https://223.5.5.5/dns-query
/kept.example/otherset
example.com
bad value
203.0.113.5
" \
CUSTOM_IPSET_URLS="file://$URL_FILE" \
CUSTOM_IPSET_CONFIG="$CONFIG" \
CUSTOM_IPSET_NO_RELOAD="1" \
CUSTOM_IPSET_TEST_IPSET_LOG="$IPSET_LOG" \
sh "$SCRIPT"

EXPECTED="$TMP_DIR/expected.txt"
cat > "$EXPECTED" <<'EOF_EXPECTED'
/already.example/testset
/example.com/testset
/kept.example/testset
/remote.example/testset
/split.example/testset
/wild.example/testset
EOF_EXPECTED

sort "$OUTPUT" > "$TMP_DIR/output.sorted"
diff -u "$EXPECTED" "$TMP_DIR/output.sorted"

grep -q 'upstream_dns_file: "/opt/adguardhome/conf/adguard_upstream_dns_file.txt"' "$CONFIG"
grep -q "  ipset_file: $OUTPUT" "$CONFIG"
grep -q "create testset hash:ip" "$IPSET_LOG"

CUSTOM_IPSET_NAME="testset" \
CUSTOM_IPSET_FILE="$OUTPUT" \
CUSTOM_IPSET_CONFIG="$CONFIG" \
CUSTOM_IPSET_NO_RELOAD="1" \
sh "$SCRIPT" del

grep -q '  ipset_file: ""' "$CONFIG"
grep -q 'upstream_dns_file: "/opt/adguardhome/conf/adguard_upstream_dns_file.txt"' "$CONFIG"

echo "custom_ipset2adg smoke test passed"
