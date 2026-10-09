#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Install-VirtIOBootDriver.ps1 - verdicts, exit codes and -Fix changes against a mocked Windows.

.DESCRIPTION
    Get-CimInstance, Get-WindowsDriver, pnputil.exe, whoami.exe and the registry cmdlets are replaced by
    global functions backed by an in-memory scenario. The virtio-win media, the Driver Store and
    System32\drivers are folders in TestDrive. No Windows system is needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Install-VirtIOBootDriver.ps1'
    $script:SvcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services'

    $script:SavedEnv = @{}
    foreach ($n in 'SystemRoot', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_ARCHITEW6432', 'COMPUTERNAME') {
        $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n)
    }
    $env:COMPUTERNAME = 'SRV01'

    # ------------------------------------------------------------------ fake registry
    function global:Get-VioRegId {
        param([string]$Key)
        return (($Key -replace '/', '\').TrimEnd('\').ToLowerInvariant())
    }

    function global:Set-TestRegKey {
        param([string]$Key, [hashtable]$Values = @{})
        $id = Get-VioRegId $Key
        if (-not $global:VioReg.ContainsKey($id)) { $global:VioReg[$id] = @{ Path = $Key; Values = @{}; Types = @{} } }
        foreach ($k in $Values.Keys) { $global:VioReg[$id].Values[$k] = $Values[$k] }
    }

    function script:Remove-TestRegKey {
        param([string]$Key)
        $id = Get-VioRegId $Key
        foreach ($k in @($global:VioReg.Keys)) {
            if ($k -eq $id -or $k.StartsWith("$id\")) { $global:VioReg.Remove($k) }
        }
    }

    function script:Get-TestRegValue {
        param([string]$Key, [string]$Name)
        $id = Get-VioRegId $Key
        if (-not $global:VioReg.ContainsKey($id)) { return $null }
        return $global:VioReg[$id].Values[$Name]
    }

    function script:Get-TestRegType {
        param([string]$Key, [string]$Name)
        return $global:VioReg[(Get-VioRegId $Key)].Types[$Name]
    }

    function script:Get-FirstPath {
        param($Path, $LiteralPath)
        return @(@($LiteralPath) + @($Path) | Where-Object { $_ })[0]
    }

    # Registry paths go to the fake registry, everything else to the real cmdlet
    function global:Test-Path {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, $PathType, [switch]$IsValid)
        $p = Get-FirstPath $Path $LiteralPath
        if ($p -like 'HKLM:*') { return $global:VioReg.ContainsKey((Get-VioRegId $p)) }
        Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
    }

    function global:Get-ItemProperty {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Parameter(Position = 1)][string[]]$Name)
        $p = Get-FirstPath $Path $LiteralPath
        if ($p -like 'HKLM:*') {
            $id = Get-VioRegId $p
            if (-not $global:VioReg.ContainsKey($id)) { return }
            $o = [ordered]@{}
            foreach ($k in $global:VioReg[$id].Values.Keys) { $o[$k] = $global:VioReg[$id].Values[$k] }
            $o['PSPath'] = $p
            return [pscustomobject]$o
        }
        Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters
    }

    function global:New-Item {
        [CmdletBinding(SupportsShouldProcess)]
        param([Parameter(Position = 0)][string[]]$Path, [string]$ItemType, [switch]$Force, $Value, [string]$Name)
        $p = Get-FirstPath $Path $null
        if ($p -like 'HKLM:*') {
            $id = Get-VioRegId $p
            $parent = $id -replace '\\[^\\]+$', ''
            if (-not $global:VioReg.ContainsKey($parent)) { throw "Parent key does not exist: $parent" }
            if ($global:VioReg.ContainsKey($id)) { throw "Key already exists: $id" }
            $global:VioReg[$id] = @{ Path = $p; Values = @{}; Types = @{} }
            return [pscustomobject]@{ PSPath = $p }
        }
        Microsoft.PowerShell.Management\New-Item @PSBoundParameters
    }

    function global:New-ItemProperty {
        [CmdletBinding(SupportsShouldProcess)]
        param([string[]]$Path, [string[]]$LiteralPath, [string]$Name, [string]$PropertyType, $Value, [switch]$Force)
        $p = Get-FirstPath $Path $LiteralPath
        if ($p -like 'HKLM:*') {
            $id = Get-VioRegId $p
            if (-not $global:VioReg.ContainsKey($id)) { throw "Key does not exist: $id" }
            $global:VioReg[$id].Values[$Name] = $Value
            $global:VioReg[$id].Types[$Name] = $PropertyType
            return
        }
        Microsoft.PowerShell.Management\New-ItemProperty @PSBoundParameters
    }

    # File versions come from the scenario (wildcard patterns), other files from the real cmdlet
    function global:Get-Item {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [switch]$Force)
        $p = (Get-FirstPath $Path $LiteralPath) -replace '\\', '/'
        foreach ($pattern in @($global:VioScenario.FileVersions.Keys)) {
            if ($p -like $pattern) {
                $v = [version]$global:VioScenario.FileVersions[$pattern]
                return [pscustomobject]@{ VersionInfo = [pscustomobject]@{
                    FileMajorPart = $v.Major; FileMinorPart = $v.Minor; FileBuildPart = $v.Build; FilePrivatePart = $v.Revision } }
            }
        }
        Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
    }

    # ------------------------------------------------------------------ fake Windows
    function global:Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        $s = $global:VioScenario
        switch ($ClassName) {
            'Win32_OperatingSystem' {
                return [pscustomobject]@{ Caption = $s.Os.Caption; BuildNumber = [string]$s.Os.Build; ProductType = $s.Os.ProductType }
            }
            'Win32_LogicalDisk' {
                if ($Filter -match "DeviceID = '(.+)'") { $id = $Matches[1]; return @($s.Disks | Where-Object { $_.DeviceID -eq $id }) }
                return @($s.Disks)
            }
            'Win32_NetworkAdapter'              { return @($s.Adapters) }
            'Win32_NetworkAdapterConfiguration' { return @($s.NicConfigs) }
        }
    }

    function global:Get-WindowsDriver {
        [CmdletBinding()]
        param([switch]$Online, [switch]$All)
        if ($global:VioScenario.StoreError) { throw $global:VioScenario.StoreError }
        return @($global:VioScenario.Store)
    }

    function global:whoami.exe {
        if ($global:VioScenario.Elevated) { '"Mandatory Label\High Mandatory Level","Label","S-1-16-12288",""' }
        else { '"Mandatory Label\Medium Mandatory Level","Label","S-1-16-8192",""' }
        $global:LASTEXITCODE = 0
    }

    # pnputil /add-driver <inf>: copies the package folder into the Driver Store and registers it
    function global:pnputil.exe {
        $s = $global:VioScenario
        $s.PnpCalls += , @($args)
        if ($s.PnpExitCode) { 'Failed to add the driver package.'; $global:LASTEXITCODE = $s.PnpExitCode; return }
        $inf = ([string]$args[1]) -replace '\\', '/'
        $leaf = Split-Path -Leaf $inf
        $version = ''
        foreach ($l in (Get-Content -LiteralPath $inf)) { if ($l -match '^DriverVer=[^,]+,([\d.]+)') { $version = $Matches[1] } }
        $dest = Join-Path $env:SystemRoot ('System32/DriverStore/FileRepository/{0}_amd64_{1}' -f $leaf, ([guid]::NewGuid().ToString('N').Substring(0, 16)))
        $null = Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $dest -Force
        Copy-Item -Path (Join-Path (Split-Path -Parent $inf) '*') -Destination $dest
        $s.Store += [pscustomobject]@{
            Driver = ('oem{0}.inf' -f (10 + @($s.Store).Count)); OriginalFileName = (Join-Path $dest $leaf)
            Version = $version; ProviderName = 'Example Vendor'; ClassName = 'SCSIAdapter'
        }
        'Driver package added successfully.'
        $global:LASTEXITCODE = 0
    }

    # ------------------------------------------------------------------ virtio-win media
    function script:New-TestInfText {
        param([string]$Name, [string]$Version, [int]$Dirid, [int]$BusType, [switch]$Network)
        if ($Network) {
            return @"
[Version]
Signature="`$WINDOWS NT`$"
Class=Net
Provider=%VENDOR%
DriverVer=01/01/2026,$Version
CatalogFile=netkvm.cat

[Strings]
VENDOR = "Example Vendor"
"@
        }
        $bus = '0x{0:X8}' -f $BusType
        return @"
;
; $Name.inf - same structure as the upstream INF
;
[Version]
Signature="`$Windows NT`$"
Class=SCSIAdapter
ClassGUID={4D36E97B-E325-11CE-BFC1-08002BE10318}
Provider=%VENDOR%
DriverVer=01/01/2026,$Version ; stamped
CatalogFile=$Name.cat
PnpLockdown=1

[DestinationDirs]
$($Name)_Files_Driver = $Dirid

[scsi_inst.Services]
AddService = $Name, 0x00000002 , scsi_Service_Inst, scsi_EventLog_Inst

[scsi_Service_Inst]
DisplayName    = %SvcDesc%
ServiceType    = %SERVICE_KERNEL_DRIVER%
StartType      = %SERVICE_BOOT_START%
ErrorControl   = %SERVICE_ERROR_NORMAL%
ServiceBinary  = %$Dirid%\$Name.sys
LoadOrderGroup = SCSI miniport
AddReg         = pnpsafe_pci_addreg

[scsi_EventLog_Inst]
AddReg = scsi_EventLog_AddReg

[scsi_EventLog_AddReg]
HKR,,EventMessageFile,%REG_EXPAND_SZ%,"%%SystemRoot%%\System32\IoLogMsg.dll"
HKR,,TypesSupported,%REG_DWORD%,7

[pnpsafe_pci_addreg]
HKR, "Parameters\PnpInterface", "5", %REG_DWORD%, 0x00000001
HKR, "Parameters", "BusType", %REG_DWORD%, $bus
HKR, "Parameters", DmaRemappingCompatible,0x00010001,0

[Strings]
VENDOR = "Example Vendor"
SvcDesc = "VirtIO $Name Service"
REG_EXPAND_SZ  = 0x00020000
REG_DWORD      = 0x00010001
SERVICE_KERNEL_DRIVER  = 1
SERVICE_BOOT_START     = 0
SERVICE_ERROR_NORMAL   = 1
"@
    }

    # Same layout as the virtio-win ISO. Windows 11 and Server 2025 builds run the driver from the Driver Store (13).
    function script:New-TestMedia {
        param([string]$Root, [string[]]$Folders, [string]$Version = '100.100.104.27100')
        foreach ($f in $Folders) {
            $dirid = 12
            if ($f -in 'w11', '2k25') { $dirid = 13 }
            foreach ($d in @(@{ N = 'vioscsi'; Dir = 'vioscsi'; Bus = 10 }, @{ N = 'viostor'; Dir = 'viostor'; Bus = 1 }, @{ N = 'netkvm'; Dir = 'NetKVM'; Bus = 0 })) {
                $p = Join-Path $Root ('{0}/{1}/amd64' -f $d.Dir, $f)
                $null = Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $p -Force
                Set-Content -LiteralPath (Join-Path $p "$($d.N).inf") -Value (New-TestInfText $d.N $Version $dirid $d.Bus -Network:($d.N -eq 'netkvm'))
                Set-Content -LiteralPath (Join-Path $p "$($d.N).sys") -Value "$($d.N) $Version"
                Set-Content -LiteralPath (Join-Path $p "$($d.N).cat") -Value 'catalog'
            }
        }
    }

    # A VM prepared the way the INF would do it (2k22: driver files in System32\drivers)
    function script:Set-TestReadyVm {
        param([string]$Media, [string]$Folder)
        foreach ($d in @(@{ N = 'vioscsi'; Dir = 'vioscsi' }, @{ N = 'viostor'; Dir = 'viostor' }, @{ N = 'netkvm'; Dir = 'NetKVM' })) {
            $null = pnputil.exe /add-driver (Join-Path $Media ('{0}/{1}/amd64/{2}.inf' -f $d.Dir, $Folder, $d.N))
        }
        foreach ($d in @(@{ N = 'vioscsi'; Bus = 10 }, @{ N = 'viostor'; Bus = 1 })) {
            Set-Content -LiteralPath (Join-Path $env:SystemRoot "System32/drivers/$($d.N).sys") -Value 'driver'
            $key = "$script:SvcKey\$($d.N)"
            Set-TestRegKey $key @{ Type = 1; Start = 0; ErrorControl = 1; Group = 'SCSI miniport'; ImagePath = "\SystemRoot\System32\drivers\$($d.N).sys" }
            Set-TestRegKey "$key\Parameters" @{ BusType = $d.Bus; DmaRemappingCompatible = 0 }
            Set-TestRegKey "$key\Parameters\PnpInterface" @{ '5' = 1 }
        }
    }

    $script:AllFolders = @('w10', 'w11', '2k16', '2k19', '2k22', '2k25')
    $script:Server2022 = @{ Caption = 'Microsoft Windows Server 2022 Standard'; Build = 20348; ProductType = 3 }

    function script:Invoke-Scenario {
        param(
            [hashtable]$Os = $script:Server2022,
            [string[]]$MediaFolders = $script:AllFolders,
            [switch]$NoMedia,
            [switch]$NoMediaParameter,
            [string]$Ready,
            [scriptblock]$Setup,
            [hashtable]$Params = @{},
            [hashtable]$Scenario = @{},
            [string]$Script = $script:Target,
            [switch]$DefaultOutputPath
        )
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:SystemRoot = Join-Path $root 'Windows'
        $null = Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path (Join-Path $env:SystemRoot 'System32/drivers') -Force

        $global:VioReg = @{}
        Set-TestRegKey $script:SvcKey
        $global:VioScenario = @{
            Os = $Os; Elevated = $true; Store = @(); StoreError = ''; PnpCalls = @(); PnpExitCode = 0
            Disks = @(); Adapters = @(); NicConfigs = @(); FileVersions = @{}
        }
        foreach ($k in $Scenario.Keys) { $global:VioScenario[$k] = $Scenario[$k] }
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        if ($Scenario.Arch) { $env:PROCESSOR_ARCHITECTURE = $Scenario.Arch }
        $env:PROCESSOR_ARCHITEW6432 = $null
        if ($Scenario.Wow64) { $env:PROCESSOR_ARCHITEW6432 = 'AMD64' }

        $media = Join-Path $root 'media'
        if (-not $NoMedia) { New-TestMedia $media $MediaFolders }
        if ($Ready) { Set-TestReadyVm $media $Ready }
        if ($Setup) { & $Setup ([pscustomobject]@{ Root = $root; Media = $media }) }
        $global:VioScenario.PnpCalls = @()

        $run = @{} + $Params
        if (-not $NoMedia -and -not $NoMediaParameter) { $run['VirtIOPath'] = $media }
        $out = Join-Path $root 'out'
        if (-not $DefaultOutputPath) { $run['OutputPath'] = $out }
        & $Script @run *> $null
        $code = $LASTEXITCODE

        $reportFile = Join-Path $out 'report.txt'
        $report = ''
        if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $reportFile) { $report = Get-Content -LiteralPath $reportFile -Raw }
        return [pscustomobject]@{
            ExitCode = $code; Report = $report; Out = $out; Root = $root
            PnpCalls = @($global:VioScenario.PnpCalls); Drivers = (Join-Path $env:SystemRoot 'System32/drivers')
        }
    }

    $script:FixParams = @{ Fix = $true; Confirm = $false }
}

AfterAll {
    foreach ($f in 'Get-VioRegId', 'Set-TestRegKey', 'Test-Path', 'Get-ItemProperty', 'New-Item', 'New-ItemProperty',
                   'Get-Item', 'Get-CimInstance', 'Get-WindowsDriver', 'whoami.exe', 'pnputil.exe') {
        # "Function:\global:<name>" does not remove anything: the provider path takes no scope prefix
        Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name VioReg, VioScenario -Scope Global -ErrorAction SilentlyContinue
    foreach ($n in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
}

Describe 'Install-VirtIOBootDriver' {

    Context 'Report only' {

        It 'prepared VM: ready (exit 0), nothing called' {
            $r = Invoke-Scenario -Ready '2k22'
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match 'OVERALL: READY FOR MIGRATION'
            $r.Report   | Should -Not -Match 'static IP configuration'
            $r.PnpCalls.Count | Should -Be 0
        }

        It 'fresh VM: action required (exit 1) and nothing is changed' {
            $r = Invoke-Scenario
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'Not in the Driver Store'
            $r.Report   | Should -Match 'Service key missing'
            $r.Report   | Should -Match 'run again with -Fix'
            $r.PnpCalls.Count | Should -Be 0
            $global:VioReg.Count | Should -Be 1
        }

        It 'Start is not boot start' {
            $r = Invoke-Scenario -Ready '2k22' -Setup { Set-TestRegKey "$script:SvcKey\vioscsi" @{ Start = 3 } }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'Start is 3, expected 0'
        }

        It 'StartOverride overrides Start' {
            $r = Invoke-Scenario -Ready '2k22' -Setup { Set-TestRegKey "$script:SvcKey\viostor\StartOverride" @{ '0' = 3 } }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'StartOverride\\0 = 3 overrides Start'
        }

        It 'service without the Parameters values of the INF' {
            $r = Invoke-Scenario -Ready '2k22' -Setup { Remove-TestRegKey "$script:SvcKey\vioscsi\Parameters" }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'Parameters\\PnpInterface\\5 is \(missing\), expected 1'
            $r.Report   | Should -Match 'Parameters\\BusType is \(missing\), expected 10'
        }

        It 'driver file missing' {
            $r = Invoke-Scenario -Ready '2k22' -Setup { Remove-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/drivers/viostor.sys') }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'Driver file not found'
        }

        It 'Group in another casing is accepted' {
            $r = Invoke-Scenario -Ready '2k22' -Setup { Set-TestRegKey "$script:SvcKey\vioscsi" @{ Group = 'SCSI Miniport' } }
            $r.ExitCode | Should -Be 0
        }

        It 'NetKVM not staged: action required, unless -SkipNetKVM' {
            $drop = { $global:VioScenario.Store = @($global:VioScenario.Store | Where-Object { $_.OriginalFileName -notlike '*netkvm.inf' }) }
            $r = Invoke-Scenario -Ready '2k22' -Setup $drop
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'starts without network'

            $r = Invoke-Scenario -Ready '2k22' -Setup $drop -Params @{ SkipNetKVM = $true }
            $r.ExitCode | Should -Be 0
        }

        It 'Driver Store cannot be read: manual check (exit 2)' {
            $r = Invoke-Scenario -Ready '2k22' -Scenario @{ StoreError = 'Access is denied.' }
            $r.ExitCode | Should -Be 2
            $r.Report   | Should -Match 'Cannot read the Driver Store: Access is denied'
        }

        It 'media newer than the Driver Store is reported' {
            $r = Invoke-Scenario -Ready '2k22' -Setup {
                param($ctx)
                New-TestMedia (Join-Path $ctx.Root 'media') @('2k22') '100.101.0.0'
            }
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match 'newer version \(100\.101\.0\.0\)'
        }
    }

    Context 'Cannot run (exit 3)' {

        It 'not elevated, and the report is still saved' {
            $r = Invoke-Scenario -Scenario @{ Elevated = $false }
            $r.ExitCode | Should -Be 3
            $r.Report   | Should -Match 'Run as administrator'
        }

        It 'Windows Server 2012 R2 is not supported' {
            $r = Invoke-Scenario -Os @{ Caption = 'Microsoft Windows Server 2012 R2 Standard'; Build = 9600; ProductType = 3 }
            $r.ExitCode | Should -Be 3
            $r.Report   | Should -Match 'Not supported'
        }

        It '32-bit PowerShell on 64-bit Windows' {
            $r = Invoke-Scenario -Scenario @{ Arch = 'x86'; Wow64 = $true }
            $r.ExitCode | Should -Be 3
            $r.Report   | Should -Match '64-bit PowerShell'
        }

        It 'ARM64 is not supported' {
            $r = Invoke-Scenario -Scenario @{ Arch = 'ARM64' }
            $r.ExitCode | Should -Be 3
        }
    }

    Context 'Driver folder from the OS build' {

        It 'build <Build>, product type <Type> uses <Folder>' -ForEach @(
            @{ Build = 14393; Type = 3; Folder = '2k16' }
            @{ Build = 17763; Type = 3; Folder = '2k19' }
            @{ Build = 20348; Type = 2; Folder = '2k22' }
            @{ Build = 26100; Type = 3; Folder = '2k25' }
            @{ Build = 19045; Type = 1; Folder = 'w10' }
            @{ Build = 22631; Type = 1; Folder = 'w11' }
            @{ Build = 26100; Type = 1; Folder = 'w11' }
        ) {
            $r = Invoke-Scenario -Os @{ Caption = 'Microsoft Windows'; Build = $Build; ProductType = $Type } -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.PnpCalls.Count | Should -Be 3
            ($r.PnpCalls[0][1] -replace '\\', '/') | Should -Match "/vioscsi/$Folder/amd64/vioscsi\.inf$"
        }

        It 'unknown server build: report works, -Fix needs -OsFolder' {
            $os = @{ Caption = 'Microsoft Windows Server Datacenter'; Build = 25398; ProductType = 3 }
            $r = Invoke-Scenario -Os $os -Ready '2k22'
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match 'no exact match for build 25398'

            $r = Invoke-Scenario -Os $os -Params $FixParams
            $r.ExitCode | Should -Be 3
            $r.Report   | Should -Match 'Use -OsFolder'
            $r.PnpCalls.Count | Should -Be 0

            $r = Invoke-Scenario -Os $os -Params @{ Fix = $true; Confirm = $false; OsFolder = '2k22' }
            $r.ExitCode | Should -Be 0
            ($r.PnpCalls[0][1] -replace '\\', '/') | Should -Match '/2k22/amd64/'
        }
    }

    Context '-Fix' {

        It 'fresh Server 2022 VM: stages the drivers and writes the service keys like the INF (driver files in System32\drivers)' {
            $r = Invoke-Scenario -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.PnpCalls.Count | Should -Be 3
            $r.Report | Should -Match 'After the changes'

            foreach ($d in @(@{ N = 'vioscsi'; Bus = 10 }, @{ N = 'viostor'; Bus = 1 })) {
                $key = "$script:SvcKey\$($d.N)"
                Get-TestRegValue $key 'Type'         | Should -Be 1
                Get-TestRegValue $key 'Start'        | Should -Be 0
                Get-TestRegValue $key 'ErrorControl' | Should -Be 1
                Get-TestRegValue $key 'Group'        | Should -Be 'SCSI miniport'
                Get-TestRegValue $key 'ImagePath'    | Should -Be "\SystemRoot\System32\drivers\$($d.N).sys"
                Get-TestRegType  $key 'ImagePath'    | Should -Be 'ExpandString'
                Get-TestRegValue "$key\Parameters" 'BusType' | Should -Be $d.Bus
                Get-TestRegValue "$key\Parameters" 'DmaRemappingCompatible' | Should -Be 0
                Get-TestRegValue "$key\Parameters\PnpInterface" '5' | Should -Be 1
                Get-Content -LiteralPath (Join-Path $r.Drivers "$($d.N).sys") | Should -Be "$($d.N) 100.100.104.27100"
            }
            # The event log values of the INF belong to another key
            Get-TestRegValue "$script:SvcKey\vioscsi" 'TypesSupported' | Should -BeNullOrEmpty
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeTrue
        }

        It 'fresh Server 2025 VM: ImagePath points to the Driver Store, nothing copied to System32\drivers' {
            $r = Invoke-Scenario -Os @{ Caption = 'Microsoft Windows Server 2025 Standard'; Build = 26100; ProductType = 3 } -Params $FixParams
            $r.ExitCode | Should -Be 0
            Get-TestRegValue "$script:SvcKey\vioscsi" 'ImagePath' |
                Should -BeLike '\SystemRoot\System32\DriverStore\FileRepository\vioscsi.inf_amd64_*\vioscsi.sys'
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Drivers 'vioscsi.sys') | Should -BeFalse
        }

        It '-WhatIf changes nothing' {
            $r = Invoke-Scenario -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'WhatIf: nothing was changed'
            $r.PnpCalls.Count | Should -Be 0
            $global:VioReg.Count | Should -Be 1
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeFalse
        }

        It 'without -OutputPath: report in a timestamp folder in InfraToolkit-Output\Install-VirtIOBootDriver next to the script, also under -WhatIf' {
            foreach ($case in @(@{ Name = 'report-only'; Params = @{} }, @{ Name = 'fix-whatif'; Params = @{ Fix = $true; WhatIf = $true } })) {
                $folder = Join-Path $TestDrive ('default-out-{0}' -f $case.Name)
                $null = Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $folder -Force
                Copy-Item -LiteralPath $script:Target -Destination $folder
                $r = Invoke-Scenario -Script (Join-Path $folder 'Install-VirtIOBootDriver.ps1') -DefaultOutputPath -Params $case.Params
                $r.ExitCode | Should -Be 1
                $runs = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $folder 'InfraToolkit-Output') 'Install-VirtIOBootDriver') -Directory)
                $runs.Count | Should -Be 1
                $runs[0].Name | Should -Match '^\d{8}-\d{6}$'
                $report = Get-Content -LiteralPath (Join-Path $runs[0].FullName 'report.txt') -Raw
                $report | Should -Match 'Not in the Driver Store'
                ($report -replace '\s', '') | Should -Match ([regex]::Escape((Join-Path $runs[0].FullName 'report.txt')))
                Microsoft.PowerShell.Management\Test-Path -LiteralPath $r.Out | Should -BeFalse
            }
        }

        It 'prepared VM: nothing to change' {
            $r = Invoke-Scenario -Ready '2k22' -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match 'Nothing to change'
            $r.PnpCalls.Count | Should -Be 0
        }

        It 'keeps a newer driver file in System32\drivers' {
            $r = Invoke-Scenario -Params $FixParams -Setup {
                Set-Content -LiteralPath (Join-Path $env:SystemRoot 'System32/drivers/vioscsi.sys') -Value 'NEWER'
                $global:VioScenario.FileVersions['*/System32/drivers/vioscsi.sys'] = '200.0.0.0'
                $global:VioScenario.FileVersions['*/FileRepository/vioscsi.inf_*/vioscsi.sys'] = '100.100.104.27100'
            }
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match 'Kept .*vioscsi\.sys: version 200\.0\.0\.0'
            Get-Content -LiteralPath (Join-Path $r.Drivers 'vioscsi.sys') | Should -Be 'NEWER'
        }

        It 'replaces an older driver file in System32\drivers' {
            $r = Invoke-Scenario -Params $FixParams -Setup {
                Set-Content -LiteralPath (Join-Path $env:SystemRoot 'System32/drivers/vioscsi.sys') -Value 'OLDER'
                $global:VioScenario.FileVersions['*/System32/drivers/vioscsi.sys'] = '1.0.0.0'
                $global:VioScenario.FileVersions['*/FileRepository/vioscsi.inf_*/vioscsi.sys'] = '100.100.104.27100'
            }
            $r.ExitCode | Should -Be 0
            Get-Content -LiteralPath (Join-Path $r.Drivers 'vioscsi.sys') | Should -Be 'vioscsi 100.100.104.27100'
        }

        It 'sets StartOverride to 0 without staging again' {
            $r = Invoke-Scenario -Ready '2k22' -Params $FixParams -Setup { Set-TestRegKey "$script:SvcKey\vioscsi\StartOverride" @{ '0' = 3 } }
            $r.ExitCode | Should -Be 0
            Get-TestRegValue "$script:SvcKey\vioscsi\StartOverride" '0' | Should -Be 0
            $r.PnpCalls.Count | Should -Be 0
        }

        It 'completes a service written by the old manual method and keeps its working ImagePath' {
            $r = Invoke-Scenario -Ready '2k22' -Params $FixParams -Setup {
                Remove-TestRegKey "$script:SvcKey\vioscsi\Parameters"
                Set-TestRegKey "$script:SvcKey\vioscsi" @{ Group = 'SCSI Miniport'; ImagePath = 'System32\drivers\vioscsi.sys' }
            }
            $r.ExitCode | Should -Be 0
            Get-TestRegValue "$script:SvcKey\vioscsi\Parameters\PnpInterface" '5' | Should -Be 1
            Get-TestRegValue "$script:SvcKey\vioscsi" 'ImagePath' | Should -Be 'System32\drivers\vioscsi.sys'
            $r.PnpCalls.Count | Should -Be 0
        }

        It 'no media while staging is needed: exit 3 and nothing is changed' {
            $r = Invoke-Scenario -NoMedia -Params $FixParams
            $r.ExitCode | Should -Be 3
            $r.Report   | Should -Match 'Nothing was changed'
            $global:VioReg.Count | Should -Be 1
        }

        It 'media without a folder for this OS: exit 3 and nothing is changed' {
            $r = Invoke-Scenario -MediaFolders @('w10') -Params $FixParams
            $r.ExitCode | Should -Be 3
            $r.Report   | Should -Match 'The media has no'
            $r.PnpCalls.Count | Should -Be 0
        }

        It 'pnputil fails: action required (exit 1) with the exit code in the report' {
            $r = Invoke-Scenario -Params $FixParams -Scenario @{ PnpExitCode = 5 }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'pnputil exit code 5'
            $r.Report   | Should -Match 'FAILED: vioscsi\.inf is not in the Driver Store'
        }
    }

    Context 'virtio-win media' {

        It 'finds the ISO on the CD drive and shows its label' {
            $r = Invoke-Scenario -NoMediaParameter -Params $FixParams -Setup {
                param($ctx)
                $global:VioScenario.Disks = @([pscustomobject]@{ DeviceID = $ctx.Media; VolumeName = 'virtio-win-0.1.999' })
            }
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match 'virtio-win-0\.1\.999'
        }

        It 'two media drives: -Fix asks for -VirtIOPath (exit 3)' {
            $r = Invoke-Scenario -NoMediaParameter -Params $FixParams -Setup {
                param($ctx)
                $second = Join-Path $ctx.Root 'media2'
                New-TestMedia $second @('2k22')
                $global:VioScenario.Disks = @(
                    [pscustomobject]@{ DeviceID = $ctx.Media; VolumeName = 'virtio-win-0.1.998' }
                    [pscustomobject]@{ DeviceID = $second;    VolumeName = 'virtio-win-0.1.999' }
                )
            }
            $r.ExitCode | Should -Be 3
            $r.Report   | Should -Match 'More than one virtio-win media'
            $r.PnpCalls.Count | Should -Be 0
        }

        It '-VirtIOPath that is not virtio-win media' {
            $r = Invoke-Scenario -NoMedia -Params @{ VirtIOPath = $TestDrive }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'is not virtio-win media'
        }
    }

    Context 'Network configuration' {

        It 'saves every adapter and lists the static ones' {
            $nics = @(
                [pscustomobject]@{ InterfaceIndex = 4; Description = 'vmxnet3 Ethernet Adapter'; MACAddress = '00-00-5E-00-53-01'; DHCPEnabled = $false
                    IPAddress = @('192.0.2.10'); IPSubnet = @('255.255.255.0'); DefaultIPGateway = @('192.0.2.1')
                    DNSServerSearchOrder = @('192.0.2.53', '192.0.2.54'); DNSDomain = 'contoso.com' }
                [pscustomobject]@{ InterfaceIndex = 7; Description = 'vmxnet3 Ethernet Adapter #2'; MACAddress = '00-00-5E-00-53-02'; DHCPEnabled = $true
                    IPAddress = @('198.51.100.20'); IPSubnet = @('255.255.255.0') }
            )
            $adapters = @(
                [pscustomobject]@{ InterfaceIndex = 4; NetConnectionID = 'Ethernet0' }
                [pscustomobject]@{ InterfaceIndex = 7; NetConnectionID = 'Ethernet1' }
            )
            $r = Invoke-Scenario -Ready '2k22' -Scenario @{ NicConfigs = $nics; Adapters = $adapters }
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match '2 with IP, 1 with a static IP'
            $r.Report   | Should -Match 'Ethernet0: 192\.0\.2\.10 / 255\.255\.255\.0, gateway 192\.0\.2\.1, DNS 192\.0\.2\.53;192\.0\.2\.54'
            $r.Report   | Should -Match 'set the saved static IP configuration'
            $csv = @(Import-Csv -LiteralPath (Join-Path $r.Out 'network-config.csv'))
            $csv.Count | Should -Be 2
            ($csv | Where-Object Name -eq 'Ethernet0').IPAddress | Should -Be '192.0.2.10'
            ($csv | Where-Object Name -eq 'Ethernet1').DHCPEnabled | Should -Be 'True'
        }
    }
}
