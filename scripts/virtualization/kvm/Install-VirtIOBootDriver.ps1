#Requires -Version 5.1
<#
.SYNOPSIS
    Checks and installs the VirtIO drivers a Windows VM needs before migration to KVM: vioscsi and viostor as boot drivers, NetKVM staged.

.DESCRIPTION
    Run inside the Windows VM before it is migrated or restored to a KVM based platform
    (for example HPE Morpheus VM Essentials, Proxmox VE, OpenStack). The source platform does not
    matter (VMware, Hyper-V).

    Windows loads a storage driver at boot only when its service is set to boot start. A VM that has
    never seen a VirtIO controller has no vioscsi or viostor service, so after the migration it stops
    with INACCESSIBLE_BOOT_DEVICE (0x7B). The script prepares the drivers in advance:

        vioscsi  VirtIO SCSI controller    Driver Store + boot-start service
        viostor  VirtIO block device       Driver Store + boot-start service
        netkvm   VirtIO network adapter    Driver Store only, Windows installs it when the adapter appears

    Without -Fix the script only reports. For each driver it checks:
      - the driver package is in the Driver Store (Get-WindowsDriver), and its version
      - the service key: Type, Start = 0 (boot), ErrorControl, Group, and the values the driver INF
        writes under Parameters (PnpInterface, BusType ...)
      - the driver file that ImagePath points to exists
      - no StartOverride value overrides Start
    It also saves the IP configuration of every network adapter to network-config.csv. On KVM the
    network adapter is a new device, and a static IP stays on the old, hidden adapter.

    With -Fix it changes only what the check found:
      - adds the driver package from the virtio-win media to the Driver Store
        (pnputil /add-driver without /install: nothing is installed on existing devices)
      - creates or corrects the service key with the values from the INF of the staged package
      - places the driver file where the INF does: System32\drivers (copied from the Driver Store,
        never over a newer file), or the Driver Store itself when the INF runs it from there
        (Windows 11 and Server 2025 builds)
      - sets StartOverride values to 0
    Then it checks again and gives the final verdict. -WhatIf shows the changes without making them.
    Every run with -Fix writes a transcript.

    The driver folder on the media is chosen from the build number and product type, exact match only:
    Windows 10, Windows 11, Windows Server 2016, 2019, 2022 and 2025, x64. Windows Server 2012 R2 and
    older are not supported. For another server build, check the virtio-win release notes and use -OsFolder.

    Requirements: elevated 64-bit PowerShell. For -Fix, the virtio-win ISO attached to the VM, or its
    content in a folder (-VirtIOPath).

.PARAMETER VirtIOPath
    Root of the virtio-win media: the ISO drive (E:\), an extracted folder or a share.
    Default: the CD/DVD drive that holds the vioscsi and viostor folders.

.PARAMETER OsFolder
    Driver folder on the media: 2k16, 2k19, 2k22, 2k25, w10 or w11. Default: chosen from the OS build.

.PARAMETER SkipNetKVM
    Do not check or stage the VirtIO network driver (when the target VM uses another adapter type).

.PARAMETER Fix
    Apply the changes. Without it the script is read-only.

.PARAMETER OutputPath
    Folder for the report, the network configuration and the transcript.
    Default: %USERPROFILE%\InfraToolkit-Output\Install-VirtIOBootDriver\<timestamp>

.EXAMPLE
    .\Install-VirtIOBootDriver.ps1
    Report only.

.EXAMPLE
    .\Install-VirtIOBootDriver.ps1 -Fix -WhatIf
    Show what would change.

.EXAMPLE
    .\Install-VirtIOBootDriver.ps1 -Fix
    Prepare the VM with the virtio-win ISO attached. Asks before each driver; add -Confirm:$false to skip.

.EXAMPLE
    .\Install-VirtIOBootDriver.ps1 -Fix -VirtIOPath \\SRV01\iso\virtio-win
    Use the extracted media from a share.

.NOTES
    Mode: Read-only (changes with -Fix)
    Network: none
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = ready, 1 = action required, 2 = manual check required, 3 = the script could not run.
    Target VM: boot disk on a VirtIO SCSI controller (vioscsi) or as a VirtIO block device (viostor).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$VirtIOPath,

    [ValidateSet('2k16', '2k19', '2k22', '2k25', 'w10', 'w11')]
    [string]$OsFolder,

    [switch]$SkipNetKVM,

    [switch]$Fix,

    [string]$OutputPath = (Join-Path $env:USERPROFILE ('InfraToolkit-Output\{0}\{1}' -f
        ($MyInvocation.MyCommand.Name -replace '\.ps1$', ''), (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants
$ServicesKey    = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$DriversDir     = Join-Path $env:SystemRoot 'System32\drivers'
$PnpOkExitCodes = @(0, 259, 3010)    # 259 = no device to install on, 3010 = restart required
$NoVersion      = [version]'0.0.0.0'

$SEV_OK     = 0
$SEV_ACTION = 1
$SEV_CHECK  = 2
$EXIT_NOT_RUN = 3

$Drivers = @(
    [pscustomobject]@{ Name = 'vioscsi'; MediaFolder = 'vioscsi'; Inf = 'vioscsi.inf'; Boot = $true;  Title = 'VirtIO SCSI controller' }
    [pscustomobject]@{ Name = 'viostor'; MediaFolder = 'viostor'; Inf = 'viostor.inf'; Boot = $true;  Title = 'VirtIO block device' }
    [pscustomobject]@{ Name = 'netkvm';  MediaFolder = 'NetKVM';  Inf = 'netkvm.inf';  Boot = $false; Title = 'VirtIO network adapter' }
)
if ($SkipNetKVM) { $Drivers = @($Drivers | Where-Object { $_.Boot }) }

$script:Report   = @()
$script:ExitCode = $EXIT_NOT_RUN

# ------------------------------------------------------------------ output helpers
function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $script:Report += $Text
}

function Format-Row {
    param([string]$Label, $Value)
    return (' {0,-18}: {1}' -f $Label, $Value)
}

function Get-Worse {
    param([int]$A, [int]$B)
    if ($B -gt $A) { return $B }
    return $A
}

function Get-VerdictText {
    param([int]$Sev)
    switch ($Sev) {
        0       { return 'READY' }
        1       { return 'ACTION REQUIRED' }
        default { return 'MANUAL CHECK REQUIRED' }
    }
}

function Get-VerdictColor {
    param([int]$Sev)
    switch ($Sev) {
        0       { return 'Green' }
        1       { return 'Red' }
        default { return 'Yellow' }
    }
}

# ------------------------------------------------------------------ generic helpers
function Get-PathLeaf {
    param([string]$Path)
    return @($Path -split '[\\/]')[-1]
}

function Get-PathParent {
    param([string]$Path)
    return ($Path -replace '[\\/][^\\/]*$', '')
}

function ConvertTo-Version {
    param($Value)
    if ($Value -and ([string]$Value -match '^\s*(\d+(\.\d+){1,3})')) {
        $parts = @($Matches[1] -split '\.')
        while ($parts.Count -lt 4) { $parts += '0' }
        return [version]($parts -join '.')
    }
    return $NoVersion
}

function ConvertTo-Int {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if ($t -match '^(0x[0-9a-fA-F]+|\d+)$') { return [int]$t }
    return $null
}

function Get-FileVersion {
    param([string]$Path)
    $vi = (Get-Item -LiteralPath $Path).VersionInfo
    if (-not $vi) { return $NoVersion }
    return [version]('{0}.{1}.{2}.{3}' -f [int]$vi.FileMajorPart, [int]$vi.FileMinorPart,
        [int]$vi.FileBuildPart, [int]$vi.FilePrivatePart)
}

function Resolve-ImagePath {
    # ImagePath of a kernel driver -> file system path
    param([string]$ImagePath)
    if (-not $ImagePath) { return '' }
    $p = $ImagePath.Trim().Trim('"')
    if ($p -match '^\\SystemRoot\\(.+)$')  { return (Join-Path $env:SystemRoot $Matches[1]) }
    if ($p -match '^%SystemRoot%\\(.+)$')  { return (Join-Path $env:SystemRoot $Matches[1]) }
    if ($p -match '^\\\?\?\\(.+)$')        { return $Matches[1] }
    if ($p -match '^[A-Za-z]:\\')          { return $p }
    return (Join-Path $env:SystemRoot $p.TrimStart('\'))
}

function ConvertTo-SystemRootPath {
    # Driver Store path -> ImagePath form (\SystemRoot\System32\DriverStore\...)
    param([string]$Path)
    $root = $env:SystemRoot.TrimEnd('\', '/')
    if ($Path.Length -gt $root.Length -and $Path.Substring(0, $root.Length) -eq $root) {
        return ('\SystemRoot\' + ($Path.Substring($root.Length).TrimStart('\', '/') -replace '/', '\'))
    }
    throw ('The Driver Store path is not under {0}: {1}' -f $root, $Path)
}

# ------------------------------------------------------------------ environment
function Test-Elevated {
    # High (S-1-16-12288) or System (S-1-16-16384) integrity level = elevated
    $ErrorActionPreference = 'Continue'
    $groups = @(& whoami.exe /groups /fo csv /nh 2>$null)
    return (@($groups -match 'S-1-16-(12288|16384)').Count -gt 0)
}

function Get-OsInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return [pscustomobject]@{
        Caption     = ([string]$os.Caption).Trim()
        Build       = [int]$os.BuildNumber
        ProductType = [int]$os.ProductType    # 1 = workstation, 2 = domain controller, 3 = server
    }
}

function Test-OsSupported {
    param($Os)
    if ($Os.ProductType -eq 1) { return ($Os.Build -ge 10240) }
    return ($Os.Build -ge 14393)
}

function Get-OsDriverFolder {
    # Exact match only. Windows 10 and 11 releases share one folder each, servers have one per LTSC build.
    param([int]$Build, [int]$ProductType)
    if ($ProductType -eq 1) {
        if ($Build -ge 22000) { return 'w11' }
        if ($Build -ge 10240) { return 'w10' }
        return ''
    }
    switch ($Build) {
        14393 { return '2k16' }
        17763 { return '2k19' }
        20348 { return '2k22' }
        26100 { return '2k25' }
    }
    return ''
}

# ------------------------------------------------------------------ virtio-win media
function Test-VirtIORoot {
    param([string]$Root)
    return ((Test-Path -LiteralPath (Join-Path $Root 'vioscsi')) -and (Test-Path -LiteralPath (Join-Path $Root 'viostor')))
}

function New-MediaInfo {
    param([string]$Root, [string]$Label, [string]$Note)
    return [pscustomobject]@{ Root = $Root; Label = $Label; Note = $Note }
}

function Find-VirtIOMedia {
    param([string]$Path)
    if ($Path) {
        if (-not (Test-VirtIORoot $Path)) {
            return (New-MediaInfo '' '' ('{0} is not virtio-win media (no vioscsi and viostor folders)' -f $Path))
        }
        $label = ''
        if ($Path -match '^([A-Za-z]:)\\?$') {
            $disk = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f $Matches[1]) -ErrorAction SilentlyContinue)
            if ($disk.Count -gt 0) { $label = [string]$disk[0].VolumeName }
        }
        return (New-MediaInfo $Path $label '')
    }
    $found = @()
    foreach ($cd in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 5' -ErrorAction SilentlyContinue)) {
        if (-not $cd.DeviceID) { continue }
        $root = '{0}\' -f $cd.DeviceID
        if (Test-VirtIORoot $root) { $found += (New-MediaInfo $root ([string]$cd.VolumeName) '') }
    }
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -gt 1) {
        return (New-MediaInfo '' '' ('More than one virtio-win media found ({0}). Choose one with -VirtIOPath' -f
            (($found | ForEach-Object { $_.Root }) -join ', ')))
    }
    return (New-MediaInfo '' '' 'No virtio-win media found. Attach the ISO or use -VirtIOPath')
}

function Get-MediaPackage {
    param($Media, $Driver, [string]$Folder)
    if (-not $Media.Root -or -not $Folder) { return $null }
    $dir = Join-Path $Media.Root ('{0}\{1}\amd64' -f $Driver.MediaFolder, $Folder)
    $inf = Join-Path $dir $Driver.Inf
    $exists = Test-Path -LiteralPath $inf
    $version = $NoVersion
    if ($exists) { $version = Get-InfDriverVersion $inf }
    return [pscustomobject]@{ Dir = $dir; InfPath = $inf; Exists = $exists; Version = $version }
}

# ------------------------------------------------------------------ INF parsing
function Remove-InfComment {
    param([string]$Line)
    if ($Line -match '^((?:[^;"]|"[^"]*")*)') { return $Matches[1].Trim() }
    return $Line.Trim()
}

function Read-InfSection {
    # INF file -> hashtable: lower-case section name -> lines without comments
    param([string]$Path)
    $sections = @{}
    $current = $null
    foreach ($raw in @(Get-Content -LiteralPath $Path)) {
        $line = Remove-InfComment ([string]$raw)
        if (-not $line) { continue }
        if ($line -match '^\[(.+)\]$') {
            $current = $Matches[1].Trim().ToLowerInvariant()
            if (-not $sections.ContainsKey($current)) { $sections[$current] = @() }
            continue
        }
        if ($null -ne $current) { $sections[$current] += $line }
    }
    return $sections
}

function Resolve-InfString {
    param([string]$Text, [hashtable]$Strings)
    $result = $Text
    foreach ($m in @([regex]::Matches($Text, '%([^%]+)%'))) {
        $key = $m.Groups[1].Value.ToLowerInvariant()
        if ($Strings.ContainsKey($key)) { $result = $result.Replace($m.Value, $Strings[$key]) }
    }
    return $result.Trim().Trim('"')
}

function Get-InfDriverVersion {
    param([string]$Path)
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]$line -match '^\s*DriverVer\s*=\s*[^,]*,\s*([\d.]+)') { return (ConvertTo-Version $Matches[1]) }
    }
    return $NoVersion
}

function Get-DefaultServiceDefinition {
    param([string]$Name)
    return [pscustomobject]@{
        ServiceName = $Name; ServiceType = 1; ErrorControl = 1; Group = 'SCSI miniport'
        Dirid = 12; BinaryName = "$Name.sys"; Values = @(); Source = 'defaults'
    }
}

function Get-InfServiceDefinition {
    # Service install section of a driver INF: binary location, service values, AddReg values.
    # Returns $null when the INF has no usable definition for the service.
    param([string]$InfPath, [string]$ServiceName)
    $inf = Read-InfSection $InfPath
    $strings = @{}
    if ($inf.ContainsKey('strings')) {
        foreach ($l in $inf['strings']) {
            if ($l -match '^([^=]+?)\s*=\s*(.*)$') { $strings[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim().Trim('"') }
        }
    }

    $installSection = ''
    foreach ($name in @($inf.Keys)) {
        foreach ($l in $inf[$name]) {
            if ($l -match '^AddService\s*=\s*"?([^,"]+)"?\s*,\s*[^,]*,\s*([^,]+?)\s*(,.*)?$' -and $Matches[1].Trim() -eq $ServiceName) {
                $installSection = $Matches[2].Trim().ToLowerInvariant()
            }
        }
    }
    if (-not $installSection -or -not $inf.ContainsKey($installSection)) { return $null }

    $def = Get-DefaultServiceDefinition $ServiceName
    $def.Source = $InfPath
    $def.Dirid = $null
    $addReg = @()
    foreach ($l in $inf[$installSection]) {
        if ($l -notmatch '^(\w+)\s*=\s*(.*)$') { continue }
        $key = $Matches[1]
        $value = Resolve-InfString $Matches[2] $strings
        switch ($key) {
            'ServiceType'    { $n = ConvertTo-Int $value; if ($null -ne $n) { $def.ServiceType = $n } }
            'ErrorControl'   { $n = ConvertTo-Int $value; if ($null -ne $n) { $def.ErrorControl = $n } }
            'LoadOrderGroup' { if ($value) { $def.Group = $value } }
            'AddReg'         { $addReg += @($value -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) }
            'ServiceBinary'  {
                if ($value -match '^%(\d+)%\\(.+)$') {
                    $def.Dirid = [int]$Matches[1]
                    $def.BinaryName = Get-PathLeaf $Matches[2]
                }
            }
        }
    }
    # 12 = System32\drivers, 13 = run from the Driver Store
    if ($def.Dirid -ne 12 -and $def.Dirid -ne 13) { return $null }

    $values = @()
    foreach ($section in $addReg) {
        if (-not $inf.ContainsKey($section)) { continue }
        foreach ($l in $inf[$section]) {
            if ($l -notmatch '^HKR\s*,(.*)$') { continue }
            $f = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"') })
            while ($f.Count -lt 4) { $f += '' }
            $flags = ConvertTo-Int (Resolve-InfString $f[2] $strings)
            if ($null -eq $flags) { $flags = 0 }
            $raw = Resolve-InfString $f[3] $strings
            switch ($flags) {
                0x00010001 { $type = 'DWord';        $data = ConvertTo-Int $raw }
                0x00020000 { $type = 'ExpandString'; $data = $raw }
                0          { $type = 'String';       $data = $raw }
                default    { $type = '' }    # key only or a type this script does not write
            }
            if (-not $type -or -not $f[1] -or $null -eq $data) { continue }
            $values += [pscustomobject]@{ Subkey = $f[0]; Name = $f[1]; Type = $type; Value = $data }
        }
    }
    $def.Values = $values
    return $def
}

# ------------------------------------------------------------------ Driver Store
function Select-StorePackage {
    # Newest package in the Driver Store with this INF name
    param($Packages, [string]$InfName)
    $best = $null
    foreach ($p in @($Packages)) {
        if (-not $p -or (Get-PathLeaf ([string]$p.OriginalFileName)) -ne $InfName) { continue }
        $v = ConvertTo-Version $p.Version
        if (-not $best -or $v -gt $best.Version) {
            $best = [pscustomobject]@{
                Driver  = [string]$p.Driver
                Version = $v
                InfPath = [string]$p.OriginalFileName
                Folder  = Get-PathParent ([string]$p.OriginalFileName)
            }
        }
    }
    return $best
}

function Invoke-PnpUtilAddDriver {
    param([string]$InfPath)
    # Windows PowerShell 5.1 turns redirected stderr into a terminating error under 'Stop'
    $ErrorActionPreference = 'Continue'
    $output = @(& pnputil.exe /add-driver $InfPath 2>&1)
    $code = $LASTEXITCODE
    foreach ($l in $output) { if (([string]$l).Trim()) { Out-Line ('    pnputil: {0}' -f ([string]$l).Trim()) 'DarkGray' } }
    return $code
}

# ------------------------------------------------------------------ registry
function Get-RegistryValue {
    # Values of a registry key as a hashtable, $null when the key does not exist
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $Key)) { return $null }
    $values = @{}
    $item = Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue
    if ($item) {
        foreach ($p in $item.PSObject.Properties) {
            if ($p.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { $values[$p.Name] = $p.Value }
        }
    }
    return $values
}

function New-RegistryKeyPath {
    param([string]$Key)
    if (Test-Path -LiteralPath $Key) { return }
    $parent = Get-PathParent $Key
    if ($parent -and $parent -ne $Key) { New-RegistryKeyPath $parent }
    New-Item -Path $Key -Confirm:$false | Out-Null
    Out-Line ('  Created key {0}' -f $Key)
}

function Set-RegistryValue {
    param([string]$Key, [string]$Name, [string]$Type, $Value)
    New-ItemProperty -LiteralPath $Key -Name $Name -PropertyType $Type -Value $Value -Force -Confirm:$false | Out-Null
    Out-Line ('  Set {0}\{1} = {2}' -f $Key, $Name, $Value)
}

function Get-ExpectedServiceValue {
    param($Definition)
    $base = @(
        [pscustomobject]@{ Subkey = ''; Name = 'Type';         Type = 'DWord';  Value = $Definition.ServiceType }
        [pscustomobject]@{ Subkey = ''; Name = 'Start';        Type = 'DWord';  Value = 0 }
        [pscustomobject]@{ Subkey = ''; Name = 'ErrorControl'; Type = 'DWord';  Value = $Definition.ErrorControl }
        [pscustomobject]@{ Subkey = ''; Name = 'Group';        Type = 'String'; Value = $Definition.Group }
    )
    return @($base + @($Definition.Values))
}

function Test-ValueMatch {
    param($Actual, $Expected)
    if ($null -eq $Actual) { return $false }
    if ($Expected.Type -eq 'DWord') {
        try { return ([int64]$Actual -eq [int64]$Expected.Value) } catch { return $false }
    }
    return ([string]$Actual -eq [string]$Expected.Value)
}

function Get-ServiceState {
    param([string]$ServiceName, $Expected)
    $key = '{0}\{1}' -f $ServicesKey, $ServiceName
    $values = Get-RegistryValue $key
    $state = [pscustomobject]@{
        Key = $key; Exists = ($null -ne $values); Values = $values; Mismatches = @()
        StartOverride = @{}; BinaryPath = ''; BinaryExists = $false
    }
    if (-not $state.Exists) { return $state }

    $cache = @{ '' = $values }
    foreach ($e in @($Expected)) {
        if (-not $cache.ContainsKey($e.Subkey)) { $cache[$e.Subkey] = Get-RegistryValue ('{0}\{1}' -f $key, $e.Subkey) }
        $actual = $null
        if ($cache[$e.Subkey]) { $actual = $cache[$e.Subkey][$e.Name] }
        if (-not (Test-ValueMatch $actual $e)) {
            $state.Mismatches += [pscustomobject]@{ Expected = $e; Actual = $actual }
        }
    }
    $so = Get-RegistryValue ('{0}\StartOverride' -f $key)
    if ($so) { $state.StartOverride = $so }
    $state.BinaryPath = Resolve-ImagePath ([string]$values['ImagePath'])
    if ($state.BinaryPath) { $state.BinaryExists = [bool](Test-Path -LiteralPath $state.BinaryPath) }
    return $state
}

# ------------------------------------------------------------------ assessment
function Get-DriverState {
    param($Driver, $Packages, [string]$StoreError, $Media, [string]$Folder)
    $state = [pscustomobject]@{
        Store = $null; StoreError = $StoreError; Media = $null
        Definition = $null; DefinitionError = ''; Service = $null
    }
    if (-not $StoreError) { $state.Store = Select-StorePackage $Packages $Driver.Inf }
    $state.Media = Get-MediaPackage $Media $Driver $Folder
    if (-not $Driver.Boot) { return $state }

    # Reference for the service values: the staged INF, else the INF on the media, else defaults
    $source = ''
    if ($state.Store) { $source = $state.Store.InfPath }
    elseif ($state.Media -and $state.Media.Exists) { $source = $state.Media.InfPath }
    if ($source) {
        $def = $null
        try { $def = Get-InfServiceDefinition -InfPath $source -ServiceName $Driver.Name } catch { $def = $null }
        if ($def) { $state.Definition = $def }
        else { $state.DefinitionError = ('Cannot read the service definition of {0} from {1}' -f $Driver.Name, $source) }
    }
    if (-not $state.Definition) { $state.Definition = Get-DefaultServiceDefinition $Driver.Name }
    $state.Service = Get-ServiceState $state.Definition.ServiceName (Get-ExpectedServiceValue $state.Definition)
    return $state
}

function Get-DriverAssessment {
    param($Driver, $State)
    $sev = $SEV_OK
    $issues = @()
    $notes = @()

    if ($State.StoreError) {
        return [pscustomobject]@{ Severity = $SEV_CHECK; Issues = @('Cannot read the Driver Store: ' + $State.StoreError); Notes = @() }
    }
    if (-not $State.Store) {
        $sev = $SEV_ACTION
        if ($Driver.Boot) { $issues += 'Not in the Driver Store' }
        else { $issues += 'Not in the Driver Store: on KVM the VM starts without network' }
    }
    if ($State.Media -and $State.Media.Exists -and $State.Store -and $State.Media.Version -gt $State.Store.Version) {
        $notes += ('The media has a newer version ({0}) than the Driver Store' -f $State.Media.Version)
    }

    if ($Driver.Boot) {
        if ($State.DefinitionError) { $sev = (Get-Worse $sev $SEV_CHECK); $issues += $State.DefinitionError }
        $svc = $State.Service
        if (-not $svc.Exists) {
            $sev = (Get-Worse $sev $SEV_ACTION)
            $issues += 'Service key missing: Windows will not load the driver at boot'
        } else {
            foreach ($m in $svc.Mismatches) {
                $sev = (Get-Worse $sev $SEV_ACTION)
                $name = $m.Expected.Name
                if ($m.Expected.Subkey) { $name = '{0}\{1}' -f $m.Expected.Subkey, $m.Expected.Name }
                $actual = '(missing)'
                if ($null -ne $m.Actual) { $actual = [string]$m.Actual }
                $issues += ('{0} is {1}, expected {2}' -f $name, $actual, $m.Expected.Value)
            }
            if (-not $svc.BinaryPath) {
                $sev = (Get-Worse $sev $SEV_ACTION); $issues += 'ImagePath is empty'
            } elseif (-not $svc.BinaryExists) {
                $sev = (Get-Worse $sev $SEV_ACTION); $issues += ('Driver file not found: {0}' -f $svc.BinaryPath)
            }
            foreach ($k in @($svc.StartOverride.Keys)) {
                if ([int]$svc.StartOverride[$k] -ne 0) {
                    $sev = (Get-Worse $sev $SEV_ACTION)
                    $issues += ('StartOverride\{0} = {1} overrides Start' -f $k, $svc.StartOverride[$k])
                }
            }
        }
    }
    return [pscustomobject]@{ Severity = [int]$sev; Issues = $issues; Notes = $notes }
}

function Get-Assessment {
    param($Media, [string]$Folder)
    $packages = @()
    $storeError = ''
    try { $packages = @(Get-WindowsDriver -Online -ErrorAction Stop) } catch { $storeError = $_.Exception.Message }
    $items = @()
    foreach ($d in $Drivers) {
        $state = Get-DriverState -Driver $d -Packages $packages -StoreError $storeError -Media $Media -Folder $Folder
        $items += [pscustomobject]@{ Driver = $d; State = $state; Result = (Get-DriverAssessment $d $state) }
    }
    return $items
}

function Write-DriverReport {
    param($Item)
    $d = $Item.Driver
    $s = $Item.State
    $kind = 'Driver Store only'
    if ($d.Boot) { $kind = 'boot driver' }
    Out-Line ''
    Out-Line ('[{0}] {1} - {2}' -f $d.Name, $d.Title, $kind) 'White'

    $store = 'not staged'
    if ($s.StoreError) { $store = 'cannot be read' }
    elseif ($s.Store) { $store = '{0} ({1})' -f $s.Store.Version, $s.Store.Driver }
    Out-Line (Format-Row 'Driver Store' $store)

    if ($s.Media) {
        if ($s.Media.Exists) { Out-Line (Format-Row 'Media' ('{0} in {1}' -f $s.Media.Version, $s.Media.Dir)) }
        else { Out-Line (Format-Row 'Media' ('no {0}' -f $s.Media.InfPath)) }
    }

    if ($d.Boot) {
        $svc = $s.Service
        if ($svc.Exists) {
            $v = $svc.Values
            Out-Line (Format-Row 'Service' ('Start={0} Type={1} ErrorControl={2} Group={3}' -f $v['Start'], $v['Type'], $v['ErrorControl'], $v['Group']))
            $file = $svc.BinaryPath
            if (-not $file) { $file = '(no ImagePath)' }
            elseif (-not $svc.BinaryExists) { $file += ' (not found)' }
            Out-Line (Format-Row 'Driver file' $file)
        } else {
            Out-Line (Format-Row 'Service' 'missing')
        }
    }

    $r = $Item.Result
    Out-Line (Format-Row 'Status' (Get-VerdictText $r.Severity)) (Get-VerdictColor $r.Severity)
    foreach ($i in $r.Issues) { Out-Line ('   - {0}' -f $i) (Get-VerdictColor $r.Severity) }
    foreach ($n in $r.Notes) { Out-Line ('   . {0}' -f $n) 'DarkGray' }
}

# ------------------------------------------------------------------ changes (-Fix)
function Install-DriverBinary {
    # Places the driver file where the INF does, returns the ImagePath value
    param($Definition, $Store)
    $source = Join-Path $Store.Folder $Definition.BinaryName
    if (-not (Test-Path -LiteralPath $source)) { throw ('Driver file not found in the Driver Store: {0}' -f $source) }
    if ($Definition.Dirid -eq 13) {
        Out-Line ('  The INF runs {0} from the Driver Store: {1}' -f $Definition.BinaryName, $source)
        return (ConvertTo-SystemRootPath $source)
    }
    $target = Join-Path $DriversDir $Definition.BinaryName
    $imagePath = '\SystemRoot\System32\drivers\{0}' -f $Definition.BinaryName
    if (Test-Path -LiteralPath $target) {
        $have = Get-FileVersion $target
        $new = Get-FileVersion $source
        if ($have -ne $NoVersion -and $have -ge $new) {
            Out-Line ('  Kept {0}: version {1}, the Driver Store has {2}' -f $target, $have, $new)
            return $imagePath
        }
    }
    Copy-Item -LiteralPath $source -Destination $target -Force -Confirm:$false
    Out-Line ('  Copied {0} to {1}' -f $source, $target)
    return $imagePath
}

function Invoke-DriverFix {
    param($Item)
    $d = $Item.Driver
    $store = $Item.State.Store

    if (-not $store) {
        $pkg = $Item.State.Media
        Out-Line ('  Adding {0} {1} to the Driver Store from {2}' -f $d.Inf, $pkg.Version, $pkg.Dir)
        $code = Invoke-PnpUtilAddDriver $pkg.InfPath
        if ($PnpOkExitCodes -notcontains $code) { Out-Line ('  pnputil exit code {0}' -f $code) 'Yellow' }
        $store = Select-StorePackage @(Get-WindowsDriver -Online -ErrorAction Stop) $d.Inf
        if (-not $store) { throw ('{0} is not in the Driver Store after pnputil (exit code {1})' -f $d.Inf, $code) }
        Out-Line ('  Staged {0} {1} ({2})' -f $d.Inf, $store.Version, $store.Driver)
    }
    if (-not $d.Boot) { return }

    $def = Get-InfServiceDefinition -InfPath $store.InfPath -ServiceName $d.Name
    if (-not $def) { throw ('Cannot read the service definition of {0} from {1}' -f $d.Name, $store.InfPath) }
    $key = '{0}\{1}' -f $ServicesKey, $def.ServiceName
    New-RegistryKeyPath $key

    $expected = Get-ExpectedServiceValue $def
    $svc = Get-ServiceState $def.ServiceName $expected
    if (-not $svc.BinaryExists) {
        Set-RegistryValue $key 'ImagePath' 'ExpandString' (Install-DriverBinary -Definition $def -Store $store)
    }
    foreach ($m in $svc.Mismatches) {
        $e = $m.Expected
        $target = $key
        if ($e.Subkey) { $target = '{0}\{1}' -f $key, $e.Subkey; New-RegistryKeyPath $target }
        Set-RegistryValue $target $e.Name $e.Type $e.Value
    }
    foreach ($k in @($svc.StartOverride.Keys)) {
        if ([int]$svc.StartOverride[$k] -ne 0) { Set-RegistryValue ('{0}\StartOverride' -f $key) $k 'DWord' 0 }
    }
}

# ------------------------------------------------------------------ network configuration
function Export-NetworkConfiguration {
    param([string]$Path)
    $names = @{}
    foreach ($a in @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue)) {
        if ($null -ne $a.InterfaceIndex) { $names[[string]$a.InterfaceIndex] = [string]$a.NetConnectionID }
    }
    $rows = @()
    foreach ($c in @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True')) {
        $rows += [pscustomobject]@{
            Name                 = $names[[string]$c.InterfaceIndex]
            Description          = [string]$c.Description
            MACAddress           = [string]$c.MACAddress
            DHCPEnabled          = [bool]$c.DHCPEnabled
            IPAddress            = (@($c.IPAddress) -join ';')
            IPSubnet             = (@($c.IPSubnet) -join ';')
            DefaultIPGateway     = (@($c.DefaultIPGateway) -join ';')
            DNSServerSearchOrder = (@($c.DNSServerSearchOrder) -join ';')
            DNSDomain            = [string]$c.DNSDomain
            DNSSuffixSearchOrder = (@($c.DNSSuffixSearchOrder) -join ';')
            WINSPrimaryServer    = [string]$c.WINSPrimaryServer
            WINSSecondaryServer  = [string]$c.WINSSecondaryServer
        }
    }
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
    }
    return $rows
}

function Write-NetworkReport {
    Out-Line ''
    Out-Line 'Network configuration' 'White'
    $csv = Join-Path $OutputPath 'network-config.csv'
    try {
        $rows = @(Export-NetworkConfiguration $csv)
    } catch {
        Out-Line ('   . Could not read the network configuration: {0}' -f $_.Exception.Message) 'Yellow'
        return 0
    }
    $static = @($rows | Where-Object { -not $_.DHCPEnabled })
    Out-Line (Format-Row 'Adapters' ('{0} with IP, {1} with a static IP' -f $rows.Count, $static.Count))
    foreach ($r in $static) {
        $name = $r.Name
        if (-not $name) { $name = $r.Description }
        Out-Line ('   {0}: {1} / {2}, gateway {3}, DNS {4}' -f $name, $r.IPAddress, $r.IPSubnet, $r.DefaultIPGateway, $r.DNSServerSearchOrder)
    }
    if ($rows.Count -gt 0) { Out-Line (Format-Row 'Saved to' $csv) }
    if ($static.Count -gt 0) {
        Out-Line '   . On KVM the network adapter is a new device. Set this configuration on it after the migration.' 'DarkGray'
        Out-Line '     Windows may say the IP is assigned to another adapter: that is the old, hidden adapter.' 'DarkGray'
    }
    return $static.Count
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param($Cmdlet)
    $modeText = 'Report only (use -Fix to change)'
    if ($Fix -and $WhatIfPreference) { $modeText = '-Fix -WhatIf (nothing is changed)' }
    elseif ($Fix) { $modeText = '-Fix' }

    Out-Line 'VirtIO driver readiness for migration to KVM' 'White'
    Out-Line (Format-Row 'Computer' $env:COMPUTERNAME)
    Out-Line (Format-Row 'Mode' $modeText)

    if (-not (Test-Elevated)) {
        Out-Line 'Run this script from an elevated PowerShell (Run as administrator).' 'Red'
        return $EXIT_NOT_RUN
    }
    if ($env:PROCESSOR_ARCHITEW6432) {
        Out-Line 'This is 32-bit PowerShell on 64-bit Windows. Run the script from 64-bit PowerShell.' 'Red'
        return $EXIT_NOT_RUN
    }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        Out-Line ('Not supported: x64 only. This system is {0}.' -f $env:PROCESSOR_ARCHITECTURE) 'Red'
        return $EXIT_NOT_RUN
    }

    $os = Get-OsInfo
    $kind = 'server'
    if ($os.ProductType -eq 1) { $kind = 'workstation' }
    Out-Line (Format-Row 'Operating system' ('{0} (build {1}, {2})' -f $os.Caption, $os.Build, $kind))
    if (-not (Test-OsSupported $os)) {
        Out-Line 'Not supported: this script covers Windows 10, Windows 11 and Windows Server 2016 or later (x64).' 'Red'
        return $EXIT_NOT_RUN
    }

    $folder = $OsFolder
    $folderText = '{0}\amd64 (set with -OsFolder)' -f $folder
    if (-not $folder) {
        $folder = Get-OsDriverFolder -Build $os.Build -ProductType $os.ProductType
        $folderText = '{0}\amd64 (from the OS build)' -f $folder
        if (-not $folder) { $folderText = 'no exact match for build {0}: check the virtio-win release notes and use -OsFolder' -f $os.Build }
    }
    Out-Line (Format-Row 'Driver folder' $folderText)

    $media = Find-VirtIOMedia $VirtIOPath
    if ($media.Root) {
        $mediaText = $media.Root
        if ($media.Label) { $mediaText += ' ({0})' -f $media.Label }
        Out-Line (Format-Row 'VirtIO media' $mediaText)
    } else {
        Out-Line (Format-Row 'VirtIO media' $media.Note)
    }

    Out-Line ''
    Out-Line 'Reading the Driver Store and the service keys ...' 'DarkGray'
    $items = @(Get-Assessment -Media $media -Folder $folder)
    foreach ($i in $items) { Write-DriverReport $i }

    $toFix = @($items | Where-Object { $_.Result.Severity -eq $SEV_ACTION })
    if ($Fix -and $toFix.Count -gt 0) {
        # Every precondition is checked before the first change
        foreach ($i in @($toFix | Where-Object { -not $_.State.Store })) {
            $why = ''
            if (-not $folder) { $why = 'No driver folder for build {0}. Use -OsFolder.' -f $os.Build }
            elseif (-not $media.Root) { $why = $media.Note }
            elseif (-not $i.State.Media.Exists) { $why = 'The media has no {0}. Use a virtio-win release that supports this OS.' -f $i.State.Media.InfPath }
            if ($why) {
                Out-Line ''
                Out-Line ('Cannot fix {0}: {1}' -f $i.Driver.Name, $why) 'Red'
                Out-Line 'Nothing was changed.' 'Red'
                return $EXIT_NOT_RUN
            }
        }

        Out-Line ''
        Out-Line 'Changes' 'White'
        foreach ($i in $toFix) {
            $action = 'Configure {0} as a boot-start driver' -f $i.Driver.Name
            if (-not $i.State.Store) {
                $action = 'Add {0} {1} to the Driver Store' -f $i.Driver.Inf, $i.State.Media.Version
                if ($i.Driver.Boot) { $action += ' and configure it as a boot-start driver' }
            }
            if ($Cmdlet.ShouldProcess($env:COMPUTERNAME, $action)) {
                Out-Line ('[{0}]' -f $i.Driver.Name) 'White'
                try { Invoke-DriverFix $i | Out-Null }
                catch { Out-Line ('  FAILED: {0}' -f $_.Exception.Message) 'Red' }
            }
        }

        if (-not $WhatIfPreference) {
            Out-Line ''
            Out-Line 'After the changes' 'White'
            $items = @(Get-Assessment -Media $media -Folder $folder)
            foreach ($i in $items) {
                $r = $i.Result
                Out-Line (Format-Row $i.Driver.Name (Get-VerdictText $r.Severity)) (Get-VerdictColor $r.Severity)
                foreach ($x in $r.Issues) { Out-Line ('   - {0}' -f $x) (Get-VerdictColor $r.Severity) }
            }
        } else {
            Out-Line 'WhatIf: nothing was changed.' 'Yellow'
        }
    } elseif ($Fix) {
        Out-Line ''
        Out-Line 'Nothing to change.' 'Green'
    }

    $staticCount = Write-NetworkReport

    $worst = $SEV_OK
    foreach ($i in $items) { $worst = Get-Worse $worst $i.Result.Severity }

    Out-Line ''
    $overall = Get-VerdictText $worst
    if ($worst -eq $SEV_OK) { $overall = 'READY FOR MIGRATION' }
    Out-Line ('OVERALL: {0}' -f $overall) (Get-VerdictColor $worst)
    Out-Line 'Next steps:' 'White'
    switch ($worst) {
        0 {
            Out-Line ' - Restart the VM once on the current platform and run this script again: it must still show READY.'
            Out-Line ' - On KVM: boot disk on a VirtIO SCSI controller (vioscsi) or as a VirtIO block device (viostor).'
            if ($staticCount -gt 0) { Out-Line ' - On KVM: set the saved static IP configuration on the new network adapter.' }
        }
        1 {
            if ($Fix -and -not $WhatIfPreference) { Out-Line ' - Review the failed items above, fix the cause and run again with -Fix.' }
            elseif ($Fix) { Out-Line ' - Run again with -Fix and without -WhatIf to apply the changes.' }
            else { Out-Line ' - Attach the virtio-win ISO (or use -VirtIOPath) and run again with -Fix.' }
        }
        default { Out-Line ' - Review the items marked MANUAL CHECK REQUIRED above.' }
    }
    return [int]$worst
}

$transcript = $null
try {
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
    $reportFile = Join-Path $OutputPath 'report.txt'
    Out-Line ''
    Out-Line (Format-Row 'Report' $reportFile) 'Cyan'
    if ($transcript) { Out-Line (Format-Row 'Transcript' $transcript) 'Cyan' }
    try {
        $script:Report | Out-File -LiteralPath $reportFile -Encoding UTF8 -WhatIf:$false -Confirm:$false
    } catch {
        Write-Warning ('Could not save the report: {0}' -f $_.Exception.Message)
    }
    if ($transcript) { Stop-Transcript | Out-Null }
}
exit $script:ExitCode
