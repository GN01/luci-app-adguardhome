# luci-app-adguardhome

OpenWrt 上的 AdGuardHome LuCI 支持插件。

## 说明

本项目修改自 sirpdboy 的版本：

https://github.com/sirpdboy/luci-app-adguardhome

## 软件包

- 软件包名称：`luci-app-adguardhome`
- 版本：`1.0.0`

## 功能说明

### upstream_dns_file

`upstream_dns_file` 用于生成 AdGuardHome 的 `dns.upstream_dns_file` 配置文件，实现按域名列表进行 DNS 分流。

- 默认下载 Loyalsoldier 的域名列表：`direct-list.txt`、`apple-cn.txt`、`google-cn.txt`
- 国内直连域名默认使用：`https://223.5.5.5/dns-query https://1.12.12.12/dns-query`
- 非国内域名默认使用：`https://dns.cloudflare.com/dns-query https://dns.google/dns-query`
- 默认生成文件：`/etc/AdGuardHome/adguard_upstream_dns_file.txt`
- 生成后会写入 AdGuardHome 配置中的 `dns.upstream_dns_file`

可在 LuCI 的 `Upstream DNS` 页面启用、调整下载源和上游 DNS，并点击生成。

### whitelist_ipset

`whitelist_ipset` 功能类似 ssrplus 的“不走代理的域名”：将指定域名的解析结果添加到名为 `whitelist` 的 ipset 中。

- 默认 ipset 名称：`whitelist`
- 保存后会直接写入 AdGuardHome 配置中的 `dns.ipset`
- 不再使用 `dns.ipset_file`，避免文件不存在导致 AdGuardHome 启动失败
- `whitelist` 是代理规则中的最高优先级，适合放置需要强制不走代理的域名
- 支持每行一个域名或规则，例如：`example.com`、`[/example.com/]server`、`/example.com/setname`

可在 LuCI 的 `IPSet Settings` 页面启用并维护域名列表。

## 许可

本项目沿用原项目许可。
