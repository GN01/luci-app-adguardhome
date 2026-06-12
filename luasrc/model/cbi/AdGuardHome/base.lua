require("luci.sys")
require("luci.util")
require("io")
local m,s,o,o1
local fs=require"nixio.fs"
local uci=require"luci.model.uci".cursor()
local configpath=uci:get("AdGuardHome","AdGuardHome","configpath") or "/etc/AdGuardHome.yaml"
local binpath=uci:get("AdGuardHome","AdGuardHome","binpath") or "/usr/bin/AdGuardHome"
httpport=uci:get("AdGuardHome","AdGuardHome","httpport") or "3000"
m = Map("AdGuardHome", "AdGuard Home")
m.description = translate("Free and open source, powerful network-wide ads & trackers blocking DNS server.")
m:section(SimpleSection).template  = "AdGuardHome/AdGuardHome_status"

s = m:section(TypedSection, "AdGuardHome")
s.anonymous=true
s.addremove=false

---- Basic Settings ----
s:tab("basic", translate("Main Config"))

o = s:taboption("basic", Flag, "enabled", translate("Enable"))
o.default = 0
o.optional = false

o = s:taboption("basic", Value,"httpport",translate("Browser management port"))
o.placeholder=3000
o.default=3000
o.datatype="port"
o.optional = false

local binmtime=uci:get("AdGuardHome","AdGuardHome","binmtime") or "0"

local e=""
if not fs.access(configpath) then e = e .. " " .. translate("no config") end
if not fs.access(binpath) then
	e=e.." "..translate("no core")
else
	local version=uci:get("AdGuardHome","AdGuardHome","version")
	local testtime=fs.stat(binpath,"mtime")
	if testtime~=tonumber(binmtime) or version==nil then

        version = luci.sys.exec(string.format("echo -n $(%s --version 2>&1 | awk -F 'version ' '{print $2}' | awk -F ',' '{print $1}')", binpath))
        if version == "" then version = "core error" end
        uci:set("AdGuardHome", "AdGuardHome", "version", version)
        uci:set("AdGuardHome", "AdGuardHome", "binmtime", testtime)
        uci:commit("AdGuardHome")
	end
	e=version..e
end

o = s:taboption("basic", ListValue, "core_version", translate("Core Version"))
o:value("latest", translate("Latest Version"))
o:value("beta", translate("Beta Version"))
o.default = "latest"
o = s:taboption("basic", Button, "restart", translate("Upgrade Core"))
o.inputtitle=translate("Update core version")
o.template = "AdGuardHome/AdGuardHome_check"
o.showfastconfig=(not fs.access(configpath))
o.description = string.format(translate("Current core version:") .. "<strong><font id='updateversion' color='green'>%s </font></strong>", e)

local port=luci.sys.exec("grep -A 5 '^dns:' "..configpath.." | grep 'port:' | awk '{print $2}'  2>nul")
if (port=="") then port="?" end

o = s:taboption("basic", ListValue, "redirect", port..translate("Redirect"), translate("AdGuardHome redirect mode") .. "<br />" .. translate("When using dnsmasq upstream or 53 redirect mode, if AdGuardHome DNS port is 53, it will be changed to 1745 automatically."))
o:value("none", translate("none"))
o:value("dnsmasq-upstream", translate("Run as dnsmasq upstream server"))
o:value("redirect", translate("Redirect 53 port to AdGuardHome"))
o:value("exchange", translate("Use port 53 replace dnsmasq"))
o.default     = "none"
o.optional = true
---- chpass
o = s:taboption("basic",Value, "hashpass", translate("Change management password"), translate("Press load culculate model and culculate finally save/apply"))
o.default     = ""
o.datatype    = "string"
o.template = "AdGuardHome/AdGuardHome_chpass"
o.optional = true

-- wait net on boot
o = s:taboption("basic", Flag, "waitonboot", translate("Start up only when the network is normal"))
o.default = 1
o.optional = false

---- Core Settings ----
s:tab("core", translate("Core Config"))

o = s:taboption("core",Value, "binpath", translate("Bin Path"), translate("AdGuardHome Bin path if no bin will auto download"))
o.default     = "/usr/bin/AdGuardHome"
o.datatype = "string"
o.optional = false
o.rmempty=false
o.validate=function(self, value)
if value=="" then return nil end
if fs.stat(value,"type")=="dir" then
	fs.rmdir(value)
end
if fs.stat(value,"type")=="dir" then
	if (m.message) then
	m.message =m.message.."\nerror!bin path is a dir"
	else
	m.message ="error!bin path is a dir"
	end
	return nil
end
return value
end
--- upx
o = s:taboption("core",ListValue, "upxflag", translate("use upx to compress bin after download"))
o.default = "off"
o:value("off", translate("none"))
o:value("-1", translate("compress faster"))
o:value("-9", translate("compress better"))
o:value("--best", translate("compress best(can be slow for big files)"))
o:value("--brute", translate("try all available compression methods & filters [slow]"))
o:value("--ultra-brute", translate("try even more compression variants [very slow]"))
o.default     = ""
o.description=translate("bin use less space,but may have compatibility issues")
o.rmempty = true
---- config path
o = s:taboption("core",Value, "configpath", translate("Config Path"), translate("AdGuardHome config path"))
o.default     = "/etc/AdGuardHome.yaml"
o.datatype    = "string"
o.optional = false
o.rmempty=false
o.validate=function(self, value)
if value==nil then return nil end
if fs.stat(value,"type")=="dir" then
	fs.rmdir(value)
end
if fs.stat(value,"type")=="dir" then
	if m.message then
	m.message =m.message.."\nerror!config path is a dir"
	else
	m.message ="error!config path is a dir"
	end
	return nil
end
return value
end
---- work dir
o = s:taboption("core",Value, "workdir", translate("Work dir"), translate("AdGuardHome work dir include rules,audit log and database"))
o.default     = "/etc/AdGuardHome"
o.datatype = "string"
o.optional = false
o.rmempty=false
o.validate=function(self, value)
if value=="" then return nil end
if fs.stat(value,"type")=="reg" then
	if m.message then
	m.message =m.message.."\nerror!work dir is a file"
	else
	m.message ="error!work dir is a file"
	end
	return nil
end
if string.sub(value, -1)=="/" then
	return string.sub(value, 1, -2)
else
	return value
end
end
---- log file
o = s:taboption("core",Value, "logfile", translate("Runtime log file"), translate("AdGuardHome runtime Log file if 'syslog': write to system log;if empty no log"))
o.datatype    = "string"
o.rmempty = true
o.validate=function(self, value)
if fs.stat(value,"type")=="dir" then
	fs.rmdir(value)
end
if fs.stat(value,"type")=="dir" then
	if m.message then
	m.message =m.message.."\nerror!log file is a dir"
	else
	m.message ="error!log file is a dir"
	end
	return nil
end
return value
end
---- debug
o = s:taboption("core",Flag, "verbose", translate("Verbose log"))
o.default = 0
o.optional = true

---- IPSet Settings ----
s:tab("ipset", translate("IPSet Settings"))

o = s:taboption("ipset", Flag, "whitelist_ipset_enable", translate("Enable whitelist ipset"), translate("Like ssrplus bypass proxy domains: add DNS results to the whitelist ipset through AdGuardHome dns.ipset. The whitelist ipset has the highest proxy priority."))
o.default = 0
o.optional = true

o = s:taboption("ipset", Value, "whitelist_ipset_name", translate("Whitelist ipset name"), translate("Only letters, numbers, underscore, dash and dot are allowed"))
o.default = "whitelist"
o.datatype = "string"
o.optional = false
o:depends("whitelist_ipset_enable", "1")
o.validate=function(self, value)
	if not value or value == "" or value:match("[^A-Za-z0-9_.%-]") then
		if m.message then
			m.message = m.message .. "\nerror! whitelist ipset name is invalid"
		else
			m.message = "error! whitelist ipset name is invalid"
		end
		return nil
	end
	return value
end

o = s:taboption("ipset", TextValue, "whitelist_ipset_domains", translate("Whitelist ipset domains"), translate("One bypass proxy domain or rule per line. Saved directly to AdGuardHome dns.ipset. Supported forms: example.com, [/example.com/]server, /example.com/setname"))
o.rows = 8
o.wrap = "off"
o.optional = true
o:depends("whitelist_ipset_enable", "1")
o.cfgvalue = function(self, section)
	local value = uci:get("AdGuardHome", section, "whitelist_ipset_domains")
	if value and value ~= "" then
		return value
	end
	return fs.readfile("/etc/ssrplus/white.list") or ""
end
o.write = function(self, section, value)
	local normalized = value:gsub("\r\n", "\n")
	uci:set("AdGuardHome", section, "whitelist_ipset_domains", normalized)
end

---- Upstream DNS Settings ----
s:tab("upstream", translate("Upstream DNS"))

o = s:taboption("upstream", Flag, "upstream_dns_file_enable", translate("Enable upstream_dns_file"), translate("Download Loyalsoldier domain lists and generate AdGuardHome dns.upstream_dns_file for DNS split routing"))
o.default = 0
o.optional = true

o = s:taboption("upstream", Value, "upstream_dns_cn_upstream", translate("CN upstream DNS"), translate("Upstream DNS for China direct domains (space-separated, e.g. https://223.5.5.5/dns-query https://1.12.12.12/dns-query)"))
o.default = "https://223.5.5.5/dns-query https://1.12.12.12/dns-query"
o.datatype = "string"
o.optional = false
o:depends("upstream_dns_file_enable", "1")

o = s:taboption("upstream", Value, "upstream_dns_default_upstreams", translate("Default upstream DNS"), translate("Default fallback upstream DNS for non-China domains (space-separated, e.g. https://dns.cloudflare.com/dns-query https://dns.google/dns-query)"))
o.default = "https://dns.cloudflare.com/dns-query https://dns.google/dns-query"
o.datatype = "string"
o.optional = false
o:depends("upstream_dns_file_enable", "1")

local upstream_dns_custom_rules_default = "#转发.lan域名到dnsmasq\n#[/lan/]127.0.0.1:1745"
o = s:taboption("upstream", TextValue, "upstream_dns_custom_rules", translate("Custom domain upstream DNS"), translate("Specify upstream servers for particular domains. Lines are written directly to upstream_dns_file."))
o.rows = 4
o.wrap = "off"
o.optional = true
o.default = upstream_dns_custom_rules_default
o:depends("upstream_dns_file_enable", "1")
o.cfgvalue = function(self, section)
	local value = uci:get("AdGuardHome", section, "upstream_dns_custom_rules")
	if value and value ~= "" then
		return value
	end
	return upstream_dns_custom_rules_default
end
o.write = function(self, section, value)
	local normalized = value:gsub("\r\n", "\n")
	uci:set("AdGuardHome", section, "upstream_dns_custom_rules", normalized)
end

o = s:taboption("upstream", DynamicList, "upstream_dns_urls", translate("Domain list URLs"), translate("Add one domain list URL per item"))
o:value("https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt", "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt")
o:value("https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple-cn.txt", "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple-cn.txt")
o:value("https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/google-cn.txt", "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/google-cn.txt")
o.datatype = "string"
o.optional = false
o:depends("upstream_dns_file_enable", "1")

o = s:taboption("upstream", Value, "upstream_dns_file", translate("Upstream DNS file path"), translate("Generated file path for AdGuardHome dns.upstream_dns_file"))
o.default = "/etc/AdGuardHome/adguard_upstream_dns_file.txt"
o.datatype = "string"
o.optional = false
o:depends("upstream_dns_file_enable", "1")

o = s:taboption("upstream", Button, "upstream_dns_apply", translate("Generate upstream_dns_file"), translate("Download domain lists, generate file, set dns.upstream_dns_file and reload AdGuardHome. This may take a while depending on network speed."))
o.inputtitle = translate("Generate")
o:depends("upstream_dns_file_enable", "1")
o.write=function()
	luci.sys.exec("sh /usr/share/AdGuardHome/upstream_dns2adg.sh >/tmp/AdGuardHome_upstream_dns.log 2>&1")
	luci.http.redirect(luci.dispatcher.build_url("admin","services","AdGuardHome"))
end

o = s:taboption("upstream", Button, "upstream_dns_del", translate("Delete upstream_dns_file setting"), translate("Clear dns.upstream_dns_file only when it points to the custom file path"))
o.inputtitle = translate("Del")
o.write=function()
	luci.sys.exec("sh /usr/share/AdGuardHome/upstream_dns2adg.sh del >/tmp/AdGuardHome_upstream_dns.log 2>&1")
	luci.http.redirect(luci.dispatcher.build_url("admin","services","AdGuardHome"))
end

---- Other Settings ----
s:tab("other", translate("Other Config"))

---- upgrade protect
o = s:taboption("other", DynamicList,  "upprotect", translate("Keep files when system upgrade"))
o:value("$binpath",translate("core bin"))
o:value("$configpath",translate("config file"))
o:value("$logfile",translate("log file"))
o:value("$workdir/data/sessions.db",translate("sessions.db"))
o:value("$workdir/data/stats.db",translate("stats.db"))
o:value("$workdir/data/querylog.json",translate("querylog.json"))
o:value("$workdir/data/filters",translate("filters"))
o.widget = "checkbox"
o.default = nil
o.optional=true

---- backup workdir on shutdown
local workdir=uci:get("AdGuardHome","AdGuardHome","workdir") or "/etc/AdGuardHome"
o = s:taboption("other",MultiValue, "backupfile", translate("Backup workdir files when shutdown"))
o1 = s:taboption("other",Value, "backupwdpath", translate("Backup workdir path"))
local name
o:value("filters","filters")
o:value("stats.db","stats.db")
o:value("querylog.json","querylog.json")
o:value("sessions.db","sessions.db")
o1:depends ("backupfile", "filters")
o1:depends ("backupfile", "stats.db")
o1:depends ("backupfile", "querylog.json")
o1:depends ("backupfile", "sessions.db")
for name in fs.glob(workdir.."/data/*")
do
	name=fs.basename (name)
	if name~="filters" and name~="stats.db" and name~="querylog.json" and name~="sessions.db" then
		o:value(name,name)
		o1:depends ("backupfile", name)
	end
end
o.widget = "checkbox"
o.default = nil
o.optional=false
o.description=translate("Will be restore when workdir/data is empty")
----backup workdir path

o1.default     = "/etc/AdGuardHome"
o1.datatype    = "string"
o1.optional = false
o1.validate=function(self, value)
if fs.stat(value,"type")=="reg" then
	if m.message then
	m.message =m.message.."\nerror!backup dir is a file"
	else
	m.message ="error!backup dir is a file"
	end
	return nil
end
if string.sub(value,-1)=="/" then
	return string.sub(value, 1, -2)
else
	return value
end
end

---- Crontab Settings ----

o = s:taboption("other",MultiValue, "crontab", translate("Crontab task"),translate("Please change time and args in crontab"))
o:value("autohost",translate("Auto update ipv6 hosts and restart AdGuardHome"))
o:value("autoupstreamdns",translate("Auto update upstream_dns_file and restart AdGuardHome"))
o.widget = "checkbox"
o.default = nil
o.optional = false

fs.writefile("/var/run/AdG_log_pos","0")

function m.on_commit(map)
	-- Keep whitelist_ipset in dns.ipset in sync with LuCI settings.
	local whitelist_ipset_enable=uci:get("AdGuardHome","AdGuardHome","whitelist_ipset_enable")
	if whitelist_ipset_enable~="1" then
		luci.sys.call("sh /usr/share/AdGuardHome/whitelist_ipset2adg.sh del noreload >/tmp/AdGuardHome_whitelist_ipset.log 2>&1")
	else
		luci.sys.call("sh /usr/share/AdGuardHome/whitelist_ipset2adg.sh noreload >/tmp/AdGuardHome_whitelist_ipset.log 2>&1")
	end
	-- Only clean up upstream dns config when disabled (fast operation, no download)
	local upstream_dns_file_enable=uci:get("AdGuardHome","AdGuardHome","upstream_dns_file_enable")
	if upstream_dns_file_enable~="1" then
		luci.sys.call("sh /usr/share/AdGuardHome/upstream_dns2adg.sh del noreload >/tmp/AdGuardHome_upstream_dns.log 2>&1")
	end
	if (fs.access("/var/run/AdGserverdis")) then
		io.popen("/etc/init.d/AdGuardHome reload &")
		return
	end
	io.popen("/etc/init.d/AdGuardHome reload &")
end
return m
