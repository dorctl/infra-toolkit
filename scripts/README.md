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
| [microsoft/dns/Test-KSK2024Readiness.ps1](microsoft/dns/Test-KSK2024Readiness.ps1) | Read-only readiness check for the DNSSEC Root KSK rollover to KSK-2024 (key tag 38696) | Read-only | not yet |
| [virtualization/kvm/Install-VirtIOBootDriver.ps1](virtualization/kvm/Install-VirtIOBootDriver.ps1) | Checks and installs the VirtIO drivers a Windows VM needs before migration to KVM: vioscsi and viostor as boot drivers, NetKVM staged. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->
