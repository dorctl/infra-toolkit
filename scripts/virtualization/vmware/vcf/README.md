# VMware Cloud Foundation

VCF: SDDC Manager, workload domains, lifecycle (bundles, upgrades), certificates, passwords rotation.

## Scripts

<!-- SCRIPTS:START -->
_No scripts yet._
<!-- SCRIPTS:END -->

## Official tools

Vendor and community tools that are not kept in this repository. Download the current version from the source.

| Tool | Use it for | Source |
|---|---|---|
| fixHostKeys.py, fix_known_hosts.sh | Fix SDDC Manager SSH host key mismatches after a node rebuild or restore | [Broadcom KB 316028](https://knowledge.broadcom.com/external/article/316028) |
| clean_tasks.sh | Clear stale bundle tasks after an SDDC Manager recovery | [Broadcom KB 395842](https://knowledge.broadcom.com/external/article/395842) |
| Remove a failed workflow | Delete a failed SDDC Manager task (the documented procedure) | [Broadcom KB 343400](https://knowledge.broadcom.com/external/article/343400) |
| VCFFailedTaskCleanup.ps1 | Delete all failed SDDC Manager tasks at once (community, needs PowerVCF, which is archived) | [GitHub: LifeOfBrianOC](https://github.com/LifeOfBrianOC/VCFFailedTaskCleanup.ps1) |
| vcf-automated-lab-deployment | Deploy a nested VCF 5.x lab with PowerCLI (William Lam) | [GitHub: lamw](https://github.com/lamw/vcf-automated-lab-deployment) |
| vcf-fleet-automated-lab-deployment | Deploy a nested VCF 9.x lab with PowerCLI (William Lam) | [GitHub: lamw](https://github.com/lamw/vcf-fleet-automated-lab-deployment) |
