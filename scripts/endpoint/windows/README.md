# Windows clients

Windows 10 / 11: fixes, registry tweaks, user profiles, client-side GPO results, Windows Update on clients.

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [Add-DnsServerToActiveAdapters.ps1](Add-DnsServerToActiveAdapters.ps1) | Reports the DNS servers of every active network adapter and adds a DNS server where it is missing (-Fix). | Read-only (changes with -Fix) | not yet |
| [Export-HardwareInventory.ps1](Export-HardwareInventory.ps1) | Adds or updates the hardware of Windows computers (model, serial, CPU, RAM, IP, monitors) in a CSV inventory. | Read-only | not yet |
| [Repair-PhantomKeyboardLayout.ps1](Repair-PhantomKeyboardLayout.ps1) | Finds keyboard layouts in the input switcher that are not in the user language list. Removes them with -Fix. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->
