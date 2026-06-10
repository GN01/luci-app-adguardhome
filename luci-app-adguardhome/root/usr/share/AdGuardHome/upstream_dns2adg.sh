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
		upstream_dns_base_url_github) value="${UPSTREAM_DNS_GITHUB:-}" ;;
		upstream_dns_base_url_cdn) value="${UPSTREAM_DNS_CDN:-}" ;;
		upstream_dns_files) value="${UPSTREAM_DNS_FILES:-}" ;;
		upstream_dns_file) value="${UPSTREAM_DNS_FILE:-}" ;;
	esac
	if [ -z "$value" ] && command -v uci >/dev/null 2>&1; then
		value="$(uci get "AdGuardHome.AdGuardHome.$key" 2>/dev/null)"
	fi
	[ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$default"
}

#=== YAML Helpers (reuse pattern from custom_ipset2adg.sh) ===#
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
download_file() {
	local file_name="$1"
	local url_primary="${BASE_URL_GITHUB}/${file_name}"
	local url_backup="${BASE_URL_CDN}/${file_name}"
	local output_file="${WORK_DIR}/${file_name}"

	if command -v wget-ssl >/dev/null 2>&1; then
		WGET="wget-ssl"
	else
		WGET="wget"
	fi

	if $WGET --no-check-certificate -q -T 15 -t 2 "$url_primary" -O "$output_file" 2>/dev/null; then
		return 0
	fi

	$WGET --no-check-certificate -q -T 15 -t 2 "$url_backup" -O "$output_file" 2>/dev/null && return 0

	return 1
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
BASE_URL_GITHUB="$(uci_get upstream_dns_base_url_github "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release")"
BASE_URL_CDN="$(uci_get upstream_dns_base_url_cdn "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release")"
files_list="$(uci_get upstream_dns_files "direct-list.txt apple-cn.txt google-cn.txt")"
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

# --- Step B: Download and convert domain lists ---
TEMP_RULES="${WORK_DIR}/cn_rules.txt"
: > "$TEMP_RULES"
files_count=0
success_count=0

for file in $files_list; do
	files_count=$((files_count + 1))
	if download_file "$file"; then
		# Convert: skip regex lines, strip 'full:' prefix, wrap as [/domain/]cn_upstream
		cat "${WORK_DIR}/${file}" | \
		grep -v "^regexp:" | \
		sed 's/^full://g' | \
		sed "s#^#[/#g" | \
		sed "s#\$#/]${cn_upstream}#g" >> "$TEMP_RULES"
		success_count=$((success_count + 1))
	else
		echo "[ERROR] download failed: $file"
	fi
done

if [ "$success_count" -ne "$files_count" ] || [ ! -s "$TEMP_RULES" ]; then
	echo "download incomplete or rules empty, aborting"
	exit 1
fi

# --- Step C: Merge into final file ---
echo "# === China Direct Rules (AliDNS) ===" >> "$FINAL_FILE"
cat "$TEMP_RULES" >> "$FINAL_FILE"

# --- Replace target file ---
mv -f "$FINAL_FILE" "$output"

# --- Set dns.upstream_dns_file in YAML ---
yaml_set_dns_value upstream_dns_file "$output" "$configpath"

reload_service "$reload_arg"
