# infra-toolkit

Infrastructure scripts and tools for Microsoft, VMware, Nutanix, storage, backup, network and Linux environments.
Everything here is generic: no customer names, domains, addresses or credentials.

## Structure

| Folder | What it holds |
|---|---|
| [`scripts/`](scripts/) | Standalone single-file scripts, organized by domain > vendor > product |
| [`tools/`](tools/) | Complete kits with an entry point, versions and releases (assessment, health-check runner ...) |
| [`modules/`](modules/) | Shared PowerShell code used by tools only |
| [`LICENSE`](LICENSE) | MIT |

## Running at a customer site

Customer networks often have no access to GitHub and no git.

- **A script:** copy the single `.ps1` file. Give the customer its hash if they ask what is being run:
  `Get-FileHash .\Script.ps1 -Algorithm SHA256`
- **A tool:** download the ZIP and its `.sha256` file from the [Releases](https://github.com/dorctl/infra-toolkit/releases)
  page, and move the ZIP through the customer's file transfer process.
- **On the server:** a file that came from the internet is blocked by Mark of the Web. Run `Unblock-File` on it,
  or `powershell.exe -ExecutionPolicy Bypass -File .\Script.ps1` where policy allows.
- **Before running:** check the `Mode` and `Network` lines in the header. Read-only scripts make no changes;
  scripts that change something support `-WhatIf` and write a transcript.
- **Outputs** go to `%USERPROFILE%\InfraToolkit-Output` or `%TEMP%` by default: never inside this repository
  and never inside a synced folder.

## Security

**This repository is public.** Scripts only, all generic. Credentials, license keys, keytabs, private keys,
connection manager exports, VPN profiles and customer data never go in here.

- Every push is checked: gitleaks secret and customer-data scan (rules in `.gitleaks.toml`), commit email check,
  PSScriptAnalyzer and the Pester tests.
- GitHub secret scanning with push protection is enabled.
- `main` is protected: no force push or deletion, and a commit reaches it only after the checks passed.

## Tools

<!-- TOOLS:START -->
_No tools yet._
<!-- TOOLS:END -->

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [scripts/backup/veeam/Invoke-VeeamRescan.ps1](scripts/backup/veeam/Invoke-VeeamRescan.ps1) | Rescans Veeam Backup & Replication managed servers and backup repositories, all of them or the ones named. | Changes: runs a rescan of managed servers and repositories | not yet |
| [scripts/endpoint/windows/Add-DnsServerToActiveAdapters.ps1](scripts/endpoint/windows/Add-DnsServerToActiveAdapters.ps1) | Reports the DNS servers of every active network adapter and adds a DNS server where it is missing (-Fix). | Read-only (changes with -Fix) | not yet |
| [scripts/endpoint/windows/Export-HardwareInventory.ps1](scripts/endpoint/windows/Export-HardwareInventory.ps1) | Adds or updates the hardware of Windows computers (model, serial, CPU, RAM, IP, monitors) in a CSV inventory. | Read-only | not yet |
| [scripts/endpoint/windows/Repair-PhantomKeyboardLayout.ps1](scripts/endpoint/windows/Repair-PhantomKeyboardLayout.ps1) | Finds keyboard layouts in the input switcher that are not in the user language list. Removes them with -Fix. | Read-only (changes with -Fix) | not yet |
| [scripts/microsoft/dns/Test-KSK2024Readiness.ps1](scripts/microsoft/dns/Test-KSK2024Readiness.ps1) | Read-only readiness check for the DNSSEC Root KSK rollover to KSK-2024 (key tag 38696) | Read-only | not yet |
| [scripts/microsoft/exchange/Clear-ExchangeLogFiles.ps1](scripts/microsoft/exchange/Clear-ExchangeLogFiles.ps1) | Reports Exchange and IIS log files older than a retention period, and deletes them with -Fix. | Read-only (changes with -Fix) | not yet |
| [scripts/microsoft/exchange/Set-ExchangeVirtualDirectoryUrls.ps1](scripts/microsoft/exchange/Set-ExchangeVirtualDirectoryUrls.ps1) | Checks Exchange virtual directory, Autodiscover and Outlook Anywhere URLs for a namespace, sets them with -Fix. | Read-only (changes with -Fix) | not yet |
| [scripts/microsoft/windows-server/Test-SchannelHardening.ps1](scripts/microsoft/windows-server/Test-SchannelHardening.ps1) | Checks TLS hardening: SCHANNEL protocols, ciphers, DH key size and .NET strong crypto. Fixes with -Fix. | Read-only (changes with -Fix) | not yet |
| [scripts/misc/Copy-FolderWithRobocopy.ps1](scripts/misc/Copy-FolderWithRobocopy.ps1) | Copies a folder with robocopy after a confirmation, with a timestamped log. -WhatIf lists what would be copied. | Changes the destination folder (copies files into it) | not yet |
| [scripts/misc/Export-RemoteTlsCertificate.ps1](scripts/misc/Export-RemoteTlsCertificate.ps1) | Connects to a TLS service (host and port) and exports the certificate it presents to a .cer file. | Read-only | not yet |
| [scripts/misc/Watch-HostPing.ps1](scripts/misc/Watch-HostPing.ps1) | Pings a host continuously, logs every reply with a timestamp to the screen and a file, and ends with a summary. | Read-only | not yet |
| [scripts/virtualization/kvm/Install-VirtIOBootDriver.ps1](scripts/virtualization/kvm/Install-VirtIOBootDriver.ps1) | Checks and installs the VirtIO drivers a Windows VM needs before migration to KVM: vioscsi and viostor as boot drivers, NetKVM staged. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->

## License

[MIT](LICENSE). Provided as is, without warranty: review a script and test it with `-WhatIf` before running it
in a production environment.
