#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

uci_get() {
	local key="$1"
	local default="$2"
	local value=""
	case "$key" in
		configpath) value="${WHITELIST_IPSET_CONFIG:-}" ;;
		whitelist_ipset_name) value="${WHITELIST_IPSET_NAME:-}" ;;
		whitelist_ipset_file) value="${WHITELIST_IPSET_FILE:-}" ;;
		whitelist_ipset_domains) value="${WHITELIST_IPSET_DOMAINS:-}" ;;
	esac
	if [ -z "$value" ] && command -v uci >/dev/null 2>&1; then
		value="$(uci get "AdGuardHome.AdGuardHome.$key" 2>/dev/null)"
	fi
	[ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$default"
}

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

normalize_domains() {
	awk '
		function emit(domain) {
			gsub(/\r/, "", domain)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", domain)
			if (domain ~ /^\./) domain=substr(domain, 2)
			if (domain == "") return
			if (domain !~ /\./) return
			if (domain ~ /[[:space:]]/) return
			if (domain ~ /:/) return
			if (domain ~ /^[0-9.]+$/) return
			if (domain ~ /[*%]/) return
			if (!seen[domain]++) print domain
		}
		{
			line=$0
			gsub(/\r/, "", line)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
			if (line == "" || line ~ /^#/) next
			if (line ~ /^!/) next
			if (line ~ /^\[\//) {
				sub(/^\[\//, "", line)
				sub(/\/\].*$/, "", line)
				emit(line)
				next
			}
			if (line ~ /^\//) {
				sub(/^\//, "", line)
				sub(/\/.*$/, "", line)
				emit(line)
				next
			}
			if (line ~ /^\|\|/) {
				sub(/^\|\|/, "", line)
				sub(/[\/\^].*$/, "", line)
				emit(line)
				next
			}
			sub(/[\/\^].*$/, "", line)
			emit(line)
		}
	'
}

ensure_ipset() {
	local setname="$1"
	if [ -n "${WHITELIST_IPSET_TEST_IPSET_LOG:-}" ]; then
		printf 'create %s hash:ip\n' "$setname" >> "$WHITELIST_IPSET_TEST_IPSET_LOG"
		return
	fi
	if command -v ipset >/dev/null 2>&1; then
		ipset list "$setname" >/dev/null 2>&1 || ipset create "$setname" hash:ip 2>/dev/null
	fi
}

reload_service() {
	[ "${WHITELIST_IPSET_NO_RELOAD:-0}" = "1" ] && return
	[ "$1" = "noreload" ] && return
	/etc/init.d/AdGuardHome reload
}

action="$1"
reload_arg="$2"
[ "$action" = "noreload" ] && reload_arg="noreload" && action=""

configpath="$(uci_get configpath "/etc/AdGuardHome.yaml")"
setname="$(uci_get whitelist_ipset_name "whitelist")"
output="$(uci_get whitelist_ipset_file "/etc/AdGuardHome/whitelist_ipset.txt")"

if [ ! -f "$configpath" ]; then
	echo "please make a config first"
	exit 1
fi

case "$setname" in
	*[!A-Za-z0-9_.-]*|"")
		echo "invalid whitelist ipset name: $setname"
		exit 1
		;;
esac

if [ "$action" = "del" ]; then
	current="$(yaml_get_dns_value ipset_file "$configpath")"
	if [ "$current" = "$output" ]; then
		yaml_set_dns_value ipset_file '""' "$configpath"
		reload_service "$reload_arg"
	fi
	exit 0
fi

tmpdir="${TMPDIR:-/tmp}/whitelist_ipset2adg.$$"
mkdir -p "$tmpdir" "${output%/*}"
trap 'rm -rf "$tmpdir"' EXIT

domains_file="$tmpdir/domains.raw"
: > "$domains_file"
uci_get whitelist_ipset_domains "" >> "$domains_file"

normalize_domains < "$domains_file" | awk -v setname="$setname" '{ print $0 "/" setname }' | sort -u > "$output"

if [ ! -s "$output" ]; then
	echo "no valid domains for whitelist ipset"
	exit 1
fi

yaml_set_dns_value ipset_file "$output" "$configpath"
ensure_ipset "$setname"
reload_service "$reload_arg"
