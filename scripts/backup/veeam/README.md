# Veeam

Veeam Backup & Replication: jobs, repositories, SureBackup, proxies, reports, configuration backup.

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [Invoke-VeeamRescan.ps1](Invoke-VeeamRescan.ps1) | Rescans Veeam Backup & Replication managed servers and backup repositories, all of them or the ones named. | Changes: runs a rescan of managed servers and repositories | not yet |
<!-- SCRIPTS:END -->

## Official tools

Vendor and community tools that are not kept in this repository. Download the current version from the source.

| Tool | Use it for | Source |
|---|---|---|
| RegisterVBRGuestAgentComponentsSPNs | Register guest agent SPNs after an upgrade to VBR 12 in a Kerberos-only domain | [Veeam KB4393](https://www.veeam.com/kb4393) |
| Security & Compliance Analyzer script | Apply the Security & Compliance Analyzer recommendations on a Windows backup server (disables RDP, WinRM and more: read it first) | [Veeam KB4525](https://www.veeam.com/kb4525) |
| DB2 pre-freeze / post-thaw (Windows) | Suspend DB2 writes during a Veeam snapshot for a consistent backup | [VeeamHub/applications](https://github.com/VeeamHub/applications/tree/master/Freeze-Thaw%20Examples/db2/windows) (community) |
