# File Services

Windows file services: SMB shares, NTFS permissions, DFS-N, DFS-R, FSRM, quotas.

## Does not go here

- NAS / storage arrays - `storage/`

## Scripts

<!-- SCRIPTS:START -->
_No scripts yet._
<!-- SCRIPTS:END -->

## Official tools

Vendor and community tools that are not kept in this repository. Download the current version from the source.

| Tool | Use it for | Source |
|---|---|---|
| Import-FSRMQuota | Copy FSRM quota templates and folder quotas from another server | [PowerShell Gallery](https://www.powershellgallery.com/packages/Import-FSRMQuota) (Sam Boutros) |
| fsrm-quotas-backup | Back up FSRM quotas and recreate them on a new server | [GitHub: monosoul/fsrm-quotas-backup](https://github.com/monosoul/fsrm-quotas-backup) |

Both use `dirquota`, which is deprecated in favor of the FileServerResourceManager PowerShell module.
