# Custom ipset_file Design

## Goal

Add a generic AdGuardHome `ipset_file` workflow for users who maintain large domain sets and want to bind them to a custom ipset name. The new workflow must not modify `upstream_dns_file`, because users may already use that file for DNS split-routing.

## Existing Behavior

The current GFW controls are dedicated helpers:

- `Add gfwlist` downloads gfwlist, converts domains to `[/domain/]upstream` entries, and inserts them directly into `dns.upstream_dns` in `AdGuardHome.yaml`.
- `Del gfwlist` removes the generated `programaddstart` to `programaddend` block from `dns.upstream_dns`.
- `Add gfwlist (ipset only)` downloads gfwlist, generates `/etc/AdGuardHome/ipset.txt`, writes `dns.ipset_file: /etc/AdGuardHome/ipset.txt`, and hard-codes the ipset name to `gfwlist`.
- `Del gfwlist (ipset only)` clears `dns.ipset_file`; it does not delete the generated file or destroy the kernel ipset.
- `Gfwlist upstream dns server` is used by the `Add gfwlist` upstream generation path. It is mostly irrelevant to the current `ipset only` path because the `upstream_dns_file` update is commented out.

## Scope

Implement a separate custom `ipset_file` feature while leaving the existing GFW buttons available. The custom feature manages one generated ipset file at a configurable path and one user-defined ipset set name.

Out of scope:

- Changing the user's `upstream_dns_file`.
- Rewriting the manual YAML editor.
- Removing or redesigning the existing GFW buttons.
- Supporting multiple independent custom ipset groups in the first version.

## LuCI Fields

Add a new section under `Other Config`:

- `custom_ipset_enable`: flag to enable or disable the generated custom ipset file.
- `custom_ipset_name`: ipset set name. Default: `adguardhome`.
- `custom_ipset_file`: output path. Default: `/etc/AdGuardHome/custom_ipset.txt`.
- `custom_ipset_domains`: textarea for manually entered domains or rules.
- `custom_ipset_urls`: dynamic list or textarea for URL sources.

The UI should explain through field descriptions that the generated file uses AdGuardHome `ipset_file` syntax and that upstream DNS routing should stay in `upstream_dns_file`.

## Script

Add `/usr/share/AdGuardHome/custom_ipset2adg.sh`.

Actions:

- Default action: generate and enable the custom ipset file.
- `del`: clear `dns.ipset_file` only if it currently points to the configured custom file.
- `noreload`: optional second argument to skip service reload, matching existing helper scripts.

Generation flow:

1. Read UCI values from `AdGuardHome.AdGuardHome`.
2. Validate `custom_ipset_name` with a conservative pattern: letters, numbers, underscore, dash, and dot.
3. Read `custom_ipset_domains`.
4. Download each URL from `custom_ipset_urls` with the same downloader style used by the existing scripts.
5. Normalize supported input forms:
   - `example.com`
   - `.example.com`
   - `[/example.com/]https://dns.example/dns-query`
   - `/example.com/setname`
6. Ignore blank lines, comments, wildcard-only entries, IP literals, and malformed values.
7. De-duplicate domains.
8. Write the output file as `/domain/custom_ipset_name`.
9. Ensure the output directory exists.
10. Update `dns.ipset_file` in `AdGuardHome.yaml` to the configured file path.
11. Create the kernel ipset set when the `ipset` command exists.
12. Reload AdGuardHome unless `noreload` is requested.

## Service Startup

Update the init script so startup does not only create the hard-coded `gfwlist` set. When `dns.ipset_file` points to an existing file, parse the third field from `/domain/setname` lines and create each set name with:

```sh
ipset list "$setname" >/dev/null 2>&1 || ipset create "$setname" hash:ip 2>/dev/null
```

This preserves the existing `gfwlist` behavior and makes custom set names work after reboot or reload.

## Compatibility

The new custom feature and the existing GFW ipset helper both write `dns.ipset_file`, so only one can be active at a time in AdGuardHome's YAML. The custom delete action must avoid clearing a GFW-managed `ipset_file` by checking the configured custom path first.

Existing users of `upstream_dns_file` remain unaffected.

## Testing

Repository-level checks:

- Run shell syntax checks on modified `.sh` files with `sh -n`.
- Verify Lua syntax when a Lua interpreter is available.
- Inspect generated output from representative domain inputs.

Manual OpenWrt checks:

- Save manual domains and confirm `custom_ipset_file` is generated.
- Save URL sources and confirm remote domains are included.
- Confirm `AdGuardHome.yaml` has `dns.ipset_file` pointing to the generated file.
- Restart the service and confirm the configured ipset set is created.
- Confirm `upstream_dns_file` is unchanged.
