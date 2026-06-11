#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
DEFAULT_WHITELIST_DOMAINS_FILE="${WHITELIST_IPSET_DEFAULT_FILE:-/etc/ssrplus/white.list}"

uci_get() {
	local key="$1"
	local default="$2"
	local value=""
	case "$key" in
		configpath) value="${WHITELIST_IPSET_CONFIG:-}" ;;
		whitelist_ipset_name) value="${WHITELIST_IPSET_NAME:-}" ;;
		whitelist_ipset_domains) value="${WHITELIST_IPSET_DOMAINS:-}" ;;
	esac
	if [ -z "$value" ] && command -v uci >/dev/null 2>&1; then
		value="$(uci get "AdGuardHome.AdGuardHome.$key" 2>/dev/null)"
	fi
	if [ -n "$value" ]; then
		printf '%s\n' "$value"
		return
	fi
	if [ "$key" = "whitelist_ipset_domains" ] && [ -f "$DEFAULT_WHITELIST_DOMAINS_FILE" ]; then
		cat "$DEFAULT_WHITELIST_DOMAINS_FILE"
		return
	fi
	printf '%s\n' "$default"
}

yaml_set_dns_ipset() {
	local entries_file="$1"
	local file="$2"
	local tmp="${file}.tmp.$$"

	awk -v entries_file="$entries_file" '
		BEGIN {
			while ((getline line < entries_file) > 0) {
				if (line != "") {
					entries[++entry_count] = line
				}
			}
			close(entries_file)
		}
		function print_ipset(    i) {
			if (entry_count == 0) {
				print "  ipset: []"
				return
			}
			print "  ipset:"
			for (i = 1; i <= entry_count; i++) {
				print "    - " entries[i]
			}
		}
		$0 ~ /^dns:/ { in_dns=1; print; next }
		in_dns && $0 ~ /^[^[:space:]]/ {
			if (!done) {
				print_ipset()
				done=1
			}
			in_dns=0
		}
		in_dns && $1 == "ipset_file:" {
			next
		}
		in_dns && $1 == "ipset:" {
			if (!done) {
				print_ipset()
				done=1
			}
			skip_ipset=1
			next
		}
		in_dns && skip_ipset {
			if ($0 ~ /^  [^[:space:]-]/) {
				skip_ipset=0
			} else {
				next
			}
		}
		in_dns && !done && $1 == "filtering_enabled:" {
			print_ipset()
			done=1
		}
		{ print }
		END {
			if (in_dns && !done) {
				print_ipset()
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
		printf 'create %s hash:net timeout 86400\n' "$setname" >> "$WHITELIST_IPSET_TEST_IPSET_LOG"
		return
	fi
	if command -v ipset >/dev/null 2>&1; then
		ipset list "$setname" >/dev/null 2>&1 || ipset create "$setname" hash:net timeout 86400 2>/dev/null
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
	empty_file="${TMPDIR:-/tmp}/whitelist_ipset2adg.empty.$$"
	: > "$empty_file"
	yaml_set_dns_ipset "$empty_file" "$configpath"
	rm -f "$empty_file"
	reload_service "$reload_arg"
	exit 0
fi

tmpdir="${TMPDIR:-/tmp}/whitelist_ipset2adg.$$"
mkdir -p "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT

domains_file="$tmpdir/domains.raw"
entries_file="$tmpdir/ipset.entries"
: > "$domains_file"
uci_get whitelist_ipset_domains "" >> "$domains_file"

normalize_domains < "$domains_file" | awk -v setname="$setname" '{ print $0 "/" setname }' | sort -u > "$entries_file"

if [ ! -s "$entries_file" ]; then
	echo "no valid domains for whitelist ipset"
	yaml_set_dns_ipset "$entries_file" "$configpath"
	reload_service "$reload_arg"
	exit 0
fi

yaml_set_dns_ipset "$entries_file" "$configpath"
ensure_ipset "$setname"
reload_service "$reload_arg"
