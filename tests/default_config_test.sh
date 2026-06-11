#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

for file in \
	"$ROOT_DIR/root/etc/AdGuardHome.yaml" \
	"$ROOT_DIR/root/usr/share/AdGuardHome/AdGuardHome_template.yaml"; do
	if ! awk '
		$0 ~ /^dns:/ { in_dns=1; next }
		in_dns && $0 ~ /^[^[:space:]]/ { in_dns=0 }
		in_dns && $1 == "port:" && $2 == "1745" { found=1 }
		END { exit(found ? 0 : 1) }
	' "$file"; then
		echo "$file should default dns.port to 1745"
		exit 1
	fi
done

echo "default config test passed"
