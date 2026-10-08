# Tools

Complete kits with a life cycle of their own: several files, an entry point, versions and releases.

## Tool or script?

It is a **tool** when at least two of these are true:

- It has more than one file (code plus config, templates or assets).
- It runs other scripts, or covers more than one product.
- It produces a rich output (HTML / Excel report, menu).
- It is used again and again across customers and evolves in versions.

Anything else is a script and goes to [`scripts/`](../scripts/).
A tool always lives here, even when it serves a single product; the product goes in its name
(`nutanix-upgrade-precheck/`). The folder stays flat: one folder per tool.

## Layout of a tool

```
tools/<tool-name>/
|-- README.md                  what it does, requirements, how to run, sample output, network access
|-- CHANGELOG.md               "## 1.2.0 - YYYY-MM-DD" headings, newest first
|-- Invoke-<ToolName>.ps1      the single entry point
|-- config/
|   `-- settings.example.json  only examples are committed, real config stays local
`-- src/                       internal functions
```

A tool may use the shared module in [`modules/`](../modules/). Load it so it works both in the repository
and from a release ZIP:

```powershell
$mod = Join-Path $PSScriptRoot 'modules/InfraToolkit'
if (-not (Test-Path $mod)) { $mod = Join-Path $PSScriptRoot '../../modules/InfraToolkit' }
Import-Module $mod -Force
```

## Releases

Every tool version is published on the [Releases](https://github.com/dorctl/infra-toolkit/releases) page
(tag `<tool-name>/v<version>`): a ZIP with the shared module bundled in, and a `.sha256` file next to it.
Take the ZIP to the customer site. See [Running at a customer site](../README.md#running-at-a-customer-site).

## Tools

<!-- TOOLS:START -->
_No tools yet._
<!-- TOOLS:END -->
