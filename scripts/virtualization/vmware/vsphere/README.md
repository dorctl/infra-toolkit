# vSphere

vCenter and ESXi: PowerCLI inventory, VM operations, host configuration, snapshots, networking (vDS), alarms.

## Does not go here

- vSAN - `../vsan/`
- VCF lifecycle - `../vcf/`

## Scripts

<!-- SCRIPTS:START -->
_No scripts yet._
<!-- SCRIPTS:END -->

## Official tools

Vendor and community tools that are not kept in this repository. Download the current version from the source.

| Tool | Use it for | Source |
|---|---|---|
| vCert | Check, replace and clean up vCenter certificates, including STS and BACKUP_STORE | [Broadcom KB 385107](https://knowledge.broadcom.com/external/article/385107) |
| lsdoctor | Find and fix Lookup Service registration problems in vCenter | [Broadcom KB 320837](https://knowledge.broadcom.com/external/article/320837) |

vCert replaces the older checksts.py ([KB 318968](https://knowledge.broadcom.com/external/article/318968)) and the BACKUP_STORE cleanup script ([KB 326268](https://knowledge.broadcom.com/external/article/326268)), which Broadcom removed from those articles.
