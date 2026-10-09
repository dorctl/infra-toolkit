# Virtualization

Hypervisors and HCI platforms, one folder per vendor (`vmware/`, `nutanix/`, later `hyper-v/`, `proxmox/` ...).

## Sub-folders

- [`kvm/`](kvm/) - KVM based platforms (HPE Morpheus VM Essentials, Proxmox VE, OpenStack): Windows guests with the VirtIO drivers, preparation before migration.
- [`nutanix/`](nutanix/) - Nutanix AHV / Prism: Prism Central and Element API, ncli / acli, LCM, cluster health.
- [`vmware/`](vmware/) - VMware by Broadcom stack, one folder per product. Add `nsx/`, `aria/` and others when the first script arrives.

## Does not go here

- Backup of VMs - `backup/`
- Storage arrays behind the hosts - `storage/`

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [kvm/Install-VirtIOBootDriver.ps1](kvm/Install-VirtIOBootDriver.ps1) | Checks and installs the VirtIO drivers a Windows VM needs before migration to KVM: vioscsi and viostor as boot drivers, NetKVM staged. | Read-only (changes with -Fix) | not yet |
| [vmware/vxrail/get-vxrail-upgrade-info.sh](vmware/vxrail/get-vxrail-upgrade-info.sh) | Shows if a VxRail cluster has an external or embedded vCenter, and its component versions, before an upgrade. | Read-only | not yet |
<!-- SCRIPTS:END -->
