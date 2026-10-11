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

## Official tools

Vendor and community tools that are not kept in this repository. Download the current version from the source.

| Tool | Use it for | Source |
|---|---|---|
| IIS Crypto | Set SCHANNEL protocols, ciphers and cipher suite order from templates (GUI and CLI) | [Nartac Software](https://www.nartac.com/Products/IISCrypto) |
| Reg2GPO | Convert a .reg file into Group Policy Preferences registry XML | [Blog post by Malcolm McCaffery](https://chentiangemalc.wordpress.com/2014/07/02/importing-reg-files-into-group-policy-preferences/) |
