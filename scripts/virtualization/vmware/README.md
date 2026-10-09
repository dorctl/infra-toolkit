# VMware

VMware by Broadcom stack, one folder per product. Add `nsx/`, `aria/` and others when the first script arrives.

## Sub-folders

- [`vcf/`](vcf/) - VCF: SDDC Manager, workload domains, lifecycle (bundles, upgrades), certificates, passwords rotation.
- [`vsan/`](vsan/) - vSAN: health, capacity, storage policies, resync, disk groups / ESA.
- [`vsphere/`](vsphere/) - vCenter and ESXi: PowerCLI inventory, VM operations, host configuration, snapshots, networking (vDS), alarms.
- [`vxrail/`](vxrail/) - Dell VxRail: VxRail Manager API, upgrades, node add / remove, hardware health.

## Scripts

<!-- SCRIPTS:START -->
| Script | Description | Mode | Verified |
|---|---|---|---|
| [vxrail/get-vxrail-upgrade-info.sh](vxrail/get-vxrail-upgrade-info.sh) | Shows if a VxRail cluster has an external or embedded vCenter, and its component versions, before an upgrade. | Read-only | not yet |
<!-- SCRIPTS:END -->
