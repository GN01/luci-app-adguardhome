# Custom ipset_file Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generic AdGuardHome `ipset_file` feature that generates a domain-to-ipset file from manual domains and URL sources with a user-defined ipset name.

**Architecture:** Keep the feature separate from the existing GFW helpers. Add one focused generator script, expose its settings in the existing LuCI `Other Config` tab, and teach the init script to create ipset sets from the configured `ipset_file` instead of only the hard-coded `gfwlist` set.

**Tech Stack:** OpenWrt LuCI Lua CBI, POSIX shell, UCI, AdGuardHome YAML, `ipset`, `wget-ssl` or `wget`.

---

## File Map

- Create `luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh`: generates and enables the custom AdGuardHome `ipset_file`.
- Create `tests/custom_ipset2adg_test.sh`: local shell smoke test using temporary files and script environment overrides.
- Modify `luci-app-adguardhome/luasrc/model/cbi/AdGuardHome/base.lua`: add custom ipset fields and generate/delete buttons under `Other Config`.
- Modify `luci-app-adguardhome/root/etc/config/AdGuardHome`: add default UCI values.
- Modify `luci-app-adguardhome/root/etc/init.d/AdGuardHome`: create all sets referenced by the active `ipset_file`.
- Modify `luci-app-adguardhome/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json`: allow LuCI to execute the new script.
- Modify `luci-app-adguardhome/po/zh-cn/AdGuardHome.po` and `luci-app-adguardhome/po/zh_Hans/AdGuardHome.po`: add Chinese labels.

---

### Task 1: Add Generator Test

**Files:**
- Create: `tests/custom_ipset2adg_test.sh`
- Depends on future script behavior in: `luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh`

- [ ] **Step 1: Write the failing smoke test**

Create `tests/custom_ipset2adg_test.sh` with:

```sh
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
```

- [ ] **Step 2: Run the test to verify it fails because the script is missing**

Run:

```bash
sh tests/custom_ipset2adg_test.sh
```

Expected: FAIL with a message that `custom_ipset2adg.sh` cannot be opened.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/custom_ipset2adg_test.sh
git commit -m "test: cover custom ipset file generation"
```

---

### Task 2: Add Custom ipset Generator Script

**Files:**
- Create: `luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh`
- Test: `tests/custom_ipset2adg_test.sh`

- [ ] **Step 1: Implement the script**

Create `luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh`:

```sh
#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

uci_get() {
	local key="$1"
	local default="$2"
	local value=""
	case "$key" in
		configpath) value="${CUSTOM_IPSET_CONFIG:-}" ;;
		custom_ipset_name) value="${CUSTOM_IPSET_NAME:-}" ;;
		custom_ipset_file) value="${CUSTOM_IPSET_FILE:-}" ;;
		custom_ipset_domains) value="${CUSTOM_IPSET_DOMAINS:-}" ;;
		custom_ipset_urls) value="${CUSTOM_IPSET_URLS:-}" ;;
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

download_url() {
	local url="$1"
	local outfile="$2"
	case "$url" in
		file://*)
			cp "${url#file://}" "$outfile"
			return $?
			;;
	esac
	if command -v wget-ssl >/dev/null 2>&1; then
		wget-ssl --no-check-certificate "$url" -O "$outfile"
	else
		wget --no-check-certificate "$url" -O "$outfile"
	fi
}

ensure_ipset() {
	local setname="$1"
	if [ -n "${CUSTOM_IPSET_TEST_IPSET_LOG:-}" ]; then
		printf 'create %s hash:ip\n' "$setname" >> "$CUSTOM_IPSET_TEST_IPSET_LOG"
		return
	fi
	if command -v ipset >/dev/null 2>&1; then
		ipset list "$setname" >/dev/null 2>&1 || ipset create "$setname" hash:ip 2>/dev/null
	fi
}

reload_service() {
	[ "${CUSTOM_IPSET_NO_RELOAD:-0}" = "1" ] && return
	[ "$1" = "noreload" ] && return
	/etc/init.d/AdGuardHome reload
}

action="$1"
reload_arg="$2"
[ "$action" = "noreload" ] && reload_arg="noreload" && action=""

configpath="$(uci_get configpath "/etc/AdGuardHome.yaml")"
setname="$(uci_get custom_ipset_name "adguardhome")"
output="$(uci_get custom_ipset_file "/etc/AdGuardHome/custom_ipset.txt")"

if [ ! -f "$configpath" ]; then
	echo "please make a config first"
	exit 1
fi

case "$setname" in
	*[!A-Za-z0-9_.-]*|"")
		echo "invalid custom ipset name: $setname"
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

tmpdir="${TMPDIR:-/tmp}/custom_ipset2adg.$$"
mkdir -p "$tmpdir" "${output%/*}"
trap 'rm -rf "$tmpdir"' EXIT

domains_file="$tmpdir/domains.raw"
: > "$domains_file"
uci_get custom_ipset_domains "" >> "$domains_file"

idx=0
uci_get custom_ipset_urls "" | while IFS= read -r url; do
	[ -z "$url" ] && continue
	case "$url" in \#*) continue ;; esac
	idx=$((idx + 1))
	download_url "$url" "$tmpdir/url.$idx" && cat "$tmpdir/url.$idx" >> "$domains_file"
done

normalize_domains < "$domains_file" | awk -v setname="$setname" '{ print "/" $0 "/" setname }' | sort -u > "$output"

if [ ! -s "$output" ]; then
	echo "no valid domains for custom ipset"
	exit 1
fi

yaml_set_dns_value ipset_file "$output" "$configpath"
ensure_ipset "$setname"
reload_service "$reload_arg"
```

- [ ] **Step 2: Make the script executable**

Run:

```bash
chmod +x luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh
```

- [ ] **Step 3: Run shell syntax check**

Run:

```bash
sh -n luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh
```

Expected: exits with status 0 and no output.

- [ ] **Step 4: Run the smoke test**

Run:

```bash
sh tests/custom_ipset2adg_test.sh
```

Expected: `custom_ipset2adg smoke test passed`.

- [ ] **Step 5: Commit script and passing test**

```bash
git add luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh tests/custom_ipset2adg_test.sh
git commit -m "feat: add custom ipset file generator"
```

---

### Task 3: Add LuCI Configuration Fields and Buttons

**Files:**
- Modify: `luci-app-adguardhome/luasrc/model/cbi/AdGuardHome/base.lua`
- Modify: `luci-app-adguardhome/root/etc/config/AdGuardHome`
- Modify: `luci-app-adguardhome/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json`

- [ ] **Step 1: Add default UCI values**

In `luci-app-adguardhome/root/etc/config/AdGuardHome`, add these options inside `config AdGuardHome 'AdGuardHome'`:

```uci
	option custom_ipset_enable '0'
	option custom_ipset_name 'adguardhome'
	option custom_ipset_file '/etc/AdGuardHome/custom_ipset.txt'
```

- [ ] **Step 2: Add LuCI ACL entry**

In `luci-app-adguardhome/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json`, add:

```json
"/usr/share/AdGuardHome/custom_ipset2adg.sh": [ "exec" ],
```

Place it beside the existing `gfwipset2adg.sh` entry.

- [ ] **Step 3: Add fields and buttons to the Other Config tab**

In `luci-app-adguardhome/luasrc/model/cbi/AdGuardHome/base.lua`, insert this block before `---- GFWList Settings ----`:

```lua
---- Custom ipset_file Settings ----
o = s:taboption("other", Flag, "custom_ipset_enable", translate("Enable custom ipset_file"), translate("Generate AdGuardHome ipset_file from custom domains and URL sources"))
o.default = 0
o.optional = true

o = s:taboption("other", Value, "custom_ipset_name", translate("Custom ipset name"), translate("Only letters, numbers, underscore, dash and dot are allowed"))
o.default = "adguardhome"
o.datatype = "string"
o.optional = false
o:depends("custom_ipset_enable", "1")
o.validate=function(self, value)
	if not value or value == "" or value:match("[^A-Za-z0-9_.%-]") then
		if m.message then
			m.message = m.message .. "\nerror! custom ipset name is invalid"
		else
			m.message = "error! custom ipset name is invalid"
		end
		return nil
	end
	return value
end

o = s:taboption("other", Value, "custom_ipset_file", translate("Custom ipset_file path"), translate("Generated file path for AdGuardHome dns.ipset_file"))
o.default = "/etc/AdGuardHome/custom_ipset.txt"
o.datatype = "string"
o.optional = false
o:depends("custom_ipset_enable", "1")

o = s:taboption("other", TextValue, "custom_ipset_domains", translate("Custom ipset domains"), translate("One domain or rule per line. Supported forms: example.com, [/example.com/]server, /example.com/setname"))
o.rows = 8
o.wrap = "off"
o.optional = true
o:depends("custom_ipset_enable", "1")
o.cfgvalue = function(self, section)
	return uci:get("AdGuardHome", section, "custom_ipset_domains") or ""
end
o.write = function(self, section, value)
	uci:set("AdGuardHome", section, "custom_ipset_domains", value:gsub("\r\n", "\n"))
end

o = s:taboption("other", DynamicList, "custom_ipset_urls", translate("Custom ipset source URLs"), translate("One URL per source file. Sources are downloaded when generating the ipset_file"))
o.optional = true
o:depends("custom_ipset_enable", "1")

o = s:taboption("other", Button, "custom_ipset_apply", translate("Generate custom ipset_file"), translate("Generate file, set dns.ipset_file, create ipset name and reload AdGuardHome"))
o.inputtitle = translate("Generate")
o:depends("custom_ipset_enable", "1")
o.write=function()
	luci.sys.exec("sh /usr/share/AdGuardHome/custom_ipset2adg.sh 2>&1 >/tmp/AdGuardHome_custom_ipset.log")
	luci.http.redirect(luci.dispatcher.build_url("admin","services","AdGuardHome"))
end

o = s:taboption("other", Button, "custom_ipset_del", translate("Delete custom ipset_file setting"), translate("Clear dns.ipset_file only when it points to the custom ipset_file path"))
o.inputtitle = translate("Del")
o.write=function()
	luci.sys.exec("sh /usr/share/AdGuardHome/custom_ipset2adg.sh del 2>&1 >/tmp/AdGuardHome_custom_ipset.log")
	luci.http.redirect(luci.dispatcher.build_url("admin","services","AdGuardHome"))
end
```

- [ ] **Step 4: Generate on Save & Apply when enabled**

In `m.on_commit(map)` in `base.lua`, before the first reload branch, add:

```lua
	local custom_ipset_enable=uci:get("AdGuardHome","AdGuardHome","custom_ipset_enable")
	if custom_ipset_enable=="1" then
		luci.sys.call("sh /usr/share/AdGuardHome/custom_ipset2adg.sh noreload >/tmp/AdGuardHome_custom_ipset.log 2>&1")
	else
		luci.sys.call("sh /usr/share/AdGuardHome/custom_ipset2adg.sh del noreload >/tmp/AdGuardHome_custom_ipset.log 2>&1")
	end
```

- [ ] **Step 5: Run syntax checks**

Run:

```bash
sh -n luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh
```

Expected: exits with status 0 and no output.

If `luac` exists, run:

```bash
luac -p luci-app-adguardhome/luasrc/model/cbi/AdGuardHome/base.lua
```

Expected: exits with status 0 and no output. If `luac` is unavailable, record that in the final verification notes.

- [ ] **Step 6: Commit LuCI integration**

```bash
git add luci-app-adguardhome/luasrc/model/cbi/AdGuardHome/base.lua luci-app-adguardhome/root/etc/config/AdGuardHome luci-app-adguardhome/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json
git commit -m "feat: expose custom ipset file settings"
```

---

### Task 4: Create ipset Sets From Active ipset_file

**Files:**
- Modify: `luci-app-adguardhome/root/etc/init.d/AdGuardHome`

- [ ] **Step 1: Add helper functions**

In `luci-app-adguardhome/root/etc/init.d/AdGuardHome`, add these functions above `start_service()`:

```sh
get_dns_config_value()
{
	local key="$1"
	local file="$2"
	[ -f "$file" ] || return
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

ensure_ipset_file_sets()
{
	local configpath="$1"
	local ipset_file setname
	command -v ipset >/dev/null 2>&1 || return
	ipset_file="$(get_dns_config_value ipset_file "$configpath")"
	[ -n "$ipset_file" ] && [ -f "$ipset_file" ] || return
	awk -F/ '
		NF >= 4 && $2 != "" && $3 != "" {
			print $3
		}
	' "$ipset_file" | sort -u | while IFS= read -r setname; do
		case "$setname" in
			*[!A-Za-z0-9_.-]*|"") continue ;;
		esac
		ipset list "$setname" >/dev/null 2>&1 || ipset create "$setname" hash:ip 2>/dev/null
	done
}
```

- [ ] **Step 2: Replace hard-coded gfwlist startup creation**

In `start_service()`, replace:

```sh
	local ipst=0
```

with no local `ipst` declaration.

Then replace:

```sh
	grep -q "ipset.txt" $configpath 2>/dev/null && ipst=1
	if [ $ipst -eq 1 ];then
		ipset list $GFWSET >/dev/null 2>&1 || ipset create $GFWSET hash:ip 2>/dev/null
	fi
```

with:

```sh
	ensure_ipset_file_sets "$configpath"
```

Keep `GFWSET="gfwlist"` unchanged for compatibility with any existing references.

- [ ] **Step 3: Run shell syntax check**

Run:

```bash
sh -n luci-app-adguardhome/root/etc/init.d/AdGuardHome
```

Expected: exits with status 0 and no output.

- [ ] **Step 4: Re-run generator test**

Run:

```bash
sh tests/custom_ipset2adg_test.sh
```

Expected: `custom_ipset2adg smoke test passed`.

- [ ] **Step 5: Commit service startup integration**

```bash
git add luci-app-adguardhome/root/etc/init.d/AdGuardHome
git commit -m "feat: create ipset sets from ipset_file"
```

---

### Task 5: Add Translations

**Files:**
- Modify: `luci-app-adguardhome/po/zh-cn/AdGuardHome.po`
- Modify: `luci-app-adguardhome/po/zh_Hans/AdGuardHome.po`

- [ ] **Step 1: Add translation entries to both Chinese PO files**

Append these entries before the trailing empty `msgid` block if present:

```po
msgid "Enable custom ipset_file"
msgstr "启用自定义 ipset_file"

msgid "Generate AdGuardHome ipset_file from custom domains and URL sources"
msgstr "从自定义域名和链接源生成 AdGuardHome ipset_file"

msgid "Custom ipset name"
msgstr "自定义 ipset 名称"

msgid "Only letters, numbers, underscore, dash and dot are allowed"
msgstr "仅允许字母、数字、下划线、短横线和点"

msgid "Custom ipset_file path"
msgstr "自定义 ipset_file 路径"

msgid "Generated file path for AdGuardHome dns.ipset_file"
msgstr "AdGuardHome dns.ipset_file 的生成文件路径"

msgid "Custom ipset domains"
msgstr "自定义 ipset 域名"

msgid "One domain or rule per line. Supported forms: example.com, [/example.com/]server, /example.com/setname"
msgstr "每行一个域名或规则。支持格式：example.com、[/example.com/]server、/example.com/setname"

msgid "Custom ipset source URLs"
msgstr "自定义 ipset 来源链接"

msgid "One URL per source file. Sources are downloaded when generating the ipset_file"
msgstr "每个来源文件填写一个 URL。生成 ipset_file 时会下载这些来源"

msgid "Generate custom ipset_file"
msgstr "生成自定义 ipset_file"

msgid "Generate file, set dns.ipset_file, create ipset name and reload AdGuardHome"
msgstr "生成文件、设置 dns.ipset_file、创建 ipset 名称并重载 AdGuardHome"

msgid "Generate"
msgstr "生成"

msgid "Delete custom ipset_file setting"
msgstr "删除自定义 ipset_file 设置"

msgid "Clear dns.ipset_file only when it points to the custom ipset_file path"
msgstr "仅当 dns.ipset_file 指向自定义路径时清空该设置"
```

- [ ] **Step 2: Commit translations**

```bash
git add luci-app-adguardhome/po/zh-cn/AdGuardHome.po luci-app-adguardhome/po/zh_Hans/AdGuardHome.po
git commit -m "i18n: add custom ipset labels"
```

---

### Task 6: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Check working tree**

Run:

```bash
git status --short
```

Expected: no unstaged changes before final verification commits, or only expected files if commits were intentionally skipped during inline execution.

- [ ] **Step 2: Run shell syntax checks**

Run:

```bash
sh -n luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh
sh -n luci-app-adguardhome/root/etc/init.d/AdGuardHome
sh -n luci-app-adguardhome/root/usr/share/AdGuardHome/gfwipset2adg.sh
sh -n luci-app-adguardhome/root/usr/share/AdGuardHome/gfw2adg.sh
```

Expected: all commands exit with status 0 and no output.

- [ ] **Step 3: Run smoke test**

Run:

```bash
sh tests/custom_ipset2adg_test.sh
```

Expected: `custom_ipset2adg smoke test passed`.

- [ ] **Step 4: Check Lua syntax when available**

Run:

```bash
command -v luac
```

If it prints a path, run:

```bash
luac -p luci-app-adguardhome/luasrc/model/cbi/AdGuardHome/base.lua
```

Expected: exits with status 0 and no output. If `luac` is not installed, record that Lua syntax verification could not run locally.

- [ ] **Step 5: Review diffs for the upstream DNS boundary**

Run:

```bash
git diff HEAD~5..HEAD -- luci-app-adguardhome/root/usr/share/AdGuardHome/custom_ipset2adg.sh luci-app-adguardhome/luasrc/model/cbi/AdGuardHome/base.lua luci-app-adguardhome/root/etc/init.d/AdGuardHome
```

Expected: custom code updates `dns.ipset_file` and does not write to `upstream_dns_file`.

- [ ] **Step 6: Final status**

Run:

```bash
git status --short
```

Expected: clean working tree.
