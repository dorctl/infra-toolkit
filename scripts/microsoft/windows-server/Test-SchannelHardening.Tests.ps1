#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Test-SchannelHardening.ps1 - verdicts, exit codes and -Fix changes against a mocked registry.

.DESCRIPTION
    reg.exe and whoami.exe are replaced by global functions backed by an in-memory registry. The fake
    registry splits key paths on '\' only, so cipher keys such as 'RC4 128/128' are single keys, as in
    Windows. No Windows system is needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Test-SchannelHardening.ps1'
    $script:Sch    = 'HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL'
    $script:Net64  = 'HKLM\SOFTWARE\Microsoft\.NETFramework'
    $script:Net32  = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\.NETFramework'

    $script:SavedEnv = @{}
    foreach ($n in 'PROCESSOR_ARCHITEW6432', 'COMPUTERNAME') { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
    $env:COMPUTERNAME = 'SRV01'

    # ------------------------------------------------------------------ fake registry
    function global:Get-SchRegId {
        param([string]$Key)
        return $Key.TrimEnd('\').ToLowerInvariant()
    }

    # Creates the key and its parents, like reg.exe add. Only '\' separates keys.
    function global:Set-SchTestReg {
        param([string]$Key, [hashtable]$Values = @{})
        $parts = @($Key.TrimEnd('\') -split '\\')
        for ($i = 1; $i -le $parts.Count; $i++) {
            $p = $parts[0..($i - 1)] -join '\'
            $id = Get-SchRegId $p
            if (-not $global:SchReg.ContainsKey($id)) { $global:SchReg[$id] = @{ Path = $p; Values = [ordered]@{} } }
        }
        foreach ($k in $Values.Keys) { $global:SchReg[(Get-SchRegId $Key)].Values[$k] = $Values[$k] }
    }

    function script:Get-SchTestValue {
        param([string]$Key, [string]$Name)
        $id = Get-SchRegId $Key
        if (-not $global:SchReg.ContainsKey($id)) { return $null }
        return $global:SchReg[$id].Values[$Name]
    }

    function script:Get-SchSnapshot {
        $lines = foreach ($k in @($global:SchReg.Keys | Sort-Object)) {
            $k
            foreach ($n in $global:SchReg[$k].Values.Keys) { '  {0}={1}' -f $n, $global:SchReg[$k].Values[$n] }
        }
        return ($lines -join "`n")
    }

    function global:ConvertTo-SchRegLine {
        param([string]$Name, $Value)
        if ($Value -is [string]) { return ('    {0}    REG_SZ    {1}' -f $Name, $Value) }
        return ('    {0}    REG_DWORD    0x{1:x}' -f $Name, ([int64]$Value -band 4294967295))
    }

    # reg.exe query <key> | add <key> /v <name> /t REG_DWORD /d <data> /f | export <key> <file> /y
    function global:reg.exe {
        $s = $global:SchScenario
        $a = @($args | ForEach-Object { [string]$_ })
        $s.Calls += , $a
        $op = $a[0].ToLowerInvariant()
        $key = $a[1]
        $id = Get-SchRegId $key
        $long = $key -replace '^HKLM', 'HKEY_LOCAL_MACHINE'
        switch ($op) {
            'query' {
                if ($s.QueryThrows) { throw $s.QueryThrows }
                if (-not $global:SchReg.ContainsKey($id)) { $global:LASTEXITCODE = 1; return }
                ''
                $long
                foreach ($n in $global:SchReg[$id].Values.Keys) { ConvertTo-SchRegLine $n $global:SchReg[$id].Values[$n] }
                ''
                foreach ($k in @($global:SchReg.Keys)) {
                    if ($k.StartsWith("$id\") -and $k.Substring($id.Length + 1) -notmatch '\\') {
                        $global:SchReg[$k].Path -replace '^HKLM', 'HKEY_LOCAL_MACHINE'
                    }
                }
                $global:LASTEXITCODE = 0
            }
            'add' {
                $name = ''; $type = ''; $data = ''
                for ($i = 2; $i -lt $a.Count - 1; $i++) {
                    if ($a[$i] -eq '/v') { $name = $a[$i + 1] }
                    if ($a[$i] -eq '/t') { $type = $a[$i + 1] }
                    if ($a[$i] -eq '/d') { $data = $a[$i + 1] }
                }
                if ($s.FailAdd -and $key -like $s.FailAdd) { 'ERROR: Access is denied.'; $global:LASTEXITCODE = 1; return }
                if ($type -ne 'REG_DWORD' -or $a -notcontains '/f') { 'ERROR: Invalid syntax.'; $global:LASTEXITCODE = 1; return }
                if ($data -match '^0x([0-9a-f]+)$') { $value = [Convert]::ToInt64($Matches[1], 16) } else { $value = [int64]$data }
                Set-SchTestReg $key @{ $name = $value }
                'The operation completed successfully.'
                $global:LASTEXITCODE = 0
            }
            'export' {
                $file = $a[2]
                if ($s.FailExport -or -not $global:SchReg.ContainsKey($id)) {
                    'ERROR: The system was unable to find the specified registry key or value.'
                    $global:LASTEXITCODE = 1
                    return
                }
                $lines = @('Windows Registry Editor Version 5.00', '')
                foreach ($k in @($global:SchReg.Keys | Sort-Object)) {
                    if ($k -ne $id -and -not $k.StartsWith("$id\")) { continue }
                    $lines += ('[{0}]' -f ($global:SchReg[$k].Path -replace '^HKLM', 'HKEY_LOCAL_MACHINE'))
                    foreach ($n in $global:SchReg[$k].Values.Keys) {
                        $lines += ('"{0}"=dword:{1:x8}' -f $n, ([int64]$global:SchReg[$k].Values[$n] -band 4294967295))
                    }
                    $lines += ''
                }
                Set-Content -LiteralPath $file -Value $lines -WhatIf:$false -Confirm:$false
                $s.Exports += $file
                $global:LASTEXITCODE = 0
            }
            default { $global:LASTEXITCODE = 1 }
        }
    }

    function global:whoami.exe {
        if ($global:SchScenario.Elevated) { '"Mandatory Label\High Mandatory Level","Label","S-1-16-12288",""' }
        else { '"Mandatory Label\Medium Mandatory Level","Label","S-1-16-8192",""' }
        $global:LASTEXITCODE = 0
    }

    # ------------------------------------------------------------------ systems
    $script:Legacy  = @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'PCT 1.0', 'Multi-Protocol Unified Hello')
    $script:Weak    = @('DES 56/56', 'NULL', 'RC2 40/128', 'RC2 56/128', 'RC2 128/128', 'RC4 40/128', 'RC4 56/128', 'RC4 64/128', 'RC4 128/128', 'Triple DES 168')

    # A fresh installation: SCHANNEL keys mostly empty, .NET 4 present, no .NET 3.5
    function script:Set-OutOfBoxSystem {
        foreach ($k in 'Protocols', 'Ciphers', 'CipherSuites', 'Hashes', 'KeyExchangeAlgorithms') { Set-SchTestReg "$script:Sch\$k" }
        Set-SchTestReg "$script:Sch\Protocols\SSL 2.0\Client" @{ DisabledByDefault = 1 }
        Set-SchTestReg "$script:Net64\v4.0.30319" @{ OnlyUseLatestCLR = 0 }
        Set-SchTestReg "$script:Net32\v4.0.30319" @{ OnlyUseLatestCLR = 0 }
    }

    # Hardened the way the baseline expects, with .NET 3.5 installed
    function script:Set-CompliantSystem {
        Set-OutOfBoxSystem
        foreach ($p in $script:Legacy) {
            foreach ($side in 'Server', 'Client') { Set-SchTestReg "$script:Sch\Protocols\$p\$side" @{ Enabled = 0; DisabledByDefault = 1 } }
        }
        foreach ($side in 'Server', 'Client') { Set-SchTestReg "$script:Sch\Protocols\TLS 1.2\$side" @{ Enabled = 4294967295; DisabledByDefault = 0 } }
        foreach ($c in $script:Weak) { Set-SchTestReg "$script:Sch\Ciphers\$c" @{ Enabled = 0 } }
        foreach ($c in 'AES 128/128', 'AES 256/256') { Set-SchTestReg "$script:Sch\Ciphers\$c" @{ Enabled = 4294967295 } }
        Set-SchTestReg "$script:Sch\KeyExchangeAlgorithms\Diffie-Hellman" @{ ServerMinKeyBitLength = 2048; Enabled = 4294967295 }
        foreach ($root in $script:Net64, $script:Net32) {
            foreach ($v in 'v4.0.30319', 'v2.0.50727') { Set-SchTestReg "$root\$v" @{ SchUseStrongCrypto = 1; SystemDefaultTlsVersions = 1 } }
        }
    }

    function script:Invoke-Scenario {
        param([switch]$Compliant, [scriptblock]$Setup, [hashtable]$Params = @{}, [hashtable]$Scenario = @{}, [string]$ScriptDir)
        $global:SchReg = @{}
        $global:SchScenario = @{ Elevated = $true; Calls = @(); Exports = @(); FailAdd = ''; FailExport = $false; QueryThrows = '' }
        foreach ($k in $Scenario.Keys) { $global:SchScenario[$k] = $Scenario[$k] }
        $env:PROCESSOR_ARCHITEW6432 = $null
        if ($Scenario.Wow64) { $env:PROCESSOR_ARCHITEW6432 = 'AMD64' }
        if ($Compliant) { Set-CompliantSystem } else { Set-OutOfBoxSystem }
        if ($Setup) { & $Setup }
        $global:SchScenario.Calls = @()
        $before = Get-SchSnapshot

        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        if ($ScriptDir) {
            # A copy of the script, run without -OutputPath: the default folder is next to the copy
            $copy = Join-Path $ScriptDir (Split-Path -Leaf $script:Target)
            Copy-Item -LiteralPath $script:Target -Destination $copy -Force
            $output = & $copy @Params *>&1
        } else {
            $output = & $script:Target @Params -OutputPath $out *>&1
        }
        $code = $LASTEXITCODE
        $text = (@($output | ForEach-Object { [string]$_ }) -join "`n")
        # With the default folder, the script prints where it wrote
        if ($ScriptDir) {
            $out = Join-Path $ScriptDir 'no-output-folder-printed'
            if ($text -match 'Output folder: ([^\r\n]+)') { $out = $Matches[1].Trim() }
        }

        $csv = Join-Path $out 'schannel-report.csv'
        $rows = @()
        if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $csv) { $rows = @(Import-Csv -LiteralPath $csv) }
        $env:PROCESSOR_ARCHITEW6432 = $null
        return [pscustomobject]@{
            ExitCode = $code; Rows = $rows; Out = $out
            Text     = $text
            Adds     = @($global:SchScenario.Calls | Where-Object { $_[0] -eq 'add' })
            Exports  = @($global:SchScenario.Exports)
            Changed  = ((Get-SchSnapshot) -ne $before)
        }
    }

    function script:Get-Row {
        param($Result, [string]$Item)
        return @($Result.Rows | Where-Object { $_.Item -eq $Item })[0]
    }

    $script:FixParams = @{ Fix = $true; Confirm = $false }
}

AfterAll {
    foreach ($f in 'Get-SchRegId', 'Set-SchTestReg', 'ConvertTo-SchRegLine', 'reg.exe', 'whoami.exe') {
        # "Function:\global:<name>" does not remove anything: the provider path takes no scope prefix
        Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name SchReg, SchScenario -Scope Global -ErrorAction SilentlyContinue
    foreach ($n in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
}

Describe 'Test-SchannelHardening' {

    Context 'Report only' {

        It 'hardened system: compliant (exit 0), nothing written' {
            $r = Invoke-Scenario -Compliant
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'RESULT: COMPLIANT'
            @($r.Rows | Where-Object { $_.Status -notin 'OK', 'N/A' }).Count | Should -Be 0
            (Get-Row $r 'TLS 1.2 Server').Current | Should -Be 'Enabled=0xffffffff, DisabledByDefault=0'
            (Get-Row $r 'v2.0.50727 (32-bit)').Status | Should -Be 'OK'
            $r.Adds.Count | Should -Be 0
            $r.Changed    | Should -BeFalse
        }

        It 'every row has Area, Item, Current, Expected and Status' {
            $r = Invoke-Scenario -Compliant
            $r.Rows.Count | Should -Be 31
            ($r.Rows[0].PSObject.Properties.Name -join ',') | Should -Be 'Area,Item,Current,Expected,Status'
            @($r.Rows | Where-Object Area -eq 'Protocol').Count    | Should -Be 14
            @($r.Rows | Where-Object Area -eq 'Cipher').Count      | Should -Be 12
            @($r.Rows | Where-Object Area -eq 'KeyExchange').Count | Should -Be 1
            @($r.Rows | Where-Object Area -eq '.NET').Count        | Should -Be 4
        }

        It 'out-of-box system (missing keys): action required (exit 1), nothing written' {
            $r = Invoke-Scenario
            $r.ExitCode | Should -Be 1
            $r.Text     | Should -Match 'RESULT: ACTION REQUIRED'
            (Get-Row $r 'SSL 3.0 Server').Status  | Should -Be 'CHANGE'
            (Get-Row $r 'SSL 3.0 Server').Current | Should -Be '(key missing)'
            (Get-Row $r 'SSL 2.0 Client').Current | Should -Be 'Enabled=(missing), DisabledByDefault=1'
            (Get-Row $r 'SSL 2.0 Client').Status  | Should -Be 'CHANGE'
            (Get-Row $r 'TLS 1.0 Client').Status  | Should -Be 'CHANGE'
            (Get-Row $r 'TLS 1.2 Server').Status  | Should -Be 'OK'
            (Get-Row $r 'TLS 1.2 Client').Status  | Should -Be 'OK'
            (Get-Row $r 'RC4 128/128').Status     | Should -Be 'CHANGE'
            (Get-Row $r 'AES 256/256').Status     | Should -Be 'OK'
            (Get-Row $r 'Diffie-Hellman').Status  | Should -Be 'CHANGE'
            (Get-Row $r 'v4.0.30319 (64-bit)').Current | Should -Be 'SchUseStrongCrypto=(missing), SystemDefaultTlsVersions=(missing)'
            (Get-Row $r 'v4.0.30319 (64-bit)').Status  | Should -Be 'CHANGE'
            (Get-Row $r 'v2.0.50727 (64-bit)').Status  | Should -Be 'N/A'
            (Get-Row $r 'v2.0.50727 (32-bit)').Current | Should -Be '(key missing: not installed)'
            Get-Row $r 'TLS 1.3 Server' | Should -BeNullOrEmpty
            $r.Adds.Count | Should -Be 0
            $r.Changed    | Should -BeFalse
            $r.Text       | Should -Match 'run again with -Fix'
        }

        It 'TLS 1.0 Client enabled: action required' {
            $r = Invoke-Scenario -Compliant -Setup { Set-SchTestReg "$script:Sch\Protocols\TLS 1.0\Client" @{ Enabled = 1; DisabledByDefault = 0 } }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'TLS 1.0 Client').Status   | Should -Be 'CHANGE'
            (Get-Row $r 'TLS 1.0 Client').Current  | Should -Be 'Enabled=1, DisabledByDefault=0'
            (Get-Row $r 'TLS 1.0 Client').Expected | Should -Be 'Enabled=0, DisabledByDefault=1'
        }

        It 'TLS 1.0 and 1.1 Client enabled with -AllowLegacyClientTls: compliant, rows not checked' {
            $r = Invoke-Scenario -Compliant -Params @{ AllowLegacyClientTls = $true } -Setup {
                Set-SchTestReg "$script:Sch\Protocols\TLS 1.0\Client" @{ Enabled = 1; DisabledByDefault = 0 }
                Set-SchTestReg "$script:Sch\Protocols\TLS 1.1\Client" @{ Enabled = 1; DisabledByDefault = 0 }
            }
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'TLS 1.0 Client').Status   | Should -Be 'N/A'
            (Get-Row $r 'TLS 1.0 Client').Expected | Should -Be 'not checked (-AllowLegacyClientTls)'
            (Get-Row $r 'TLS 1.1 Client').Status   | Should -Be 'N/A'
        }

        It '-AllowLegacyClientTls still checks the TLS 1.0 Server key and the SSL Client keys' {
            $r = Invoke-Scenario -Compliant -Params @{ AllowLegacyClientTls = $true } -Setup {
                Set-SchTestReg "$script:Sch\Protocols\TLS 1.0\Server" @{ Enabled = 1 }
                Set-SchTestReg "$script:Sch\Protocols\SSL 3.0\Client" @{ Enabled = 1 }
            }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'TLS 1.0 Server').Status | Should -Be 'CHANGE'
            (Get-Row $r 'SSL 3.0 Client').Status | Should -Be 'CHANGE'
        }

        It 'Triple DES enabled: action required' {
            $r = Invoke-Scenario -Compliant -Setup { Set-SchTestReg "$script:Sch\Ciphers\Triple DES 168" @{ Enabled = 4294967295 } }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'Triple DES 168').Status  | Should -Be 'CHANGE'
            (Get-Row $r 'Triple DES 168').Current | Should -Be 'Enabled=0xffffffff'
        }

        It 'Diffie-Hellman 1024 bits: action required, 4096 bits: compliant' {
            $r = Invoke-Scenario -Compliant -Setup { Set-SchTestReg "$script:Sch\KeyExchangeAlgorithms\Diffie-Hellman" @{ ServerMinKeyBitLength = 1024 } }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'Diffie-Hellman').Current  | Should -Be 'ServerMinKeyBitLength=1024'
            (Get-Row $r 'Diffie-Hellman').Expected | Should -Be 'ServerMinKeyBitLength>=2048'

            $r = Invoke-Scenario -Compliant -Setup { Set-SchTestReg "$script:Sch\KeyExchangeAlgorithms\Diffie-Hellman" @{ ServerMinKeyBitLength = 4096 } }
            $r.ExitCode | Should -Be 0
        }

        It 'Diffie-Hellman value missing: action required' {
            $r = Invoke-Scenario -Compliant -Setup {
                $global:SchReg[(Get-SchRegId "$script:Sch\KeyExchangeAlgorithms\Diffie-Hellman")].Values.Remove('ServerMinKeyBitLength')
            }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'Diffie-Hellman').Current | Should -Be 'ServerMinKeyBitLength=(missing)'
        }

        It '.NET values missing in the 32-bit view: action required' {
            $r = Invoke-Scenario -Compliant -Setup {
                $v = $global:SchReg[(Get-SchRegId "$script:Net32\v4.0.30319")].Values
                $v.Remove('SchUseStrongCrypto'); $v.Remove('SystemDefaultTlsVersions')
            }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'v4.0.30319 (32-bit)').Status | Should -Be 'CHANGE'
            (Get-Row $r 'v4.0.30319 (64-bit)').Status | Should -Be 'OK'
        }

        It '.NET v4 key missing in the 64-bit view: action required, not N/A' {
            $r = Invoke-Scenario -Compliant -Setup { $global:SchReg.Remove((Get-SchRegId "$script:Net64\v4.0.30319")) }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'v4.0.30319 (64-bit)').Status  | Should -Be 'CHANGE'
            (Get-Row $r 'v4.0.30319 (64-bit)').Current | Should -Be '(key missing)'
        }

        It 'TLS 1.2 <Side> with <Label>: action required' -ForEach @(
            @{ Side = 'Server'; Label = 'Enabled = 0';                    Values = @{ Enabled = 0 } }
            @{ Side = 'Client'; Label = 'DisabledByDefault = 1';          Values = @{ DisabledByDefault = 1 } }
            @{ Side = 'Server'; Label = 'DisabledByDefault = 0xffffffff'; Values = @{ DisabledByDefault = 4294967295 } }
        ) {
            $key = "$script:Sch\Protocols\TLS 1.2\$Side"
            $r = Invoke-Scenario -Compliant -Setup { Set-SchTestReg $key $Values }.GetNewClosure()
            $r.ExitCode | Should -Be 1
            (Get-Row $r "TLS 1.2 $Side").Status   | Should -Be 'CHANGE'
            (Get-Row $r "TLS 1.2 $Side").Expected | Should -Be 'Enabled not 0, DisabledByDefault=0 or missing'
        }

        It 'TLS 1.2 with only Enabled = 0xffffffff (DisabledByDefault missing): OK' {
            $r = Invoke-Scenario -Compliant -Setup {
                $global:SchReg[(Get-SchRegId "$script:Sch\Protocols\TLS 1.2\Client")].Values.Remove('DisabledByDefault')
            }
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'TLS 1.2 Client').Current | Should -Be 'Enabled=0xffffffff, DisabledByDefault=(missing)'
            (Get-Row $r 'TLS 1.2 Client').Status  | Should -Be 'OK'
        }

        It 'AES 256 disabled: action required' {
            $r = Invoke-Scenario -Compliant -Setup { Set-SchTestReg "$script:Sch\Ciphers\AES 256/256" @{ Enabled = 0 } }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'AES 256/256').Status | Should -Be 'CHANGE'
        }

        It 'a value that is not a DWORD does not count as set' {
            $r = Invoke-Scenario -Compliant -Setup { Set-SchTestReg "$script:Sch\Ciphers\RC4 40/128" @{ Enabled = '0' } }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'RC4 40/128').Current | Should -Be 'Enabled="0" (not a DWORD)'
        }

        It 'TLS 1.3 is listed when configured, not checked' {
            $r = Invoke-Scenario -Compliant -Setup { Set-SchTestReg "$script:Sch\Protocols\TLS 1.3\Server" @{ Enabled = 0 } }
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'TLS 1.3 Server').Status   | Should -Be 'N/A'
            (Get-Row $r 'TLS 1.3 Server').Expected | Should -Be 'not checked'
            Get-Row $r 'TLS 1.3 Client' | Should -BeNullOrEmpty
        }

        It 'reading needs no elevation' {
            $r = Invoke-Scenario -Compliant -Scenario @{ Elevated = $false }
            $r.ExitCode | Should -Be 0
        }
    }

    Context 'Cannot run (exit 3)' {

        It 'not elevated with -Fix: nothing is written' {
            $r = Invoke-Scenario -Params $FixParams -Scenario @{ Elevated = $false }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'Run as administrator'
            $r.Adds.Count    | Should -Be 0
            $r.Exports.Count | Should -Be 0
            $r.Changed       | Should -BeFalse
        }

        It '32-bit PowerShell on 64-bit Windows' {
            $r = Invoke-Scenario -Compliant -Scenario @{ Wow64 = $true }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match '64-bit PowerShell'
        }

        It 'unexpected error' {
            $r = Invoke-Scenario -Compliant -Scenario @{ QueryThrows = 'Simulated failure' }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'ERROR: Simulated failure'
        }

        It 'backup fails: nothing is written' {
            $r = Invoke-Scenario -Params $FixParams -Scenario @{ FailExport = $true }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'Backup failed'
            $r.Adds.Count | Should -Be 0
            $r.Changed    | Should -BeFalse
        }
    }

    Context '-Fix' {

        It 'out-of-box system: backs up, writes the baseline and reports SET (exit 0)' {
            $r = Invoke-Scenario -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'RESULT: COMPLIANT'
            $r.Text     | Should -Match 'Restart the computer'

            foreach ($p in $script:Legacy) {
                foreach ($side in 'Server', 'Client') {
                    Get-SchTestValue "$script:Sch\Protocols\$p\$side" 'Enabled'           | Should -Be 0
                    Get-SchTestValue "$script:Sch\Protocols\$p\$side" 'DisabledByDefault' | Should -Be 1
                }
            }
            foreach ($c in $script:Weak) { Get-SchTestValue "$script:Sch\Ciphers\$c" 'Enabled' | Should -Be 0 }
            # Cipher names with '/' are one key, not a key with a sub-key
            $global:SchReg.ContainsKey((Get-SchRegId "$script:Sch\Ciphers\RC4 128/128")) | Should -BeTrue
            $global:SchReg.ContainsKey((Get-SchRegId "$script:Sch\Ciphers\RC4 128"))     | Should -BeFalse
            Get-SchTestValue "$script:Sch\KeyExchangeAlgorithms\Diffie-Hellman" 'ServerMinKeyBitLength' | Should -Be 2048
            foreach ($root in $script:Net64, $script:Net32) {
                Get-SchTestValue "$root\v4.0.30319" 'SchUseStrongCrypto'       | Should -Be 1
                Get-SchTestValue "$root\v4.0.30319" 'SystemDefaultTlsVersions' | Should -Be 1
                $global:SchReg.ContainsKey((Get-SchRegId "$root\v2.0.50727")) | Should -BeFalse
            }
            # Items that were already OK are not touched
            @($r.Adds | Where-Object { $_[1] -like '*TLS 1.2*' -or $_[1] -like '*AES*' }).Count | Should -Be 0
            # Every DWORD is written with reg.exe add /t REG_DWORD /f
            @($r.Adds | Where-Object { $_ -notcontains 'REG_DWORD' -or $_ -notcontains '/f' }).Count | Should -Be 0

            (Get-Row $r 'SSL 2.0 Server').Status      | Should -Be 'SET'
            (Get-Row $r 'Triple DES 168').Status      | Should -Be 'SET'
            (Get-Row $r 'Diffie-Hellman').Status      | Should -Be 'SET'
            (Get-Row $r 'v4.0.30319 (32-bit)').Status | Should -Be 'SET'
            (Get-Row $r 'TLS 1.2 Server').Status      | Should -Be 'OK'
            (Get-Row $r 'v2.0.50727 (64-bit)').Status | Should -Be 'N/A'

            $schBackup = Join-Path $r.Out 'backup-schannel.reg'
            Microsoft.PowerShell.Management\Test-Path -LiteralPath $schBackup | Should -BeTrue
            Get-Content -LiteralPath $schBackup -Raw | Should -Match ([regex]::Escape("[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL]"))
            # The backup holds the state before the change
            Get-Content -LiteralPath $schBackup -Raw | Should -Not -Match 'Triple DES'
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'backup-dotnet-v4.0.30319-64-bit.reg') | Should -BeTrue
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'backup-dotnet-v4.0.30319-32-bit.reg') | Should -BeTrue
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'backup-dotnet-v2.0.50727-64-bit.reg') | Should -BeFalse
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeTrue

            # The first export runs before the first write
            $ops = @($global:SchScenario.Calls | ForEach-Object { $_[0] } | Where-Object { $_ -ne 'query' })
            $ops[0] | Should -Be 'export'
            [array]::IndexOf($ops, 'add') | Should -BeGreaterThan ([array]::LastIndexOf($ops, 'export'))
        }

        It 'writes only the values that differ' {
            $r = Invoke-Scenario -Compliant -Params $FixParams -Setup {
                $global:SchReg[(Get-SchRegId "$script:Sch\Protocols\TLS 1.0\Server")].Values.Remove('DisabledByDefault')
            }
            $r.ExitCode | Should -Be 0
            $r.Adds.Count | Should -Be 1
            $r.Adds[0][1] | Should -Be "$script:Sch\Protocols\TLS 1.0\Server"
            $r.Adds[0]    | Should -Contain 'DisabledByDefault'
            (Get-Row $r 'TLS 1.0 Server').Status | Should -Be 'SET'
        }

        It 'TLS 1.2 disabled: writes Enabled = 1 and DisabledByDefault = 0; AES disabled: writes 0xffffffff' {
            $r = Invoke-Scenario -Compliant -Params $FixParams -Setup {
                Set-SchTestReg "$script:Sch\Protocols\TLS 1.2\Server" @{ Enabled = 0; DisabledByDefault = 1 }
                Set-SchTestReg "$script:Sch\Protocols\TLS 1.2\Client" @{ DisabledByDefault = 4294967295 }
                Set-SchTestReg "$script:Sch\Ciphers\AES 128/128" @{ Enabled = 0 }
            }
            $r.ExitCode | Should -Be 0
            Get-SchTestValue "$script:Sch\Protocols\TLS 1.2\Server" 'Enabled'           | Should -Be 1
            Get-SchTestValue "$script:Sch\Protocols\TLS 1.2\Server" 'DisabledByDefault' | Should -Be 0
            Get-SchTestValue "$script:Sch\Protocols\TLS 1.2\Client" 'DisabledByDefault' | Should -Be 0
            (Get-Row $r 'TLS 1.2 Client').Status | Should -Be 'SET'
            Get-SchTestValue "$script:Sch\Ciphers\AES 128/128" 'Enabled'               | Should -Be 4294967295
        }

        It 'Diffie-Hellman 1024: writes 2048' {
            $r = Invoke-Scenario -Compliant -Params $FixParams -Setup { Set-SchTestReg "$script:Sch\KeyExchangeAlgorithms\Diffie-Hellman" @{ ServerMinKeyBitLength = 1024 } }
            $r.ExitCode | Should -Be 0
            Get-SchTestValue "$script:Sch\KeyExchangeAlgorithms\Diffie-Hellman" 'ServerMinKeyBitLength' | Should -Be 2048
            Get-SchTestValue "$script:Sch\KeyExchangeAlgorithms\Diffie-Hellman" 'Enabled' | Should -Be 4294967295
        }

        It '-AllowLegacyClientTls: TLS 1.0 and 1.1 Client keys are not changed' {
            $r = Invoke-Scenario -Params @{ Fix = $true; Confirm = $false; AllowLegacyClientTls = $true } -Setup {
                Set-SchTestReg "$script:Sch\Protocols\TLS 1.0\Client" @{ Enabled = 1; DisabledByDefault = 0 }
            }
            $r.ExitCode | Should -Be 0
            Get-SchTestValue "$script:Sch\Protocols\TLS 1.0\Client" 'Enabled' | Should -Be 1
            $global:SchReg.ContainsKey((Get-SchRegId "$script:Sch\Protocols\TLS 1.1\Client")) | Should -BeFalse
            Get-SchTestValue "$script:Sch\Protocols\TLS 1.1\Server" 'Enabled' | Should -Be 0
            (Get-Row $r 'TLS 1.0 Client').Status | Should -Be 'N/A'
        }

        It '-WhatIf writes nothing' {
            $r = Invoke-Scenario -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            $r.Text     | Should -Match 'WhatIf: nothing was changed'
            $r.Adds.Count    | Should -Be 0
            $r.Exports.Count | Should -Be 0
            $r.Changed       | Should -BeFalse
            @($r.Rows | Where-Object Status -eq 'SET').Count | Should -Be 0
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeFalse
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'backup-schannel.reg') | Should -BeFalse
        }

        It 'compliant system: nothing to change, no backup' {
            $r = Invoke-Scenario -Compliant -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'Nothing to change'
            $r.Adds.Count    | Should -Be 0
            $r.Exports.Count | Should -Be 0
            $r.Text     | Should -Not -Match 'Restart the computer'
        }

        It 'only .NET changed: asks for an application restart' {
            $r = Invoke-Scenario -Compliant -Params $FixParams -Setup {
                $global:SchReg[(Get-SchRegId "$script:Net64\v2.0.50727")].Values.Remove('SchUseStrongCrypto')
            }
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'Restart the \.NET applications'
            $r.Text     | Should -Not -Match 'Restart the computer:'
        }

        It 'a write that fails: FAILED and exit 2, the other items are still set' {
            $r = Invoke-Scenario -Params $FixParams -Scenario @{ FailAdd = '*\Ciphers\RC4*' }
            $r.ExitCode | Should -Be 2
            $r.Text     | Should -Match 'RESULT: SOME CHANGES FAILED'
            (Get-Row $r 'RC4 128/128').Status    | Should -Be 'FAILED'
            (Get-Row $r 'Triple DES 168').Status | Should -Be 'SET'
            $r.Text | Should -Match 'Access is denied'
        }
    }

    Context 'Default output folder' {

        It 'without the path parameter: InfraToolkit-Output\Test-SchannelHardening plus a timestamp folder, next to the script, also with -WhatIf' {
            $dir = Join-Path $TestDrive ('Scripts-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
            Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $dir | Out-Null
            $base = Join-Path (Join-Path $dir 'InfraToolkit-Output') 'Test-SchannelHardening'

            $r = Invoke-Scenario -Compliant -ScriptDir $dir
            $r.ExitCode | Should -Be 0
            $r.Rows.Count | Should -Be 31
            Split-Path -Parent $r.Out | Should -Be $base
            Split-Path -Leaf $r.Out   | Should -Match '^\d{8}-\d{6}$'

            # -WhatIf must not stop the script from finding its folder, and writes only the report
            $r = Invoke-Scenario -ScriptDir $dir -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            $r.Rows.Count | Should -Be 31
            $r.Exports.Count | Should -Be 0
            Split-Path -Parent $r.Out | Should -Be $base
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeFalse
        }
    }
}
