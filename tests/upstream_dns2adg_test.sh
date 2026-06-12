#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/share/AdGuardHome/upstream_dns2adg.sh"
TMP_DIR="${TMPDIR:-/tmp}/upstream-dns-test.$$"
CONFIG="$TMP_DIR/AdGuardHome.yaml"
OUTPUT="$TMP_DIR/adguard_upstream_dns_file.txt"
WGET="$TMP_DIR/wget"
WGET_LOG="$TMP_DIR/wget.log"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/sources"

cat > "$CONFIG" <<'YAML'
dns:
  upstream_dns:
    - 223.5.5.5
  upstream_dns_file: ""
  ipset: []
YAML

cat > "$TMP_DIR/sources/direct-list.txt" <<'EOF_DIRECT'
example.cn
full:full.example.cn
regexp:^skip.example
EOF_DIRECT

cat > "$TMP_DIR/sources/apple-cn.txt" <<'EOF_APPLE'
apple.com
icloud.com
EOF_APPLE

cat > "$TMP_DIR/sources/google-cn.txt" <<'EOF_GOOGLE'
google.cn
EOF_GOOGLE

cat > "$WGET" <<'EOF_WGET'
#!/bin/sh
url=""
output=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-O)
			shift
			output="$1"
			;;
		http://*|https://*)
			url="$1"
			;;
	esac
	shift
done

case "$url" in
	https://example.test/direct-list.txt) cp "$UPSTREAM_DNS_TEST_SOURCE_DIR/direct-list.txt" "$output" ;;
	https://mirror.test/apple-cn.txt) cp "$UPSTREAM_DNS_TEST_SOURCE_DIR/apple-cn.txt" "$output" ;;
	https://cdn.test/google-cn.txt) cp "$UPSTREAM_DNS_TEST_SOURCE_DIR/google-cn.txt" "$output" ;;
	*) exit 1 ;;
esac
printf '%s\n' "$url" >> "$UPSTREAM_DNS_TEST_WGET_LOG"
EOF_WGET
chmod +x "$WGET"

UPSTREAM_DNS_URLS="https://example.test/direct-list.txt
https://mirror.test/apple-cn.txt
https://cdn.test/google-cn.txt" \
UPSTREAM_DNS_CONFIG="$CONFIG" \
UPSTREAM_DNS_FILE="$OUTPUT" \
UPSTREAM_DNS_CN="https://223.5.5.5/dns-query https://1.12.12.12/dns-query" \
UPSTREAM_DNS_DEFAULT="https://dns.cloudflare.com/dns-query https://dns.google/dns-query" \
UPSTREAM_DNS_CUSTOM_RULES="#转发.lan域名到dnsmasq
#[/lan/]127.0.0.1:1745
[/test.lan/]127.0.0.1:1745" \
UPSTREAM_DNS_NO_RELOAD="1" \
UPSTREAM_DNS_TEST_WGET="$WGET" \
UPSTREAM_DNS_TEST_WGET_LOG="$WGET_LOG" \
UPSTREAM_DNS_TEST_SOURCE_DIR="$TMP_DIR/sources" \
sh "$SCRIPT"

grep -q "https://dns.cloudflare.com/dns-query" "$OUTPUT"
grep -q "https://dns.google/dns-query" "$OUTPUT"
grep -q "# === Custom Domain Upstream Rules ===" "$OUTPUT"
grep -q "#转发.lan域名到dnsmasq" "$OUTPUT"
grep -q "#\\[/lan/\\]127.0.0.1:1745" "$OUTPUT"
grep -q "\\[/test.lan/\\]127.0.0.1:1745" "$OUTPUT"
grep -q "\\[/example.cn/\\]https://223.5.5.5/dns-query https://1.12.12.12/dns-query" "$OUTPUT"
grep -q "\\[/full.example.cn/\\]https://223.5.5.5/dns-query https://1.12.12.12/dns-query" "$OUTPUT"
grep -q "\\[/apple.com/\\]https://223.5.5.5/dns-query https://1.12.12.12/dns-query" "$OUTPUT"
grep -q "\\[/google.cn/\\]https://223.5.5.5/dns-query https://1.12.12.12/dns-query" "$OUTPUT"
if grep -q "regexp:" "$OUTPUT"; then
	echo "regexp rules should be skipped"
	exit 1
fi
grep -q "  upstream_dns_file: $OUTPUT" "$CONFIG"
grep -q "^https://example.test/direct-list.txt$" "$WGET_LOG"
grep -q "^https://mirror.test/apple-cn.txt$" "$WGET_LOG"
grep -q "^https://cdn.test/google-cn.txt$" "$WGET_LOG"

echo "upstream_dns2adg URL list test passed"
