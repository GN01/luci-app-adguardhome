#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/root/etc/init.d/AdGuardHome"

start_service_body="$(awk '
	/^start_service\(\) \{/ { in_func=1 }
	in_func { print }
	in_func && /^}/ { exit }
' "$INIT_SCRIPT")"

redirect_line="$(printf "%s\n" "$start_service_body" | grep -n "_do_redirect 1" | head -n 1 | cut -d: -f1 || true)"
procd_line="$(printf "%s\n" "$start_service_body" | grep -n "procd_open_instance" | head -n 1 | cut -d: -f1 || true)"
upstream_file_guard_line="$(printf "%s\n" "$start_service_body" | grep -n "ensure_upstream_dns_file_available" | head -n 1 | cut -d: -f1 || true)"

if [ -z "$redirect_line" ] || [ -z "$procd_line" ] || [ "$redirect_line" -gt "$procd_line" ]; then
	echo "start_service must prepare redirect before starting AdGuardHome"
	exit 1
fi

if [ -z "$upstream_file_guard_line" ] || [ "$upstream_file_guard_line" -gt "$procd_line" ]; then
	echo "start_service must clear missing upstream_dns_file before starting AdGuardHome"
	exit 1
fi

grep -q "ensure_upstream_dns_file_available" "$INIT_SCRIPT" || {
	echo "missing upstream_dns_file guard"
	exit 1
}

grep -q 'config_editor "dns.upstream_dns_file" '\''""'\''' "$INIT_SCRIPT" || {
	echo "missing upstream_dns_file clear operation"
	exit 1
}

grep -q "ensure_adguardhome_dns_port_available" "$INIT_SCRIPT" || {
	echo "redirect/dnsmasq-upstream modes must move AdGuardHome off port 53 before start"
	exit 1
}

grep -q 'safe_port="1745"' "$INIT_SCRIPT" || {
	echo "redirect/dnsmasq-upstream modes must use 1745 as the fixed safe port"
	exit 1
}

if grep -q "for safe_port in" "$INIT_SCRIPT"; then
	echo "redirect/dnsmasq-upstream modes must not choose rotating safe ports"
	exit 1
fi

if printf "%s\n" "$start_service_body" | grep -q "sleep 5.*_do_redirect 1"; then
	echo "start_service must not run delayed redirect after startup"
	exit 1
fi

if printf "%s\n" "$start_service_body" | grep -q "upstream_dns2adg.sh noreload"; then
	echo "start_service must not block on upstream_dns2adg.sh"
	exit 1
fi

if grep -q "CONFIGURATION\\|CRON_FILE\\|GFWSET\\|AdGuardHome_PORT\\|ADDITIONAL_ARGS\\|SET_TZ" "$INIT_SCRIPT"; then
	echo "init script internal names should be lowercase"
	exit 1
fi

grep -q 'ipset destroy "$setname"' "$INIT_SCRIPT" || {
	echo "whitelist ipset should be recreated on startup"
	exit 1
}

grep -q 'ipset create "$setname" hash:net timeout 86400' "$INIT_SCRIPT" || {
	echo "whitelist ipset should use hash:net timeout 86400"
	exit 1
}

echo "AdGuardHome redirect startup order test passed"
