# Scripts

Single-file scripts, organized by **domain > vendor > product**.
Every script here is **standalone**: one file, no dependency on `modules/`, so it can be copied to a customer server on its own.

| Domain | What goes there |
|---|---|
| [`microsoft/`](microsoft/) | Active Directory, DNS, Exchange on-prem, Microsoft 365, Windows Server, file services, PKI |
| [`virtualization/`](virtualization/) | VMware (vSphere, VCF, vSAN, VxRail), Nutanix, KVM (VirtIO guests), later Hyper-V / Proxmox |
| [`storage/`](storage/) | Storage arrays, SAN fabric, NAS - one folder per vendor |
| [`backup/`](backup/) | Veeam, tape |
| [`databases/`](databases/) | SQL Server, later other engines |
| [`network/`](network/) | Switches, routers, firewalls - one folder per vendor |
| [`linux/`](linux/) | Distribution-agnostic scripts and Red Hat |
| [`endpoint/`](endpoint/) | Windows workstations, drivers, client applications |
| [`misc/`](misc/) | Generic utilities that do not belong to a product |

## All scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [backup/veeam/Invoke-VeeamRescan.ps1](backup/veeam/Invoke-VeeamRescan.ps1) | Rescans Veeam Backup & Replication managed servers and backup repositories, all of them or the ones named. | Changes: runs a rescan of managed servers and repositories | not yet |
| [endpoint/windows/Add-DnsServerToActiveAdapters.ps1](endpoint/windows/Add-DnsServerToActiveAdapters.ps1) | Reports the DNS servers of every active network adapter and adds a DNS server where it is missing (-Fix). | Read-only (changes with -Fix) | not yet |
| [endpoint/windows/Export-HardwareInventory.ps1](endpoint/windows/Export-HardwareInventory.ps1) | Adds or updates the hardware of Windows computers (model, serial, CPU, RAM, IP, monitors) in a CSV inventory. | Read-only | not yet |
| [endpoint/windows/Repair-PhantomKeyboardLayout.ps1](endpoint/windows/Repair-PhantomKeyboardLayout.ps1) | Finds keyboard layouts in the input switcher that are not in the user language list. Removes them with -Fix. | Read-only (changes with -Fix) | not yet |
| [microsoft/dns/Test-KSK2024Readiness.ps1](microsoft/dns/Test-KSK2024Readiness.ps1) | Read-only readiness check for the DNSSEC Root KSK rollover to KSK-2024 (key tag 38696) | Read-only | not yet |
| [microsoft/exchange/Clear-ExchangeLogFiles.ps1](microsoft/exchange/Clear-ExchangeLogFiles.ps1) | Reports Exchange and IIS log files older than a retention period, and deletes them with -Fix. | Read-only (changes with -Fix) | not yet |
| [microsoft/exchange/Repair-ExchangeVssWriter.ps1](microsoft/exchange/Repair-ExchangeVssWriter.ps1) | Checks the Microsoft Exchange Writer (VSS) and restarts the Microsoft Exchange Replication service with -Fix. | Read-only (changes with -Fix) | not yet |
| [microsoft/exchange/Set-ExchangeVirtualDirectoryUrls.ps1](microsoft/exchange/Set-ExchangeVirtualDirectoryUrls.ps1) | Checks Exchange virtual directory, Autodiscover and Outlook Anywhere URLs for a namespace, sets them with -Fix. | Read-only (changes with -Fix) | not yet |
| [microsoft/windows-server/Test-SchannelHardening.ps1](microsoft/windows-server/Test-SchannelHardening.ps1) | Checks TLS hardening: SCHANNEL protocols, ciphers, DH key size and .NET strong crypto. Fixes with -Fix. | Read-only (changes with -Fix) | not yet |
| [misc/Copy-FolderWithRobocopy.ps1](misc/Copy-FolderWithRobocopy.ps1) | Copies a folder with robocopy after a confirmation, with a timestamped log. -WhatIf lists what would be copied. | Changes the destination folder (copies files into it) | not yet |
| [misc/Export-RemoteTlsCertificate.ps1](misc/Export-RemoteTlsCertificate.ps1) | Connects to a TLS service (host and port) and exports the certificate it presents to a .cer file. | Read-only | not yet |
| [misc/Watch-HostPing.ps1](misc/Watch-HostPing.ps1) | Pings a host continuously, logs every reply with a timestamp to the screen and a file, and ends with a summary. | Read-only | not yet |
| [virtualization/kvm/Install-VirtIOBootDriver.ps1](virtualization/kvm/Install-VirtIOBootDriver.ps1) | Checks and installs the VirtIO drivers a Windows VM needs before migration to KVM: vioscsi and viostor as boot drivers, NetKVM staged. | Read-only (changes with -Fix) | not yet |
| [virtualization/vmware/vxrail/get-vxrail-upgrade-info.sh](virtualization/vmware/vxrail/get-vxrail-upgrade-info.sh) | Shows if a VxRail cluster has an external or embedded vCenter, and its component versions, before an upgrade. | Read-only | not yet |
<!-- SCRIPTS:END -->
