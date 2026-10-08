# KVM

KVM based platforms (HPE Morpheus VM Essentials, Proxmox VE, OpenStack and others): Windows guests with the
upstream VirtIO drivers (virtio-win), preparation before a migration from VMware or Hyper-V.

## Does not go here

- Nutanix AHV (KVM based, with its own VirtIO package and tools) - `../nutanix/`

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [Install-VirtIOBootDriver.ps1](Install-VirtIOBootDriver.ps1) | Checks and installs the VirtIO drivers a Windows VM needs before migration to KVM: vioscsi and viostor as boot drivers, NetKVM staged. | Read-only (changes with -Fix) | not yet |
<!-- SCRIPTS:END -->
