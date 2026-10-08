# Windows DNS

Windows DNS Server: zones, forwarders, conditional forwarders, root hints, scavenging, DNSSEC.

## Does not go here

- DHCP - `microsoft/windows-server/` until it has enough scripts for its own folder
- BIND / Unbound - `linux/`

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [Test-KSK2024Readiness.ps1](Test-KSK2024Readiness.ps1) | Read-only readiness check for the DNSSEC Root KSK rollover to KSK-2024 (key tag 38696) | Read-only | not yet |
<!-- SCRIPTS:END -->
