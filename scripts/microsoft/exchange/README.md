# Exchange Server (on-premises)

Exchange Server on-premises: mailboxes, databases, DAG, transport, connectors, certificates, the on-premises side of hybrid.

## Does not go here

- Exchange Online - `microsoft/m365/`

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [Clear-ExchangeLogFiles.ps1](Clear-ExchangeLogFiles.ps1) | Reports Exchange and IIS log files older than a retention period, and deletes them with -Fix. | Read-only (changes with -Fix) | not yet |
| [Repair-ExchangeVssWriter.ps1](Repair-ExchangeVssWriter.ps1) | Checks the Microsoft Exchange Writer (VSS) and restarts the Microsoft Exchange Replication service with -Fix. | Read-only (changes with -Fix) | not yet |
| [Set-ExchangeVirtualDirectoryUrls.ps1](Set-ExchangeVirtualDirectoryUrls.ps1) | Checks Exchange virtual directory, Autodiscover and Outlook Anywhere URLs for a namespace, sets them with -Fix. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->
