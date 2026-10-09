# Endpoint

User workstations and client applications, regardless of vendor.

## Sub-folders

- [`apps/`](apps/) - Client applications: AnyDesk, Google Drive for desktop, browsers, VPN clients and other end-user software.
- [`drivers/`](drivers/) - Driver install, export, cleanup and inventory on workstations.
- [`windows/`](windows/) - Windows 10 / 11: fixes, registry tweaks, user profiles, client-side GPO results, Windows Update on clients.

## Does not go here

- Windows Server - `microsoft/windows-server/`

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [windows/Add-DnsServerToActiveAdapters.ps1](windows/Add-DnsServerToActiveAdapters.ps1) | Reports the DNS servers of every active network adapter and adds a DNS server where it is missing (-Fix). | Read-only (changes with -Fix) | not yet |
| [windows/Export-HardwareInventory.ps1](windows/Export-HardwareInventory.ps1) | Adds or updates the hardware of Windows computers (model, serial, CPU, RAM, IP, monitors) in a CSV inventory. | Read-only | not yet |
| [windows/Repair-PhantomKeyboardLayout.ps1](windows/Repair-PhantomKeyboardLayout.ps1) | Finds keyboard layouts in the input switcher that are not in the user language list. Removes them with -Fix. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->
