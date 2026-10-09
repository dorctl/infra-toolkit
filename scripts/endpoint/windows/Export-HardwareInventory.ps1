#Requires -Version 5.1

<#
.SYNOPSIS
    Adds or updates the hardware of Windows computers (model, serial, CPU, RAM, IP, monitors) in a CSV inventory.

.DESCRIPTION
    Reads the hardware details of each computer with Get-CimInstance and writes one row per computer
    to a CSV file. Run it on each computer (for example from a logon script or a scheduled task) with
    -CsvPath on a share, so many computers write to one file, or from an admin station with -ComputerName.
    Without -CsvPath the file is next to the script, so a script started from a share where the computers
    can write also gives one shared file.

    Columns, the same for every computer so the file stays consistent:
        ComputerName, Manufacturer, Model, SerialNumber, BiosVersion, OperatingSystem, OsVersion, Cpu,
        MemoryGB, IPAddresses, MacAddresses, DhcpEnabled, Monitors, CollectedAt

      - IPAddresses, MacAddresses and DhcpEnabled (Yes / No) have one entry per network adapter with IP
        enabled, in the same order, separated by '; '. Only IPv4 addresses are listed. An adapter with
        more than one IPv4 address lists them separated by ', ', an adapter without one shows '-'.
      - Monitors: "<manufacturer> <model> SN:<serial>" for each monitor, separated by '; '. Empty on
        servers and virtual machines that report no monitors (not an error).
      - MemoryGB: the memory visible to Windows, rounded to whole GB.
      - CollectedAt: local time of the computer that ran the script, yyyy-MM-dd HH:mm.

    A computer's row is found by its BIOS serial number. When the serial is empty or a placeholder
    (To be filled by O.E.M., Default string, Default, System Serial Number, Chassis Serial Number,
    Not Specified, Not Applicable, N/A, None, OEM, 0, 0123456789; not case sensitive) it is found by
    computer name instead. That row is replaced, every other row is kept.

    Other columns in the file (for example Owner or Location added by hand) are kept, and their
    values stay on the row when the script replaces it. Older files of the previous inventory script:
    Hostname goes to ComputerName and Serial Number to SerialNumber, the other columns are kept as
    they are. Before the script first rewrites a file whose columns differ from the list above, it
    saves a copy as <file>.bak (once: an existing .bak is not replaced). Starting a fresh file is
    recommended.

    Shared file: many computers can run the script against one file at the same time. While a
    computer updates the file it holds <file>.lock, created only when it does not exist yet, so the
    others wait for it (a short random wait, up to 30 seconds, then exit 3). It writes the new file
    as a temporary file in the same folder and then replaces the old one, so a reader never sees a
    half-written file. A lock file older than 10 minutes is left over from a computer that stopped:
    it is taken over with a warning. A file that exists but cannot be read (access denied, damaged)
    stops the script with exit 3: it is never replaced by a new file. While someone has the file open
    in Excel it cannot be replaced: the script exits 3 and the file is unchanged.

    Uses Get-CimInstance only (Win32_ComputerSystem, Win32_BIOS, Win32_OperatingSystem, Win32_Processor,
    Win32_NetworkAdapterConfiguration, root\wmi WmiMonitorID), so it runs in Constrained Language Mode.
    Remote computers are read over WinRM (Get-CimInstance -ComputerName) and need admin rights there.

.PARAMETER ComputerName
    Computers to read. Default: the local computer.

.PARAMETER CsvPath
    The inventory file. It can be a UNC path on a share that many computers write to.
    Default: InfraToolkit-Output\Export-HardwareInventory\hardware-inventory.csv in the folder of the script
    (falls back to %TEMP%\InfraToolkit-Output\Export-HardwareInventory\hardware-inventory.csv when that folder
    cannot be written or is in OneDrive).

.EXAMPLE
    .\Export-HardwareInventory.ps1
    Add or update the local computer in the default file.

.EXAMPLE
    .\Export-HardwareInventory.ps1 -CsvPath \\SRV01\Inventory$\hardware-inventory.csv
    Add or update the local computer in a file on a share.

.EXAMPLE
    .\Export-HardwareInventory.ps1 -ComputerName PC01, PC02, PC03 -CsvPath C:\Temp\hardware-inventory.csv
    Read three remote computers over WinRM.

.NOTES
    Mode: Read-only
    Network: none (remote computers in -ComputerName are read over WinRM)
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = written, 1 = some computers could not be read (the others were written),
                3 = the script could not run (the file could not be read, locked or written,
                unexpected error). The CSV is the output of the script, like a report.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'

$EXIT_OK      = 0
$EXIT_ACTION  = 1
$EXIT_NOT_RUN = 3

$Columns = @('ComputerName', 'Manufacturer', 'Model', 'SerialNumber', 'BiosVersion', 'OperatingSystem', 'OsVersion',
             'Cpu', 'MemoryGB', 'IPAddresses', 'MacAddresses', 'DhcpEnabled', 'Monitors', 'CollectedAt')
# Columns of older files, mapped to the columns of this script
$LegacyColumns      = @{ ComputerName = 'Hostname'; SerialNumber = 'Serial Number' }
$PlaceholderSerials = @('To be filled by O.E.M.', 'Default string', 'Default', 'System Serial Number',
                        'Chassis Serial Number', 'Not Specified', 'Not Applicable', 'N/A', 'None', 'OEM',
                        '0', '0123456789')
$LockWaitSeconds    = 30
$StaleLockMinutes   = 10

$script:ExitCode = $EXIT_NOT_RUN

# ------------------------------------------------------------------ helpers
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

function Test-LocalComputer {
    param([string]$Name)
    return ($Name -eq '.' -or $Name -eq 'localhost' -or $Name -eq $env:COMPUTERNAME)
}

function Get-CimData {
    param([string]$Computer, [string]$ClassName, [string]$Namespace = '', [string]$Filter = '')
    $query = @{ ClassName = $ClassName; ErrorAction = 'Stop' }
    if ($Namespace) { $query['Namespace'] = $Namespace }
    if ($Filter) { $query['Filter'] = $Filter }
    if (-not (Test-LocalComputer $Computer)) { $query['ComputerName'] = $Computer }
    return @(Get-CimInstance @query)
}

function Get-CleanText {
    # Trims and collapses repeated spaces (CPU names are padded)
    param($Value)
    return ((([string]$Value) -replace '\s+', ' ').Trim())
}

function ConvertFrom-MonitorString {
    # WmiMonitorID strings are arrays of character codes padded with zeros
    param($Codes)
    $chars = @(@($Codes) | Where-Object { $_ } | ForEach-Object { [string][char][int]$_ })
    return (Get-CleanText ($chars -join ''))
}

function Test-PlaceholderSerial {
    param([string]$Serial)
    $s = $Serial.Trim()
    if (-not $s) { return $true }
    foreach ($p in $PlaceholderSerials) { if ($s -eq $p) { return $true } }
    return $false
}

function Get-InventoryKey {
    # BIOS serial number, or the computer name when the serial is empty or a placeholder
    param($Row)
    if (-not (Test-PlaceholderSerial ([string]$Row.SerialNumber))) {
        return ('SN:{0}' -f ([string]$Row.SerialNumber).Trim().ToUpperInvariant())
    }
    return ('NAME:{0}' -f ([string]$Row.ComputerName).Trim().ToUpperInvariant())
}

# ------------------------------------------------------------------ collection
function Get-CpuText {
    param($Processors)
    $names = @($Processors | ForEach-Object { Get-CleanText $_.Name } | Where-Object { $_ })
    $parts = @($names | Group-Object | ForEach-Object {
        if ($_.Count -gt 1) { '{0} x {1}' -f $_.Count, $_.Name } else { $_.Name }
    })
    return ($parts -join '; ')
}

function Get-MonitorText {
    param($Monitors)
    $parts = @(foreach ($m in @($Monitors)) {
        if (-not $m) { continue }
        $words = @((ConvertFrom-MonitorString $m.ManufacturerName), (ConvertFrom-MonitorString $m.UserFriendlyName)) | Where-Object { $_ }
        ((@($words) + ('SN:{0}' -f (ConvertFrom-MonitorString $m.SerialNumberID))) -join ' ')
    })
    return ($parts -join '; ')
}

function Get-HardwareRow {
    param([string]$Computer)
    $cs   = @(Get-CimData -Computer $Computer -ClassName 'Win32_ComputerSystem')[0]
    $bios = @(Get-CimData -Computer $Computer -ClassName 'Win32_BIOS')[0]
    $os   = @(Get-CimData -Computer $Computer -ClassName 'Win32_OperatingSystem')[0]
    $cpus = @(Get-CimData -Computer $Computer -ClassName 'Win32_Processor')
    $nics = @(Get-CimData -Computer $Computer -ClassName 'Win32_NetworkAdapterConfiguration' -Filter 'IPEnabled = True')
    if (-not $cs -or -not $bios -or -not $os) { throw 'Win32_ComputerSystem, Win32_BIOS or Win32_OperatingSystem returned nothing' }

    $monitors = @()
    try {
        $monitors = @(Get-CimData -Computer $Computer -ClassName 'WmiMonitorID' -Namespace 'root\wmi')
    } catch {
        # Servers and virtual machines often have no monitor information
        Write-Verbose ('{0}: no monitor information ({1})' -f $Computer, $_.Exception.Message)
    }

    $ips = @(); $macs = @(); $dhcp = @()
    foreach ($n in $nics) {
        $v4 = @(@($n.IPAddress) | Where-Object { [string]$_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
        $ip = $v4 -join ', '
        if (-not $ip) { $ip = '-' }
        $mac = [string]$n.MACAddress
        if (-not $mac) { $mac = '-' }
        $ips += $ip
        $macs += $mac
        if ($n.DHCPEnabled) { $dhcp += 'Yes' } else { $dhcp += 'No' }
    }

    $memory = ''
    if ($cs.TotalPhysicalMemory) { $memory = [string][int64][math]::Round([double]$cs.TotalPhysicalMemory / 1GB) }

    $biosVersion = Get-CleanText $bios.SMBIOSBIOSVersion
    if (-not $biosVersion) { $biosVersion = Get-CleanText $bios.Version }

    $name = Get-CleanText $cs.Name
    if (-not $name) { $name = $Computer.ToUpperInvariant() }

    $row = [ordered]@{
        ComputerName    = $name
        Manufacturer    = Get-CleanText $cs.Manufacturer
        Model           = Get-CleanText $cs.Model
        SerialNumber    = Get-CleanText $bios.SerialNumber
        BiosVersion     = $biosVersion
        OperatingSystem = Get-CleanText $os.Caption
        OsVersion       = Get-CleanText $os.Version
        Cpu             = Get-CpuText $cpus
        MemoryGB        = $memory
        IPAddresses     = $ips -join '; '
        MacAddresses    = $macs -join '; '
        DhcpEnabled     = $dhcp -join '; '
        Monitors        = Get-MonitorText $monitors
        CollectedAt     = Get-Date -Format 'yyyy-MM-dd HH:mm'
    }
    return [pscustomobject]$row
}

# ------------------------------------------------------------------ CSV file
function Get-ExtraColumn {
    # Columns of the file that are not columns of this script (Owner, Location ...), in file order.
    # An old column name that is mapped to a column of this script (Hostname, Serial Number) is not kept.
    param([string[]]$Header)
    $mapped = @(foreach ($c in $LegacyColumns.Keys) { if ($Header -notcontains $c) { $LegacyColumns[$c] } })
    return @($Header | Where-Object { $Columns -notcontains $_ -and $mapped -notcontains $_ })
}

function ConvertTo-InventoryRow {
    # A row read from the file: the columns of this script (older names mapped) and the extra columns
    param($Row, [string[]]$Header, [string[]]$Extra)
    $o = [ordered]@{}
    foreach ($c in $Columns) {
        $value = ''
        if ($Header -contains $c) { $value = [string]$Row.$c }
        elseif ($LegacyColumns.ContainsKey($c) -and $Header -contains $LegacyColumns[$c]) { $value = [string]$Row.($LegacyColumns[$c]) }
        $o[$c] = $value
    }
    foreach ($x in @($Extra)) { $o[$x] = [string]$Row.$x }
    return [pscustomobject]$o
}

function Join-InventoryRow {
    # A new row with the extra column values of the row it replaces (empty for a new computer)
    param($Row, $Old, [string[]]$Extra)
    $o = [ordered]@{}
    foreach ($c in $Columns) { $o[$c] = $Row.$c }
    foreach ($x in @($Extra)) {
        $value = ''
        if ($Old) { $value = [string]$Old.$x }
        $o[$x] = $value
    }
    return [pscustomobject]$o
}

function Merge-InventoryRow {
    # Existing rows with the key of a new row are replaced in place, the other new rows are appended
    param($Existing, $New, [string[]]$Extra)
    $newByKey = @{}
    foreach ($n in @($New)) { $newByKey[(Get-InventoryKey $n)] = $n }
    $done = @{}
    $merged = @(foreach ($e in @($Existing)) {
        $key = Get-InventoryKey $e
        if (-not $newByKey.ContainsKey($key)) { $e; continue }
        if (-not $done.ContainsKey($key)) { $done[$key] = $true; Join-InventoryRow -Row $newByKey[$key] -Old $e -Extra $Extra }
    })
    $merged += @(foreach ($n in @($New)) {
        $key = Get-InventoryKey $n
        if (-not $done.ContainsKey($key)) { $done[$key] = $true; Join-InventoryRow -Row $newByKey[$key] -Old $null -Extra $Extra }
    })
    return $merged
}

function Get-ParentFolder {
    param([string]$Path)
    $folder = Split-Path -Path $Path -Parent
    if (-not $folder) { $folder = '.' }
    return $folder
}

function Read-InventoryFile {
    # Rows of the file. The folder is listed instead of Test-Path, because Test-Path answers "not found"
    # when access is denied: a file that exists but cannot be read must never be treated as a new file.
    param([string]$Path)
    $leaf = Split-Path -Path $Path -Leaf
    $found = @(Get-ChildItem -LiteralPath (Get-ParentFolder $Path) -Force -ErrorAction Stop | Where-Object { $_.Name -eq $leaf })
    $file = [pscustomobject]@{ Exists = ($found.Count -gt 0); Rows = @(); Extra = @(); Differs = $false; Mapped = $false }
    if (-not $file.Exists) { return $file }
    if ($found[0].PSIsContainer) { throw ('{0} is a folder, not a CSV file' -f $Path) }

    $raw = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
    if ($raw.Count -eq 0) { return $file }
    $header = @($raw[0].PSObject.Properties | ForEach-Object { $_.Name })
    $file.Differs = (($header -join '|') -ne ($Columns -join '|'))
    $file.Mapped = (@($Columns | Where-Object { $header -notcontains $_ }).Count -gt 0)
    $file.Extra = @(Get-ExtraColumn -Header $header)
    $file.Rows = @(foreach ($r in $raw) { ConvertTo-InventoryRow -Row $r -Header $header -Extra $file.Extra })
    return $file
}

function Get-LockOwner {
    param([string]$LockPath)
    $owner = @(Get-Content -LiteralPath $LockPath -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($owner.Count -gt 0 -and $owner[0]) { return [string]$owner[0] }
    return 'unknown'
}

function Enter-InventoryLock {
    # Creates the lock file. New-Item without -Force fails when the file exists, so only one computer
    # at a time holds it. Others wait a short random time and try again, up to $LockWaitSeconds.
    param([string]$LockPath)
    $waitedMs = 0
    $missing = 0
    $tookOver = $false
    while ($true) {
        $lastError = ''
        try {
            New-Item -ItemType File -Path $LockPath -Value ('{0} {1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ErrorAction Stop | Out-Null
            return
        } catch {
            $lastError = $_.Exception.Message
        }

        $lock = Get-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        if (-not $lock) {
            # Released in the meantime, or the folder cannot be written: stop after a few tries
            $missing++
            if ($missing -ge 3) { throw ('Cannot create the lock file {0}: {1}' -f $LockPath, $lastError) }
            continue
        }
        if (-not $tookOver -and $lock.LastWriteTime -lt (Get-Date).AddMinutes(-$StaleLockMinutes)) {
            Write-Warning ('Taking over {0}: it is older than {1} minutes (left by {2})' -f $LockPath, $StaleLockMinutes, (Get-LockOwner $LockPath))
            $tookOver = $true
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            continue
        }
        if ($waitedMs -ge ($LockWaitSeconds * 1000)) {
            throw ('The file is being updated by another computer ({0}, lock file {1}). Run the script again later.' -f (Get-LockOwner $LockPath), $LockPath)
        }
        if ($waitedMs -eq 0) { Write-Host ('  {0} is in use by {1}, waiting ...' -f $LockPath, (Get-LockOwner $LockPath)) -ForegroundColor Yellow }
        $pause = Get-Random -Minimum 200 -Maximum 1000
        Start-Sleep -Milliseconds $pause
        $waitedMs += $pause
    }
}

function Update-InventoryFile {
    # Read, update and replace the file while holding the lock. The new content is written to a temporary
    # file in the same folder and moved over the old file, so readers never see a half-written file.
    param([string]$Path, $NewRows)
    $lockPath = '{0}.lock' -f $Path
    Enter-InventoryLock -LockPath $lockPath
    $temp = ''
    try {
        $file = Read-InventoryFile -Path $Path
        $merged = @(Merge-InventoryRow -Existing $file.Rows -New $NewRows -Extra $file.Extra)

        $temp = Join-Path (Get-ParentFolder $Path) ('{0}.{1}-{2}.tmp' -f (Split-Path -Path $Path -Leaf), $env:COMPUTERNAME, (Get-Random))
        $merged | Select-Object -Property (@($Columns) + @($file.Extra)) |
            Export-Csv -LiteralPath $temp -NoTypeInformation -Encoding UTF8

        $backup = ''
        if ($file.Differs) {
            $bak = '{0}.bak' -f $Path
            if (-not (Test-Path -LiteralPath $bak)) {
                Copy-Item -LiteralPath $Path -Destination $bak
                $backup = $bak
            }
        }
        if ($file.Exists) { Move-Item -LiteralPath $temp -Destination $Path -Force }
        else { Move-Item -LiteralPath $temp -Destination $Path }
        $temp = ''
        return [pscustomobject]@{ Rows = $merged.Count; Mapped = $file.Mapped; Extra = $file.Extra; Backup = $backup }
    } finally {
        if ($temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    $rows = @()
    $failed = @()
    foreach ($computer in $ComputerName) {
        Write-Host ('Reading {0} ...' -f $computer) -ForegroundColor Cyan
        try {
            $row = Get-HardwareRow -Computer $computer
            $rows += $row
            Write-Host (($row | Format-List | Out-String -Width 200).Trim())
            Write-Host ''
        } catch {
            $failed += $computer
            Write-Host ('  FAILED: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host 'No computer could be read. Nothing was written.' -ForegroundColor Red
        return $EXIT_ACTION
    }

    if (-not $CsvPath) {
        $CsvPath = Join-Path (Get-OutputFolder -ScriptRoot $PSScriptRoot -ScriptName 'Export-HardwareInventory') 'hardware-inventory.csv'
    }
    $folder = Split-Path -Path $CsvPath -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    $result = Update-InventoryFile -Path $CsvPath -NewRows $rows
    if ($result.Backup) { Write-Host ('Copy of the previous file: {0}' -f $result.Backup) -ForegroundColor Yellow }
    if ($result.Mapped) {
        Write-Host ('{0} had columns of an older format: Hostname was moved to ComputerName and Serial Number to' -f $CsvPath) -ForegroundColor Yellow
        Write-Host 'SerialNumber. Starting a fresh file is recommended.' -ForegroundColor Yellow
    }
    if (@($result.Extra).Count -gt 0) { Write-Host ('Other columns kept: {0}' -f (@($result.Extra) -join ', ')) -ForegroundColor Yellow }
    Write-Host ('Inventory : {0} ({1} computer(s) written, {2} row(s) in the file)' -f $CsvPath, $rows.Count, $result.Rows) -ForegroundColor Green

    if ($failed.Count -gt 0) {
        Write-Host ('Could not read: {0}' -f ($failed -join ', ')) -ForegroundColor Red
        return $EXIT_ACTION
    }
    return $EXIT_OK
}

try {
    $result = @(Invoke-Main)
    $script:ExitCode = [int]$result[-1]
} catch {
    Write-Host ('ERROR: {0}' -f $_.Exception.Message) -ForegroundColor Red
    $script:ExitCode = $EXIT_NOT_RUN
}
exit $script:ExitCode
