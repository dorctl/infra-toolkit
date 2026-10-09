#Requires -Version 5.1

<#
.SYNOPSIS
    Checks TLS hardening: SCHANNEL protocols, ciphers, DH key size and .NET strong crypto. Fixes with -Fix.

.DESCRIPTION
    Compares the SCHANNEL and .NET Framework registry settings of the local computer with the
    Microsoft TLS guidance: legacy protocols off, weak ciphers off, Diffie-Hellman keys of at least
    2048 bits, and .NET Framework applications that use strong crypto and the OS TLS defaults.

    SCHANNEL (HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL):
      Protocols     SSL 2.0, SSL 3.0, TLS 1.0, TLS 1.1, PCT 1.0, Multi-Protocol Unified Hello:
                    Enabled = 0 and DisabledByDefault = 1, under Server and under Client.
                    TLS 1.2: must not be disabled: Enabled missing or not 0, DisabledByDefault
                    missing or 0. Missing keys are OK (on by default).
                    TLS 1.3: listed when configured, not checked and not changed.
      Ciphers       DES 56/56, NULL, RC2 40/128, RC2 56/128, RC2 128/128, RC4 40/128, RC4 56/128,
                    RC4 64/128, RC4 128/128, Triple DES 168: Enabled = 0.
                    AES 128/128, AES 256/256: must not be disabled. Missing keys are OK.
      Key exchange  KeyExchangeAlgorithms\Diffie-Hellman: ServerMinKeyBitLength >= 2048.
                    Missing counts as action required: older systems default to 1024 bits.

    The .NET Framework (strong crypto and OS TLS defaults for .NET applications):
      SchUseStrongCrypto = 1 and SystemDefaultTlsVersions = 1 under
      HKLM\SOFTWARE\Microsoft\.NETFramework\v4.0.30319 and \v2.0.50727, in the 64-bit view and in the
      32-bit view (WOW6432Node). A v2.0.50727 key or a WOW6432Node key that does not exist is N/A:
      that .NET version or the 32-bit view is not installed, and -Fix does not create it.

    Not checked: hashes (MD5, SHA ...) and the cipher suite order. Manage the cipher suite order with
    Group Policy or Disable-TlsCipherSuite.

    Without -Fix the script only reports. With -Fix it first exports the SCHANNEL key and the .NET
    Framework keys to .reg files in the output folder, then writes the expected DWORD values
    (one confirmation per item) and checks again. -WhatIf shows the changes without making them.
    Every run with -Fix writes a transcript. SCHANNEL reads its settings at startup: restart the
    computer after the changes.

    Before -Fix: with TLS 1.0 and TLS 1.1 off, the computer cannot connect to or accept connections
    from systems that support nothing newer (old SQL Server clients and drivers, old Java
    applications, embedded devices ...). On a server that must still connect to such systems as a
    client, use -AllowLegacyClientTls.

    Registry access goes through reg.exe (query, add, export). Cipher key names contain '/', which the
    PowerShell registry provider treats as a path separator. reg.exe takes the names as they are and
    needs no .NET method calls, so the check also runs in Constrained Language Mode.

    Requirements: Windows Server 2012 R2 or later, Windows 10 or 11, 64-bit PowerShell.
    Reading needs no administrator rights. -Fix needs an elevated session.

.PARAMETER AllowLegacyClientTls
    Do not check or change the TLS 1.0 and TLS 1.1 Client keys, for a server that must still connect to
    systems that support only TLS 1.0 or 1.1. The Server keys of these protocols are still checked.

.PARAMETER Fix
    Back up the keys and write the expected values. Without it the script is read-only.

.PARAMETER OutputPath
    Folder for the CSV report, the .reg backups and the transcript.
    Default: InfraToolkit-Output\Test-SchannelHardening\<timestamp> in the folder of the script
    (falls back to %TEMP%\InfraToolkit-Output\Test-SchannelHardening\<timestamp> when that folder cannot be
    written or is in OneDrive).

.EXAMPLE
    .\Test-SchannelHardening.ps1
    Report only.

.EXAMPLE
    .\Test-SchannelHardening.ps1 -Fix -WhatIf
    Show what would change.

.EXAMPLE
    .\Test-SchannelHardening.ps1 -Fix
    Back up the keys and apply the baseline. Asks before each item; add -Confirm:$false to skip.

.EXAMPLE
    .\Test-SchannelHardening.ps1 -Fix -AllowLegacyClientTls
    Apply the baseline but keep TLS 1.0 and TLS 1.1 available for outgoing connections.

.NOTES
    Mode: Read-only (changes with -Fix)
    Network: none
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = compliant (or all fixed), 1 = action required, 2 = some changes failed,
                3 = the script could not run.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$AllowLegacyClientTls,

    [switch]$Fix,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ baseline
$SchannelKey     = 'HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL'
$LegacyProtocols = @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'PCT 1.0', 'Multi-Protocol Unified Hello')
$LegacyClientTls = @('TLS 1.0', 'TLS 1.1')
$WeakCiphers     = @('DES 56/56', 'NULL', 'RC2 40/128', 'RC2 56/128', 'RC2 128/128',
                     'RC4 40/128', 'RC4 56/128', 'RC4 64/128', 'RC4 128/128', 'Triple DES 168')
$StrongCiphers   = @('AES 128/128', 'AES 256/256')
$MinDhBits       = 2048
$CipherOn        = 4294967295    # 0xffffffff, the value Microsoft documents to enable a cipher
$DotNetKeys = @(
    [pscustomobject]@{ Item = 'v4.0.30319 (64-bit)'; Key = 'HKLM\SOFTWARE\Microsoft\.NETFramework\v4.0.30319';             Optional = $false }
    [pscustomobject]@{ Item = 'v4.0.30319 (32-bit)'; Key = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'; Optional = $true }
    [pscustomobject]@{ Item = 'v2.0.50727 (64-bit)'; Key = 'HKLM\SOFTWARE\Microsoft\.NETFramework\v2.0.50727';             Optional = $true }
    [pscustomobject]@{ Item = 'v2.0.50727 (32-bit)'; Key = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v2.0.50727'; Optional = $true }
)

$EXIT_OK      = 0
$EXIT_ACTION  = 1
$EXIT_FAILED  = 2
$EXIT_NOT_RUN = 3

$script:ExitCode = $EXIT_NOT_RUN

# ------------------------------------------------------------------ output helpers
function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Format-Dword {
    param($Value)
    if ($Value -is [int64] -and $Value -gt 65535) { return ('0x{0:x8}' -f $Value) }
    return [string]$Value
}

function Get-OutputFolder {
    # Default output folder: InfraToolkit-Output\<script name> next to the script file.
    # Falls back to %TEMP%\InfraToolkit-Output\<script name> when the script was not run from a file,
    # when its folder is inside OneDrive (outputs must not be synced), or when that folder cannot be written.
    # Its write test always runs, also under -WhatIf and -Confirm.
    param([string]$ScriptRoot, [string]$ScriptName)

    $candidates = @()
    if ($ScriptRoot) {
        $root = $ScriptRoot.TrimEnd('\', '/').ToLowerInvariant()
        $synced = $false
        foreach ($s in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
            if (-not $s) { continue }
            $sync = $s.TrimEnd('\', '/').ToLowerInvariant()
            if ($root -eq $sync -or $root.StartsWith($sync + '\') -or $root.StartsWith($sync + '/')) { $synced = $true }
        }
        if ($synced) {
            Write-Warning ('The script folder is inside OneDrive. Output goes to the TEMP folder instead: {0}' -f $ScriptRoot)
        } else {
            $candidates += Join-Path (Join-Path $ScriptRoot 'InfraToolkit-Output') $ScriptName
        }
    }
    $temp = $env:TEMP
    if (-not $temp) { $temp = $env:TMPDIR }
    if (-not $temp) { $temp = '/tmp' }
    $candidates += Join-Path (Join-Path $temp 'InfraToolkit-Output') $ScriptName

    foreach ($c in $candidates) {
        try {
            New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false | Out-Null
            $probe = Join-Path $c ('.write-test-{0}' -f (Get-Random))
            Set-Content -LiteralPath $probe -Value '' -ErrorAction Stop -WhatIf:$false -Confirm:$false
            Remove-Item -LiteralPath $probe -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
            return $c
        } catch {
            Write-Verbose ('Cannot write to {0}: {1}' -f $c, $_.Exception.Message)
        }
    }
    throw ('No writable output folder. Tried: {0}. Give a folder with the output path parameter of the script.' -f ($candidates -join '; '))
}

# ------------------------------------------------------------------ registry through reg.exe
# reg.exe instead of the registry provider: cipher key names contain '/' ('RC4 128/128'), which
# New-Item and Get-ItemProperty split into two keys. The .NET RegistryKey methods would handle it,
# but method calls on RegistryKey objects are blocked in Constrained Language Mode.

function ConvertFrom-Hex {
    param([string]$Hex)
    [int64]$n = 0
    foreach ($c in $Hex.ToLowerInvariant().ToCharArray()) { $n = $n * 16 + '0123456789abcdef'.IndexOf([string]$c) }
    return $n
}

function Get-RegKeyValue {
    # Values of a key as a hashtable (REG_DWORD as [int64], other types as text), $null when the key does not exist
    param([string]$Key)
    # Windows PowerShell 5.1 turns redirected stderr into a terminating error under 'Stop'
    $ErrorActionPreference = 'Continue'
    $lines = @(& reg.exe query $Key 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    $values = @{}
    foreach ($l in $lines) {
        if ([string]$l -notmatch '^ {4}(.+?) {4}(REG_[A-Z_]+)(?: {4}(.*))?$') { continue }
        $name = $Matches[1]
        $type = $Matches[2]
        $data = [string]$Matches[3]
        if ($type -eq 'REG_DWORD' -and $data -match '^0x([0-9a-fA-F]{1,8})$') {
            $values[$name] = ConvertFrom-Hex $Matches[1]
        } else {
            $values[$name] = $data
        }
    }
    return $values
}

function Set-RegDword {
    param([string]$Key, [string]$Name, [int64]$Value)
    $ErrorActionPreference = 'Continue'
    $out = @(& reg.exe add $Key /v $Name /t REG_DWORD /d ('0x{0:x}' -f $Value) /f 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('reg.exe add {0} /v {1} failed (exit code {2}): {3}' -f $Key, $Name, $LASTEXITCODE,
            ((@($out | ForEach-Object { ([string]$_).Trim() }) -join ' ').Trim()))
    }
}

function Export-RegKey {
    param([string]$Key, [string]$File)
    $ErrorActionPreference = 'Continue'
    $out = @(& reg.exe export $Key $File /y 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('reg.exe export {0} failed (exit code {1}): {2}' -f $Key, $LASTEXITCODE,
            ((@($out | ForEach-Object { ([string]$_).Trim() }) -join ' ').Trim()))
    }
}

# ------------------------------------------------------------------ environment
function Test-Elevated {
    # High (S-1-16-12288) or System (S-1-16-16384) integrity level = elevated
    $ErrorActionPreference = 'Continue'
    $groups = @(& whoami.exe /groups /fo csv /nh 2>$null)
    return (@($groups -match 'S-1-16-(12288|16384)').Count -gt 0)
}

# ------------------------------------------------------------------ checks
# A rule is one value: 'eq' = must be Value (missing fails), 'eqm' = must be Value or missing,
# 'ne' = must not be Value (missing is OK, -Fix writes FixValue), 'ge' = at least Value (missing fails).
function New-Rule {
    param([string]$Name, [string]$Op, [int64]$Value, [int64]$FixValue)
    if ($Op -ne 'ne') { $FixValue = $Value }
    return [pscustomobject]@{ Name = $Name; Op = $Op; Value = $Value; FixValue = $FixValue }
}

function New-Check {
    param([string]$Area, [string]$Item, [string]$Key, $Rules, [string]$Skip = '', [switch]$Optional, [switch]$InfoOnly)
    return [pscustomobject]@{
        Area = $Area; Item = $Item; Key = $Key; Rules = @($Rules)
        Skip = $Skip; Optional = [bool]$Optional; InfoOnly = [bool]$InfoOnly
    }
}

function Get-CheckList {
    $off = @((New-Rule 'Enabled' 'eq' 0), (New-Rule 'DisabledByDefault' 'eq' 1))
    # TLS 1.2 on: Enabled missing or not 0; DisabledByDefault missing or 0 (any other value disables it by default)
    $on  = @((New-Rule 'Enabled' 'ne' 0 1), (New-Rule 'DisabledByDefault' 'eqm' 0))
    $list = @()
    foreach ($p in $LegacyProtocols) {
        foreach ($side in 'Server', 'Client') {
            $skip = ''
            if ($AllowLegacyClientTls -and $side -eq 'Client' -and $LegacyClientTls -contains $p) {
                $skip = 'not checked (-AllowLegacyClientTls)'
            }
            $list += New-Check 'Protocol' "$p $side" "$SchannelKey\Protocols\$p\$side" $off -Skip $skip
        }
    }
    foreach ($side in 'Server', 'Client') {
        $list += New-Check 'Protocol' "TLS 1.2 $side" "$SchannelKey\Protocols\TLS 1.2\$side" $on
    }
    foreach ($side in 'Server', 'Client') {
        $list += New-Check 'Protocol' "TLS 1.3 $side" "$SchannelKey\Protocols\TLS 1.3\$side" $on -InfoOnly
    }
    foreach ($c in $WeakCiphers) {
        $list += New-Check 'Cipher' $c "$SchannelKey\Ciphers\$c" @(New-Rule 'Enabled' 'eq' 0)
    }
    foreach ($c in $StrongCiphers) {
        $list += New-Check 'Cipher' $c "$SchannelKey\Ciphers\$c" @(New-Rule 'Enabled' 'ne' 0 $CipherOn)
    }
    $list += New-Check 'KeyExchange' 'Diffie-Hellman' "$SchannelKey\KeyExchangeAlgorithms\Diffie-Hellman" @(New-Rule 'ServerMinKeyBitLength' 'ge' $MinDhBits)
    foreach ($d in $DotNetKeys) {
        $list += New-Check '.NET' $d.Item $d.Key @((New-Rule 'SchUseStrongCrypto' 'eq' 1), (New-Rule 'SystemDefaultTlsVersions' 'eq' 1)) -Optional:$d.Optional
    }
    return $list
}

function Test-Rule {
    param($Rule, $Actual)
    if ($null -eq $Actual) { return ($Rule.Op -eq 'ne' -or $Rule.Op -eq 'eqm') }
    if ($Actual -isnot [int64]) { return $false }    # not a DWORD: SCHANNEL ignores it, -Fix replaces it
    switch ($Rule.Op) {
        'eq' { return ($Actual -eq $Rule.Value) }
        'eqm' { return ($Actual -eq $Rule.Value) }
        'ne' { return ($Actual -ne $Rule.Value) }
        'ge' { return ($Actual -ge $Rule.Value) }
    }
    return $false
}

function Get-RuleText {
    param($Rule)
    switch ($Rule.Op) {
        'eq' { return ('{0}={1}' -f $Rule.Name, (Format-Dword $Rule.Value)) }
        'eqm' { return ('{0}={1} or missing' -f $Rule.Name, (Format-Dword $Rule.Value)) }
        'ne' { return ('{0} not {1}' -f $Rule.Name, (Format-Dword $Rule.Value)) }
        'ge' { return ('{0}>={1}' -f $Rule.Name, (Format-Dword $Rule.Value)) }
    }
    return $Rule.Name
}

function Invoke-Check {
    param($Check)
    $values = Get-RegKeyValue $Check.Key
    if ($Check.InfoOnly -and $null -eq $values) { return $null }

    $current = '(key missing)'
    if ($null -ne $values) {
        $parts = @()
        foreach ($r in $Check.Rules) {
            $v = '(missing)'
            if ($values.ContainsKey($r.Name)) {
                $v = Format-Dword $values[$r.Name]
                if ($values[$r.Name] -isnot [int64]) { $v = '"{0}" (not a DWORD)' -f $values[$r.Name] }
            }
            $parts += ('{0}={1}' -f $r.Name, $v)
        }
        $current = $parts -join ', '
    }

    $expected = (@($Check.Rules | ForEach-Object { Get-RuleText $_ }) -join ', ')
    $failing = @()
    $status = 'OK'
    if ($Check.InfoOnly) {
        $expected = 'not checked'
        $status = 'N/A'
    } elseif ($Check.Skip) {
        $expected = $Check.Skip
        $status = 'N/A'
    } elseif ($Check.Optional -and $null -eq $values) {
        $current = '(key missing: not installed)'
        $status = 'N/A'
    } else {
        foreach ($r in $Check.Rules) {
            $actual = $null
            if ($null -ne $values) { $actual = $values[$r.Name] }
            if (-not (Test-Rule $r $actual)) { $failing += $r }
        }
        if ($failing.Count -gt 0) { $status = 'CHANGE' }
    }
    return [pscustomobject]@{
        Check = $Check; Area = $Check.Area; Item = $Check.Item
        Current = $current; Expected = $expected; Status = $status; Failing = $failing; Changed = $false; Error = ''
    }
}

function Get-Assessment {
    $results = @()
    foreach ($c in (Get-CheckList)) {
        $r = Invoke-Check $c
        if ($r) { $results += $r }
    }
    return $results
}

function Get-ReportRow {
    param($Results)
    return @($Results | Select-Object Area, Item, Current, Expected, Status)
}

# ------------------------------------------------------------------ changes (-Fix)
function Backup-RegistryKey {
    # Exports every key the script may change. Throws when an existing key cannot be exported.
    $targets = @([pscustomobject]@{ Key = $SchannelKey; File = 'backup-schannel.reg' })
    foreach ($d in $DotNetKeys) {
        $targets += [pscustomobject]@{ Key = $d.Key; File = ('backup-dotnet-{0}.reg' -f (($d.Item -replace '[^A-Za-z0-9.]+', '-').Trim('-'))) }
    }
    foreach ($t in $targets) {
        if ($null -eq (Get-RegKeyValue $t.Key)) {
            Out-Line ('  {0} does not exist, nothing to back up' -f $t.Key) 'DarkGray'
            continue
        }
        $file = Join-Path $OutputPath $t.File
        Export-RegKey $t.Key $file
        Out-Line ('  Backup: {0}' -f $file)
    }
}

function Invoke-ItemFix {
    param($Result)
    foreach ($r in $Result.Failing) {
        Set-RegDword $Result.Check.Key $r.Name $r.FixValue
        Out-Line ('  Set {0}\{1} = {2}' -f $Result.Check.Key, $r.Name, (Format-Dword $r.FixValue))
    }
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param($Cmdlet)
    $modeText = 'Report only (use -Fix to change)'
    if ($Fix -and $WhatIfPreference) { $modeText = '-Fix -WhatIf (nothing is changed)' }
    elseif ($Fix) { $modeText = '-Fix' }

    Out-Line 'SCHANNEL and .NET Framework TLS hardening' 'White'
    Out-Line (' Computer : {0}' -f $env:COMPUTERNAME)
    Out-Line (' Mode     : {0}' -f $modeText)
    if ($AllowLegacyClientTls) { Out-Line ' Option   : -AllowLegacyClientTls (TLS 1.0 and TLS 1.1 Client keys are not checked)' }

    if (-not (Get-Command reg.exe -ErrorAction SilentlyContinue)) {
        Out-Line 'reg.exe was not found. This script runs on Windows only.' 'Red'
        return $EXIT_NOT_RUN
    }
    if ($env:PROCESSOR_ARCHITEW6432) {
        Out-Line 'This is 32-bit PowerShell on 64-bit Windows. Run the script from 64-bit PowerShell.' 'Red'
        return $EXIT_NOT_RUN
    }
    if ($Fix -and -not (Test-Elevated)) {
        Out-Line '-Fix needs an elevated PowerShell (Run as administrator). Nothing was changed.' 'Red'
        return $EXIT_NOT_RUN
    }

    $results = @(Get-Assessment)
    $toFix = @($results | Where-Object { $_.Status -eq 'CHANGE' })

    if ($Fix -and $toFix.Count -gt 0) {
        Out-Line ''
        if (-not $WhatIfPreference) {
            Out-Line 'Backup' 'White'
            try {
                Backup-RegistryKey
            } catch {
                Out-Line ('Backup failed: {0}' -f $_.Exception.Message) 'Red'
                Out-Line 'Nothing was changed.' 'Red'
                return $EXIT_NOT_RUN
            }
            Out-Line ''
        }
        Out-Line 'Changes' 'White'
        foreach ($r in $toFix) {
            $writes = @($r.Failing | ForEach-Object { '{0}={1}' -f $_.Name, (Format-Dword $_.FixValue) })
            if ($Cmdlet.ShouldProcess($r.Check.Key, ('Set {0}' -f ($writes -join ', ')))) {
                $r.Changed = $true
                try {
                    Invoke-ItemFix $r
                } catch {
                    $r.Error = $_.Exception.Message
                    Out-Line ('  FAILED: {0}' -f $r.Error) 'Red'
                }
            }
        }

        if (-not $WhatIfPreference) {
            # Check again: an item that was changed is SET when it now matches, FAILED otherwise
            $after = @(Get-Assessment)
            for ($i = 0; $i -lt $after.Count; $i++) {
                $old = @($results | Where-Object { $_.Check.Key -eq $after[$i].Check.Key })[0]
                if ($old -and $old.Changed) {
                    if ($after[$i].Status -eq 'OK' -and -not $old.Error) { $after[$i].Status = 'SET' }
                    else { $after[$i].Status = 'FAILED' }
                }
            }
            $results = $after
        } else {
            Out-Line 'WhatIf: nothing was changed.' 'Yellow'
        }
    } elseif ($Fix) {
        Out-Line ''
        Out-Line 'Nothing to change.' 'Green'
    }

    $rows = Get-ReportRow $results
    Out-Line ''
    Out-Line (($rows | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd())
    $csv = Join-Path $OutputPath 'schannel-report.csv'
    $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false

    $count = @{}
    foreach ($s in 'OK', 'SET', 'CHANGE', 'FAILED', 'N/A') { $count[$s] = @($rows | Where-Object { $_.Status -eq $s }).Count }
    $code = $EXIT_OK
    if ($count['CHANGE'] -gt 0) { $code = $EXIT_ACTION }
    if ($count['FAILED'] -gt 0) { $code = $EXIT_FAILED }

    Out-Line ''
    Out-Line ('Summary: {0} OK, {1} SET, {2} CHANGE, {3} FAILED, {4} N/A' -f
        $count['OK'], $count['SET'], $count['CHANGE'], $count['FAILED'], $count['N/A'])
    switch ($code) {
        0 { Out-Line 'RESULT: COMPLIANT' 'Green' }
        1 { Out-Line 'RESULT: ACTION REQUIRED' 'Red' }
        2 { Out-Line 'RESULT: SOME CHANGES FAILED' 'Red' }
    }
    Out-Line ('Report: {0}' -f $csv) 'Cyan'

    if (@($rows | Where-Object { $_.Status -eq 'SET' -and $_.Area -ne '.NET' }).Count -gt 0) {
        Out-Line 'Restart the computer: SCHANNEL changes take effect after a restart.' 'Yellow'
    } elseif ($count['SET'] -gt 0) {
        Out-Line 'Restart the .NET applications (or the computer) to apply the .NET Framework settings.' 'Yellow'
    }
    if ($count['SET'] -gt 0 -or $count['FAILED'] -gt 0) {
        Out-Line ('To undo: reg.exe import the backup-*.reg files in {0}. Values that did not exist before are not removed.' -f $OutputPath) 'DarkGray'
    }
    if ($code -eq $EXIT_ACTION) {
        if ($Fix -and $WhatIfPreference) { Out-Line 'Run again with -Fix and without -WhatIf to apply the changes.' }
        elseif (-not $Fix) { Out-Line 'Review the CHANGE items, then run again with -Fix (see -AllowLegacyClientTls for servers that talk to old systems).' }
    }
    return $code
}

$transcript = $null
try {
    if (-not $OutputPath) {
        # The helper creates and test-writes the folder: run it without -WhatIf and -Confirm, or a
        # -WhatIf run would find no writable folder
        $OutputPath = & {
            param([string]$Root)
            $WhatIfPreference = $false
            $ConfirmPreference = 'None'
            Get-OutputFolder -ScriptRoot $Root -ScriptName 'Test-SchannelHardening'
        } $PSScriptRoot
        $OutputPath = Join-Path $OutputPath (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false -Confirm:$false | Out-Null
    if ($Fix -and -not $WhatIfPreference) {
        $transcript = Join-Path $OutputPath 'transcript.txt'
        Start-Transcript -LiteralPath $transcript -WhatIf:$false -Confirm:$false | Out-Null
    }
    $result = @(Invoke-Main -Cmdlet $PSCmdlet)
    $script:ExitCode = [int]$result[-1]
} catch {
    Out-Line ('ERROR: {0}' -f $_.Exception.Message) 'Red'
    $script:ExitCode = $EXIT_NOT_RUN
} finally {
    if ($OutputPath) { Out-Line ('Output folder: {0}' -f $OutputPath) 'Cyan' }
    if ($transcript) {
        Out-Line ('Transcript: {0}' -f $transcript) 'Cyan'
        Stop-Transcript | Out-Null
    }
}
exit $script:ExitCode
