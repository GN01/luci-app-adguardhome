# luci-app-adguardhome

修改自 sirpdboy 的版本：

https://github.com/sirpdboy/luci-app-adguardhome

## 用法

### 分支说明

- `main` 分支：适配 QWRT 18.06 / QWRT 25.12，已测试，QWRT 仍使用 `.ipk` 包格式

### GitHub Actions 自动构建

`main` 分支内置 `Build and Release` 工作流，会构建并发布 `.ipk` 包：

- `.ipk`：默认使用 OpenWrt `24.10.7` SDK

发布方式：

- 推送 `v*` 标签会自动构建并创建 GitHub Release
- 也可以在 GitHub Actions 页面手动运行工作流，并按需修改 OpenWrt 版本、target、subtarget 和 Release tag

### upstream_dns_file

在 LuCI 的 `Upstream DNS` 页面启用后，添加域名列表链接并点击生成，插件会生成 AdGuardHome 的 `dns.upstream_dns_file`。

可在“指定特定域名上游服务器”输入框中添加需要固定上游的域名规则，内容会原样写入 `upstream_dns_file`。默认示例：

```text
#转发.lan域名到dnsmasq
#[/lan/]127.0.0.1:1745
```

默认域名列表链接：

- `https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt`
- `https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple-cn.txt`
- `https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/google-cn.txt`

默认国内上游 DNS：

`https://223.5.5.5/dns-query https://1.12.12.12/dns-query`

默认非国内上游 DNS：

`https://dns.cloudflare.com/dns-query https://dns.google/dns-query`

### whitelist_ipset

在 LuCI 的 `IPSet Settings` 页面启用后，填写需要不走代理的域名列表并保存，插件会直接写入 AdGuardHome 的 `dns.ipset`。

- 默认 ipset 名称：`whitelist`
- 默认域名列表：如果本插件未保存域名，且 `/etc/ssrplus/white.list` 存在，则使用该文件内容
- ipset 类型：`hash:net`
- ipset timeout：`86400`
- 启动时如果 whitelist ipset 已存在则复用，不存在时创建
- 支持每行一个域名或规则，例如：`example.com`、`[/example.com/]server`、`/example.com/setname`
