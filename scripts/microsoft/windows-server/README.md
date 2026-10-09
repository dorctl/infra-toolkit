# Windows Server

Windows Server OS level: roles and features, updates, services, event logs, performance, RDS, DHCP, failover clustering (non Hyper-V), server registry fixes.

## Does not go here

- Hyper-V - `virtualization/hyper-v/`
- File shares and DFS - `microsoft/file-services/`
- Workstation fixes - `endpoint/windows/`

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [Test-SchannelHardening.ps1](Test-SchannelHardening.ps1) | Checks TLS hardening: SCHANNEL protocols, ciphers, DH key size and .NET strong crypto. Fixes with -Fix. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->
