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
| [windows/Repair-PhantomKeyboardLayout.ps1](windows/Repair-PhantomKeyboardLayout.ps1) | Finds keyboard layouts in the input switcher that are not in the user language list. Removes them with -Fix. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->
