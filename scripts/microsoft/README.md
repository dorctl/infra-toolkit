# Microsoft

Microsoft infrastructure services: Active Directory, DNS, Exchange on-premises, Windows Server, file services, PKI and Microsoft 365.

## Sub-folders

- [`active-directory/`](active-directory/) - AD DS: users, groups, computers, OUs, GPO, replication, FSMO roles, sites, trusts, Kerberos (SPN, ktpass / keytab generation scripts).
- [`dns/`](dns/) - Windows DNS Server: zones, forwarders, conditional forwarders, root hints, scavenging, DNSSEC.
- [`exchange/`](exchange/) - Exchange Server on-premises: mailboxes, databases, DAG, transport, connectors, certificates, the on-premises side of hybrid.
- [`file-services/`](file-services/) - Windows file services: SMB shares, NTFS permissions, DFS-N, DFS-R, FSRM, quotas.
- [`m365/`](m365/) - Microsoft 365 cloud services: Exchange Online, Entra ID (including Entra Connect sync), Intune, Teams, SharePoint / OneDrive, licensing.
- [`pki/`](pki/) - AD CS and certificates: certificate templates, CRL / AIA, root and intermediate certificate deployment, expiry reports.
- [`windows-server/`](windows-server/) - Windows Server OS level: roles and features, updates, services, event logs, performance, RDS, DHCP, failover clustering (non Hyper-V), server registry fixes.

## Does not go here

- Hyper-V - `virtualization/hyper-v/`
- SQL Server - `databases/mssql/`
- Azure IaaS - `cloud/azure/`
- Windows 10/11 workstations - `endpoint/windows/`

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [dns/Test-KSK2024Readiness.ps1](dns/Test-KSK2024Readiness.ps1) | Read-only readiness check for the DNSSEC Root KSK rollover to KSK-2024 (key tag 38696) | Read-only | not yet |
| [exchange/Clear-ExchangeLogFiles.ps1](exchange/Clear-ExchangeLogFiles.ps1) | Reports Exchange and IIS log files older than a retention period, and deletes them with -Fix. | Read-only (changes with -Fix) | not yet |
| [exchange/Set-ExchangeVirtualDirectoryUrls.ps1](exchange/Set-ExchangeVirtualDirectoryUrls.ps1) | Checks Exchange virtual directory, Autodiscover and Outlook Anywhere URLs for a namespace, sets them with -Fix. | Read-only (changes with -Fix) | not yet |
| [windows-server/Test-SchannelHardening.ps1](windows-server/Test-SchannelHardening.ps1) | Checks TLS hardening: SCHANNEL protocols, ciphers, DH key size and .NET strong crypto. Fixes with -Fix. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->
