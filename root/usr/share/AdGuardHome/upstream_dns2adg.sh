#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

#=== UCI Helper ===#
uci_get() {
	local key="$1"
	local default="$2"
	local value=""
	case "$key" in
		configpath) value="${UPSTREAM_DNS_CONFIG:-}" ;;
		upstream_dns_cn_upstream) value="${UPSTREAM_DNS_CN:-}" ;;
		upstream_dns_default_upstreams) value="${UPSTREAM_DNS_DEFAULT:-}" ;;
		upstream_dns_custom_rules) value="${UPSTREAM_DNS_CUSTOM_RULES:-}" ;;
		upstream_dns_urls) value="${UPSTREAM_DNS_URLS:-}" ;;
		upstream_dns_file) value="${UPSTREAM_DNS_FILE:-}" ;;
	esac
	if [ -z "$value" ] && command -v uci >/dev/null 2>&1; then
		value="$(uci get "AdGuardHome.AdGuardHome.$key" 2>/dev/null)"
	fi
	[ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$default"
}

#=== YAML Helpers (reuse pattern from whitelist_ipset2adg.sh) ===#
yaml_get_dns_value() {
	local key="$1"
	local file="$2"
	awk -v key="$key" '
		$0 ~ /^dns:/ { in_dns=1; next }
		in_dns && $0 ~ /^[^[:space:]]/ { in_dns=0 }
		in_dns && $1 == key ":" {
			sub(/^[^:]+:[[:space:]]*/, "")
			gsub(/^"|"$/, "")
			print
			exit
		}
	' "$file"
}

yaml_set_dns_value() {
	local key="$1"
	local value="$2"
	local file="$3"
	local tmp="${file}.tmp.$$"
	awk -v key="$key" -v value="$value" '
		$0 ~ /^dns:/ { in_dns=1; print; next }
		in_dns && $0 ~ /^[^[:space:]]/ {
			if (!done) {
				print "  " key ": " value
				done=1
			}
			in_dns=0
		}
		in_dns && $1 == key ":" {
			if (!done) {
				print "  " key ": " value
				done=1
			}
			next
		}
		in_dns && !done && $1 == "ipset:" {
			print
			print "  " key ": " value
			done=1
			next
		}
		{ print }
		END {
			if (in_dns && !done) {
				print "  " key ": " value
			}
		}
	' "$file" > "$tmp" && mv "$tmp" "$file"
}

#=== Download Helper ===#
download_url() {
	local url="$1"
	local output_file="$2"

	if [ -n "${UPSTREAM_DNS_TEST_WGET:-}" ]; then
		WGET="$UPSTREAM_DNS_TEST_WGET"
	elif command -v wget-ssl >/dev/null 2>&1; then
		WGET="wget-ssl"
	else
		WGET="wget"
	fi

	$WGET --no-check-certificate -q -T 15 -t 2 "$url" -O "$output_file" 2>/dev/null
}

reload_service() {
	[ "${UPSTREAM_DNS_NO_RELOAD:-0}" = "1" ] && return
	[ "$1" = "noreload" ] && return
	/etc/init.d/AdGuardHome reload
}

#=== Main Logic ===#
action="$1"
reload_arg="$2"
[ "$action" = "noreload" ] && reload_arg="noreload" && action=""

configpath="$(uci_get configpath "/etc/AdGuardHome.yaml")"
cn_upstream="$(uci_get upstream_dns_cn_upstream "https://223.5.5.5/dns-query https://1.12.12.12/dns-query")"
default_upstreams="$(uci_get upstream_dns_default_upstreams "https://dns.cloudflare.com/dns-query https://dns.google/dns-query")"
custom_rules="$(uci_get upstream_dns_custom_rules "#转发.lan域名到dnsmasq
#[/lan/]127.0.0.1:1745")"
urls_list="$(uci_get upstream_dns_urls "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple-cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/google-cn.txt")"
output="$(uci_get upstream_dns_file "/etc/AdGuardHome/adguard_upstream_dns_file.txt")"

if [ ! -f "$configpath" ]; then
	echo "please make a config first"
	exit 1
fi

# --- Del action: clear upstream_dns_file in YAML ---
if [ "$action" = "del" ]; then
	current="$(yaml_get_dns_value upstream_dns_file "$configpath")"
	if [ "$current" = "$output" ]; then
		yaml_set_dns_value upstream_dns_file '""' "$configpath"
		reload_service "$reload_arg"
	fi
	exit 0
fi

# --- Generate upstream_dns_file ---
WORK_DIR="${TMPDIR:-/tmp}/upstream_dns2adg.$$"
mkdir -p "$WORK_DIR" "${output%/*}"
trap 'rm -rf "$WORK_DIR"' EXIT

FINAL_FILE="${WORK_DIR}/final_config.txt"
: > "$FINAL_FILE"

# --- Step A: Write default upstream DNS ---
echo "# === Default Upstream DNS (Fallback) ===" >> "$FINAL_FILE"
for dns in $default_upstreams; do
	echo "$dns" >> "$FINAL_FILE"
done
echo "" >> "$FINAL_FILE"

# --- Step B: Write custom domain upstream rules ---
echo "# === Custom Domain Upstream Rules ===" >> "$FINAL_FILE"
printf '%s\n' "$custom_rules" >> "$FINAL_FILE"
echo "" >> "$FINAL_FILE"

# --- Step C: Download and convert domain lists ---
TEMP_RULES="${WORK_DIR}/cn_rules.txt"
: > "$TEMP_RULES"
urls_count=0
success_count=0

for url in $urls_list; do
	urls_count=$((urls_count + 1))
	rules_file="${WORK_DIR}/rules_${urls_count}.txt"
	if download_url "$url" "$rules_file"; then
		# Convert: skip regex lines, strip 'full:' prefix, wrap as [/domain/]cn_upstream
		cat "$rules_file" | \
		grep -v "^regexp:" | \
		sed 's/^full://g' | \
		sed "s#^#[/#g" | \
		sed "s#\$#/]${cn_upstream}#g" >> "$TEMP_RULES"
		success_count=$((success_count + 1))
	else
		echo "[ERROR] download failed: $url"
	fi
done

if [ "$success_count" -ne "$urls_count" ] || [ ! -s "$TEMP_RULES" ]; then
	echo "download incomplete or rules empty, aborting"
	exit 1
fi

# --- Step D: Merge into final file ---
echo "# === China Direct Rules (AliDNS) ===" >> "$FINAL_FILE"
cat "$TEMP_RULES" >> "$FINAL_FILE"

# --- Replace target file ---
mv -f "$FINAL_FILE" "$output"

# --- Set dns.upstream_dns_file in YAML ---
yaml_set_dns_value upstream_dns_file "$output" "$configpath"

reload_service "$reload_arg"
