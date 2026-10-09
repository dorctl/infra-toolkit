#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Export-HardwareInventory.ps1 - collected values, CSV add or update, legacy files and exit codes.

.DESCRIPTION
    Get-CimInstance is replaced by a global function that returns the CIM classes of an in-memory scenario
    per computer. The inventory files are real CSV files in TestDrive. No Windows system is needed, so the
    tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Export-HardwareInventory.ps1'
    $script:Columns = @('ComputerName', 'Manufacturer', 'Model', 'SerialNumber', 'BiosVersion', 'OperatingSystem', 'OsVersion',
                        'Cpu', 'MemoryGB', 'IPAddresses', 'MacAddresses', 'DhcpEnabled', 'Monitors', 'CollectedAt')

    $script:SavedComputerName = $env:COMPUTERNAME
    $env:COMPUTERNAME = 'PC01'

    # WmiMonitorID strings: character codes padded with zeros
    function script:ConvertTo-MonitorCode {
        param([string]$Text, [int]$Length = 16)
        $codes = @($Text.ToCharArray() | ForEach-Object { [uint16][char]$_ })
        while ($codes.Count -lt $Length) { $codes += [uint16]0 }
        return , [uint16[]]$codes
    }

    function script:New-TestMonitor {
        param([string]$Maker, [string]$Model, [string]$Serial)
        return [pscustomobject]@{
            ManufacturerName = ConvertTo-MonitorCode $Maker
            UserFriendlyName = ConvertTo-MonitorCode $Model 13
            SerialNumberID   = ConvertTo-MonitorCode $Serial
            Active           = $true
        }
    }

    function script:New-TestAdapter {
        param([string[]]$IP, [string]$Mac, [bool]$Dhcp = $true, [bool]$Enabled = $true)
        return [pscustomobject]@{ IPEnabled = $Enabled; IPAddress = $IP; MACAddress = $Mac; DHCPEnabled = $Dhcp }
    }

    function script:New-TestComputer {
        param(
            [string]$Name, [string]$Serial, [string]$Model = 'OptiPlex 7090', [string]$Manufacturer = 'Example Computers Inc.',
            [int64]$MemoryBytes = 17007497216, [object[]]$Adapters, [object[]]$Monitors, [switch]$NoMonitors,
            [int]$Sockets = 1
        )
        if (-not $Adapters) { $Adapters = @(New-TestAdapter -IP '192.0.2.10', 'fe80::1' -Mac '00:00:5E:00:53:01') }
        $cpu = @(1..$Sockets | ForEach-Object { [pscustomobject]@{ Name = 'Intel(R) Core(TM) i7-11700  CPU @ 2.50GHz   ' } })
        $pc = @{
            ComputerSystem = [pscustomobject]@{ Name = $Name; Manufacturer = $Manufacturer; Model = $Model; TotalPhysicalMemory = $MemoryBytes }
            Bios           = [pscustomobject]@{ SerialNumber = $Serial; SMBIOSBIOSVersion = '1.12.0'; Version = 'EXAMPLE - 1072009' }
            OS             = [pscustomobject]@{ Caption = 'Microsoft Windows 11 Enterprise'; Version = '10.0.26100' }
            Processor      = $cpu
            Adapters       = $Adapters
            Monitors       = $Monitors
        }
        if ($NoMonitors) { $pc.Monitors = $null }
        return $pc
    }

    # Mocked CIM. Functions take precedence over cmdlets.
    function global:Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Namespace, [string]$Filter, [string[]]$ComputerName)
        $name = $env:COMPUTERNAME
        if ($ComputerName) { $name = $ComputerName[0] }
        $global:InvScenario.Calls += [pscustomobject]@{ ClassName = $ClassName; ComputerName = ($ComputerName -join ','); Namespace = $Namespace }
        $pc = $global:InvScenario.Computers[$name]
        if (-not $pc) { throw ('WinRM cannot complete the operation. Verify that the computer {0} is reachable.' -f $name) }
        switch ($ClassName) {
            'Win32_ComputerSystem'  { return $pc.ComputerSystem }
            'Win32_BIOS'            { return $pc.Bios }
            'Win32_OperatingSystem' { return $pc.OS }
            'Win32_Processor'       { return $pc.Processor }
            'Win32_NetworkAdapterConfiguration' {
                $a = @($pc.Adapters)
                if ($Filter -match 'IPEnabled\s*=\s*True') { $a = @($a | Where-Object { $_.IPEnabled }) }
                return $a
            }
            'WmiMonitorID' {
                if ($Namespace -ne 'root\wmi') { throw 'Invalid class' }
                if ($null -eq $pc.Monitors) { throw 'Not supported' }
                return $pc.Monitors
            }
        }
        throw ('Unexpected class {0}' -f $ClassName)
    }

    function script:Set-Scenario {
        param([hashtable]$Computers)
        $global:InvScenario = @{ Computers = $Computers; Calls = @() }
    }

    function script:Invoke-Inventory {
        param([string]$Csv, [string[]]$Computers)
        $run = @{ CsvPath = $Csv }
        if ($Computers) { $run['ComputerName'] = $Computers }
        $output = & $script:Target @run *>&1 | Out-String
        $code = $LASTEXITCODE
        $rows = @()
        if (Test-Path -LiteralPath $Csv) { $rows = @(Import-Csv -LiteralPath $Csv) }
        return [pscustomobject]@{ ExitCode = $code; Output = $output; Rows = $rows; Calls = @($global:InvScenario.Calls) }
    }

    # Export-Csv that always fails, like a full disk. A global function, because the Pester mock of
    # Export-Csv cannot take -Encoding UTF8 on PowerShell 7. Removed in AfterEach.
    function script:Set-FailingExport {
        function global:Export-Csv {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$LiteralPath, [switch]$NoTypeInformation, [string]$Encoding)
            end { throw [System.IO.IOException]::new('There is not enough space on the disk.') }
        }
    }

    function script:Set-TestCsv {
        param([string]$Path, [string[]]$Lines)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
        Set-Content -LiteralPath $Path -Value $Lines
    }

    function script:Get-FolderContent {
        param([string]$Csv)
        return @(Get-ChildItem -LiteralPath (Split-Path -Parent $Csv) -Force | ForEach-Object { $_.Name } | Sort-Object)
    }

    function script:New-CsvPath {
        return (Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) 'hardware-inventory.csv')
    }

    $script:Monitor1 = New-TestMonitor 'DEL' 'DELL P2422H' 'ABC1234'
    $script:Monitor2 = New-TestMonitor 'SAM' 'S24R35x' 'H4ZR000001'
}

AfterAll {
    # "Function:\global:<name>" does not remove anything: the provider path takes no scope prefix
    foreach ($f in 'Get-CimInstance', 'Export-Csv') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
    Remove-Variable -Name InvScenario -Scope Global -ErrorAction SilentlyContinue
    $env:COMPUTERNAME = $script:SavedComputerName
}

Describe 'Export-HardwareInventory' {

    AfterEach { Remove-Item -LiteralPath 'Function:\Export-Csv' -ErrorAction SilentlyContinue }

    Context 'Collected values' {

        It 'new file: one row with the fixed columns, local computer read without -ComputerName (exit 0)' {
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ' -Monitors $script:Monitor1, $script:Monitor2) }
            $csv = New-CsvPath
            $r = Invoke-Inventory -Csv $csv
            $r.ExitCode | Should -Be 0
            Test-Path -LiteralPath $csv | Should -BeTrue
            (Get-Content -LiteralPath $csv -TotalCount 1) | Should -Be ('"{0}"' -f ($script:Columns -join '","'))
            $r.Rows.Count | Should -Be 1
            $row = $r.Rows[0]
            $row.ComputerName    | Should -Be 'PC01'
            $row.Manufacturer    | Should -Be 'Example Computers Inc.'
            $row.Model           | Should -Be 'OptiPlex 7090'
            $row.SerialNumber    | Should -Be '5CD1234XYZ'
            $row.BiosVersion     | Should -Be '1.12.0'
            $row.OperatingSystem | Should -Be 'Microsoft Windows 11 Enterprise'
            $row.OsVersion       | Should -Be '10.0.26100'
            $row.Cpu             | Should -Be 'Intel(R) Core(TM) i7-11700 CPU @ 2.50GHz'
            $row.MemoryGB        | Should -Be '16'
            $row.IPAddresses     | Should -Be '192.0.2.10'
            $row.MacAddresses    | Should -Be '00:00:5E:00:53:01'
            $row.DhcpEnabled     | Should -Be 'Yes'
            $row.Monitors        | Should -Be 'DEL DELL P2422H SN:ABC1234; SAM S24R35x SN:H4ZR000001'
            $row.CollectedAt     | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d$'
            @($r.Calls | Where-Object { $_.ComputerName }).Count | Should -Be 0
            ($r.Calls | Where-Object { $_.ClassName -eq 'WmiMonitorID' }).Namespace | Should -Be 'root\wmi'
        }

        It 'two adapters: no error, IP, MAC and DHCP per adapter in the same order, a dash for no IPv4, IP disabled left out' {
            $adapters = @(
                New-TestAdapter -IP '192.0.2.10', 'fe80::1' -Mac '00:00:5E:00:53:01' -Dhcp $true
                New-TestAdapter -IP '198.51.100.20', '198.51.100.21' -Mac '00:00:5E:00:53:02' -Dhcp $false
                New-TestAdapter -IP 'fe80::3' -Mac '00:00:5E:00:53:03' -Dhcp $true
                New-TestAdapter -IP $null -Mac '00:00:5E:00:53:04' -Enabled $false
            )
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ' -Adapters $adapters -Sockets 2) }
            $r = Invoke-Inventory -Csv (New-CsvPath)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].IPAddresses  | Should -Be '192.0.2.10; 198.51.100.20, 198.51.100.21; -'
            $r.Rows[0].MacAddresses | Should -Be '00:00:5E:00:53:01; 00:00:5E:00:53:02; 00:00:5E:00:53:03'
            $r.Rows[0].DhcpEnabled  | Should -Be 'Yes; No; Yes'
            $r.Rows[0].Cpu          | Should -Be '2 x Intel(R) Core(TM) i7-11700 CPU @ 2.50GHz'
        }

        It 'no monitor information (server or VM): Monitors empty, not an error' {
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial 'VMware-42 1a 2b 3c' -NoMonitors) }
            $r = Invoke-Inventory -Csv (New-CsvPath)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Monitors | Should -BeNullOrEmpty
        }

        It 'remote computers are read with -ComputerName' {
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial 'S1'); PC02 = (New-TestComputer -Name 'PC02' -Serial 'S2') }
            $r = Invoke-Inventory -Csv (New-CsvPath) -Computers 'PC02', 'localhost'
            $r.ExitCode | Should -Be 0
            $r.Rows.ComputerName | Should -Be @('PC02', 'PC01')
            @($r.Calls | Where-Object { $_.ComputerName -eq 'PC02' }).Count | Should -Be 6
            @($r.Calls | Where-Object { -not $_.ComputerName }).Count | Should -Be 6
        }
    }

    Context 'Add or update' {

        It 'same serial again: the row is updated, not added' {
            $csv = New-CsvPath
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            (Invoke-Inventory -Csv $csv).ExitCode | Should -Be 0
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ' -Model 'OptiPlex 7010' -MemoryBytes 34200000000 -Monitors $script:Monitor1) }
            $r = Invoke-Inventory -Csv $csv
            $r.ExitCode | Should -Be 0
            $r.Rows.Count | Should -Be 1
            $r.Rows[0].Model    | Should -Be 'OptiPlex 7010'
            $r.Rows[0].MemoryGB | Should -Be '32'
            $r.Rows[0].Monitors | Should -Be 'DEL DELL P2422H SN:ABC1234'
            Get-FolderContent $csv | Should -Be @('hardware-inventory.csv')
        }

        It 'a renamed computer with the same serial replaces its row' {
            $csv = New-CsvPath
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            Invoke-Inventory -Csv $csv | Out-Null
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01-NEW' -Serial '5cd1234xyz') }
            $r = Invoke-Inventory -Csv $csv
            $r.Rows.Count | Should -Be 1
            $r.Rows[0].ComputerName | Should -Be 'PC01-NEW'
        }

        It 'a real serial is the key: the same name with another serial is a new row' {
            $csv = New-CsvPath
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            Invoke-Inventory -Csv $csv | Out-Null
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD5555NEW' -Model 'OptiPlex 7020') }
            $r = Invoke-Inventory -Csv $csv
            $r.ExitCode | Should -Be 0
            $r.Rows.SerialNumber | Should -Be @('5CD1234XYZ', '5CD5555NEW')
        }

        It 'a second computer is appended and the first row is kept as it was' {
            $csv = New-CsvPath
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            Invoke-Inventory -Csv $csv | Out-Null
            $first = (Get-Content -LiteralPath $csv)[1]
            Set-Scenario @{ PC02 = (New-TestComputer -Name 'PC02' -Serial '5CD9999ABC' -Model 'Latitude 5440') }
            $r = Invoke-Inventory -Csv $csv -Computers 'PC02'
            $r.ExitCode | Should -Be 0
            $r.Rows.ComputerName | Should -Be @('PC01', 'PC02')
            (Get-Content -LiteralPath $csv)[1] | Should -Be $first
            $r.Rows[1].Model | Should -Be 'Latitude 5440'
        }

        It 'placeholder serials are keyed by computer name' {
            $csv = New-CsvPath
            Set-Scenario @{
                PC03 = (New-TestComputer -Name 'PC03' -Serial 'To be filled by O.E.M.')
                PC04 = (New-TestComputer -Name 'PC04' -Serial 'To Be Filled By O.E.M.')
                PC05 = (New-TestComputer -Name 'PC05' -Serial ' ')
                PC06 = (New-TestComputer -Name 'PC06' -Serial 'Default string')
            }
            $r = Invoke-Inventory -Csv $csv -Computers 'PC03', 'PC04', 'PC05', 'PC06'
            $r.ExitCode | Should -Be 0
            $r.Rows.Count | Should -Be 4

            $global:InvScenario.Computers['PC03'] = New-TestComputer -Name 'PC03' -Serial 'To be filled by O.E.M.' -Model 'Changed'
            $r = Invoke-Inventory -Csv $csv -Computers 'PC03'
            $r.Rows.Count | Should -Be 4
            ($r.Rows | Where-Object { $_.ComputerName -eq 'PC03' }).Model | Should -Be 'Changed'
            ($r.Rows | Where-Object { $_.ComputerName -eq 'PC04' }).Model | Should -Be 'OptiPlex 7090'
        }

        It 'placeholder serial <Serial> is keyed by computer name' -ForEach @(
            @{ Serial = 'Default' }, @{ Serial = 'System Serial Number' }, @{ Serial = 'chassis serial number' },
            @{ Serial = 'Not Specified' }, @{ Serial = 'NOT APPLICABLE' }, @{ Serial = 'n/a' }, @{ Serial = ' OEM ' },
            @{ Serial = 'None' }, @{ Serial = '0' }, @{ Serial = '0123456789' }
        ) {
            Set-Scenario @{
                PC07 = (New-TestComputer -Name 'PC07' -Serial $Serial)
                PC08 = (New-TestComputer -Name 'PC08' -Serial $Serial)
            }
            $csv = New-CsvPath
            $r = Invoke-Inventory -Csv $csv -Computers 'PC07', 'PC08'
            $r.ExitCode | Should -Be 0
            $r.Rows.ComputerName | Should -Be @('PC07', 'PC08')
            $r = Invoke-Inventory -Csv $csv -Computers 'PC08'
            $r.Rows.ComputerName | Should -Be @('PC07', 'PC08')
        }

        It 'a file written by the older script: rows kept with the columns mapped, the same serial replaced' {
            $csv = New-CsvPath
            New-Item -ItemType Directory -Path (Split-Path -Parent $csv) -Force | Out-Null
            Set-Content -LiteralPath $csv -Value @(
                '"Hostname","Manufacturer","Model","Serial Number","Service Tag","IP Address","DHCP Status","Monitor 1 Serial Number"'
                '"OLD01","Example Computers Inc.","OptiPlex 3020","OLD-SERIAL-1","OLD-SERIAL-1","192.0.2.50","DHCP","ABC0001"'
                '"PC01","Example Computers Inc.","OptiPlex 3020","5CD1234XYZ","5CD1234XYZ","192.0.2.10","Static","ABC0002"'
            )
            $original = Get-Content -LiteralPath $csv -Raw
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            $r = Invoke-Inventory -Csv $csv
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'older format'
            $extra = @('Service Tag', 'IP Address', 'DHCP Status', 'Monitor 1 Serial Number')
            (Get-Content -LiteralPath $csv -TotalCount 1) | Should -Be ('"{0}"' -f ((@($script:Columns) + $extra) -join '","'))
            $r.Rows.Count | Should -Be 2
            $old = $r.Rows[0]
            $old.ComputerName  | Should -Be 'OLD01'
            $old.SerialNumber  | Should -Be 'OLD-SERIAL-1'
            $old.Model         | Should -Be 'OptiPlex 3020'
            $old.IPAddresses   | Should -BeNullOrEmpty
            $old.'IP Address'  | Should -Be '192.0.2.50'
            $old.'Service Tag' | Should -Be 'OLD-SERIAL-1'
            $r.Rows[1].ComputerName  | Should -Be 'PC01'
            $r.Rows[1].Model         | Should -Be 'OptiPlex 7090'
            $r.Rows[1].'IP Address'  | Should -Be '192.0.2.10'
            Get-Content -LiteralPath ($csv + '.bak') -Raw | Should -Be $original
        }

        It 'columns added by hand are kept with their values, and the .bak copy is made only once' {
            $csv = New-CsvPath
            $header = '"{0}","Owner","Location"' -f ($script:Columns -join '","')
            Set-TestCsv $csv @(
                $header
                '"PC01","Example Computers Inc.","OptiPlex 3020","5CD1234XYZ","1.0.0","Microsoft Windows 10 Pro","10.0.19045","Old CPU","8","192.0.2.10","00:00:5E:00:53:01","Yes","","2026-01-01 08:00","IT","Room 101"'
                '"PC02","Example Computers Inc.","OptiPlex 3020","5CD2222BBB","1.0.0","Microsoft Windows 10 Pro","10.0.19045","Old CPU","8","192.0.2.11","00:00:5E:00:53:02","Yes","","2026-01-01 08:00","Finance","Room 202"'
            )
            $original = Get-Content -LiteralPath $csv -Raw
            Set-Scenario @{
                PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ')
                PC03 = (New-TestComputer -Name 'PC03' -Serial '5CD3333CCC')
            }
            $r = Invoke-Inventory -Csv $csv -Computers 'PC01', 'PC03'
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Other columns kept: Owner, Location'
            (Get-Content -LiteralPath $csv -TotalCount 1) | Should -Be $header
            $r.Rows.ComputerName | Should -Be @('PC01', 'PC02', 'PC03')
            $r.Rows[0].Model | Should -Be 'OptiPlex 7090'
            $r.Rows[0].Owner | Should -Be 'IT'
            $r.Rows[0].Location | Should -Be 'Room 101'
            $r.Rows[1].Owner | Should -Be 'Finance'
            $r.Rows[2].Owner | Should -BeNullOrEmpty
            Get-Content -LiteralPath ($csv + '.bak') -Raw | Should -Be $original

            # second run: the .bak copy is not replaced
            Invoke-Inventory -Csv $csv -Computers 'PC03' | Out-Null
            Get-Content -LiteralPath ($csv + '.bak') -Raw | Should -Be $original
            Get-FolderContent $csv | Should -Be @('hardware-inventory.csv', 'hardware-inventory.csv.bak')
        }

        It 'the file is locked by another computer: waits and writes when the lock is released' {
            $csv = New-CsvPath
            Set-TestCsv ($csv + '.lock') @('PC09 2026-10-09 08:00:00')
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            $global:InvScenario.LockFile = $csv + '.lock'
            Mock Start-Sleep { Remove-Item -LiteralPath $global:InvScenario.LockFile }
            $r = Invoke-Inventory -Csv $csv
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'in use by PC09 2026-10-09 08:00:00, waiting'
            $r.Rows.ComputerName | Should -Be @('PC01')
            Should -Invoke Start-Sleep -Times 1 -Exactly
            Get-FolderContent $csv | Should -Be @('hardware-inventory.csv')
        }

        It 'a lock older than 10 minutes is taken over with a warning' {
            $csv = New-CsvPath
            Set-TestCsv ($csv + '.lock') @('PC09 2026-10-09 08:00:00')
            (Get-Item -LiteralPath ($csv + '.lock')).LastWriteTime = (Get-Date).AddMinutes(-11)
            Mock Start-Sleep {}
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            $r = Invoke-Inventory -Csv $csv
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Taking over .*hardware-inventory\.csv\.lock.*left by PC09'
            $r.Rows.ComputerName | Should -Be @('PC01')
            Should -Invoke Start-Sleep -Times 0 -Exactly
            Get-FolderContent $csv | Should -Be @('hardware-inventory.csv')
        }
    }

    Context 'Errors' {

        It 'an unreachable computer: exit 1, the others are written' {
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            $r = Invoke-Inventory -Csv (New-CsvPath) -Computers 'PC01', 'SRV99'
            $r.ExitCode | Should -Be 1
            $r.Rows.ComputerName | Should -Be @('PC01')
            $r.Output | Should -Match 'Could not read: SRV99'
        }

        It 'no computer could be read: exit 1 and no file' {
            Set-Scenario @{}
            $csv = New-CsvPath
            $r = Invoke-Inventory -Csv $csv -Computers 'SRV99'
            $r.ExitCode | Should -Be 1
            Test-Path -LiteralPath $csv | Should -BeFalse
        }

        It 'the lock is never released: exit 3 after about 30 seconds, the file and the lock are left alone' {
            $csv = New-CsvPath
            Set-TestCsv $csv @('"ComputerName","Owner"', '"PC09","IT"')
            Set-TestCsv ($csv + '.lock') @('PC09 2026-10-09 08:00:00')
            $before = Get-Content -LiteralPath $csv -Raw
            Mock Start-Sleep {}
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ') }
            $r = Invoke-Inventory -Csv $csv
            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'being updated by another computer \(PC09'
            Should -Invoke Start-Sleep -Times 31
            Get-Content -LiteralPath $csv -Raw | Should -Be $before
            Get-FolderContent $csv | Should -Be @('hardware-inventory.csv', 'hardware-inventory.csv.lock')
        }

        It 'the write fails: exit 3, the file is unchanged, no temporary or lock file is left' {
            $csv = New-CsvPath
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ'); PC02 = (New-TestComputer -Name 'PC02' -Serial '5CD2222BBB') }
            Invoke-Inventory -Csv $csv -Computers 'PC02' | Out-Null
            $before = Get-Content -LiteralPath $csv -Raw
            Set-FailingExport
            $r = Invoke-Inventory -Csv $csv -Computers 'PC01'
            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'ERROR: There is not enough space on the disk'
            Get-Content -LiteralPath $csv -Raw | Should -Be $before
            Get-FolderContent $csv | Should -Be @('hardware-inventory.csv')
        }

        It 'the folder cannot be listed (access denied): exit 3, never treated as a new file' {
            $csv = New-CsvPath
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ'); PC02 = (New-TestComputer -Name 'PC02' -Serial '5CD2222BBB') }
            Invoke-Inventory -Csv $csv -Computers 'PC02' | Out-Null
            $before = Get-Content -LiteralPath $csv -Raw
            $global:InvScenario.DeniedFolder = Split-Path -Parent $csv
            # Pester 6 does not fall back to the real command when no -ParameterFilter matches,
            # so one default mock handles both cases (the real cmdlet through its CmdletInfo, no recursion).
            Mock Get-ChildItem {
                if ($LiteralPath -eq $global:InvScenario.DeniedFolder) {
                    throw [System.UnauthorizedAccessException]::new('Access to the path is denied.')
                }
                & (Get-Command -Name Get-ChildItem -CommandType Cmdlet) @PesterBoundParameters
            }
            $r = Invoke-Inventory -Csv $csv -Computers 'PC01'
            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'ERROR: Access to the path is denied'
            Get-Content -LiteralPath $csv -Raw | Should -Be $before
            Test-Path -LiteralPath ($csv + '.lock') | Should -BeFalse
        }

        It 'the file cannot be read: exit 3, the file is not replaced' {
            $csv = New-CsvPath
            Set-Scenario @{ PC01 = (New-TestComputer -Name 'PC01' -Serial '5CD1234XYZ'); PC02 = (New-TestComputer -Name 'PC02' -Serial '5CD2222BBB') }
            Invoke-Inventory -Csv $csv -Computers 'PC02' | Out-Null
            $before = Get-Content -LiteralPath $csv -Raw
            Mock Import-Csv { throw [System.UnauthorizedAccessException]::new('Access to the path is denied.') }
            $run = @{ CsvPath = $csv; ComputerName = @('PC01') }
            $output = & $script:Target @run *>&1 | Out-String
            $LASTEXITCODE | Should -Be 3
            $output | Should -Match 'ERROR: Access to the path is denied'
            Get-Content -LiteralPath $csv -Raw | Should -Be $before
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $csv) -Force).Name | Should -Be @('hardware-inventory.csv')
        }
    }
}
