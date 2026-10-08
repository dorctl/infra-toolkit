# Modules

Shared PowerShell code used by the **tools** in [`tools/`](../tools/).

## Rules

- Only tools import modules. Scripts in `scripts/` stay standalone so a single file can be copied to a customer server.
- A function moves here when the same code is copied into a third tool
  (typical candidates: logging, verdict output, HTML / Excel export, connecting to vCenter or Prism).
- Every tool release bundles the module it uses, so the ZIP runs on its own.
- Same field rules as everything else: Windows PowerShell 5.1 compatible, ASCII or UTF-8 with BOM, no secrets.

## Layout

The module is created with its first function:

```
modules/InfraToolkit/
|-- InfraToolkit.psd1     manifest (version, exported functions)
|-- InfraToolkit.psm1     loads Public/ and Private/
|-- Public/               one exported function per file
`-- Private/              internal helpers
```
