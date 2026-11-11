# Loom engine. Reads the catalog and applies registry, service, package,
# feature, update, and Windows image actions.
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [string]$Payload = "",
    [string]$Resources = ""
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:LogFile = $null
$script:HadError = $false

function Write-Loom {
    param(
        [string]$Message,
        [int]$Percent = -1,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    if ($Level -eq "ERROR") { $script:HadError = $true }
    $safe = ($Message -replace "`r|`n", " ").Trim()
    if (-not $safe) { return }
    Write-Output ("LOG`t{0}`t{1}`t{2}" -f $Level, $Percent, $safe)
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value ("[{0}] {1} {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $safe) -ErrorAction SilentlyContinue
    }
}

function Exit-Loom {
    param($Object, [int]$Code = 0)
    $json = $Object | ConvertTo-Json -Compress -Depth 8
    Write-Output ("RESULT`t{0}" -f $json)
    exit $Code
}

function Get-LoomPayload {
    if ([string]::IsNullOrWhiteSpace($Payload)) { return [pscustomobject]@{} }
    $text = $Payload
    if (Test-Path -LiteralPath $Payload) {
        $text = Get-Content -LiteralPath $Payload -Raw -ErrorAction Stop
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    return $text | ConvertFrom-Json
}

function As-List($Value) {
    if ($null -eq $Value) { return @() }
    return @($Value)
}

$logDir = Join-Path $env:LOCALAPPDATA "Loom\logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$script:LogFile = Join-Path $logDir ("session-{0}.log" -f (Get-Date -Format "yyyyMMdd"))

if ([string]::IsNullOrWhiteSpace($Resources)) {
    $Resources = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
}
$configDir = Join-Path $Resources "config"
$engineDir = Join-Path $Resources "engine"

function Read-LoomJson([string]$Name) {
    $path = Join-Path $configDir $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing configuration file: $Name" }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

$tweaks = $null
$features = $null
$dnsTable = $null

function Get-Tweaks { if (-not $script:tweaks) { $script:tweaks = Read-LoomJson "tweaks.json" }; return $script:tweaks }
function Get-Features { if (-not $script:features) { $script:features = Read-LoomJson "feature.json" }; return $script:features }
function Get-DnsTable { if (-not $script:dnsTable) { $script:dnsTable = Read-LoomJson "dns.json" }; return $script:dnsTable }

function Test-LoomAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-HKU {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
    }
}

function Set-LoomRegistry {
    param($Name, $Path, $Type, $Value)
    try {
        Ensure-HKU
        if ($null -eq $Name -or [string]::IsNullOrWhiteSpace([string]$Path)) { return }

        if ([string]$Value -eq "<RemoveEntry>") {
            $exists = $true
            try { Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop | Out-Null }
            catch [System.Management.Automation.PSArgumentException] { $exists = $false }
            catch [System.Management.Automation.ItemNotFoundException] { $exists = $false }
            if (-not $exists) {
                Write-Loom "Registry value $Path\$Name is already absent"
                return
            }
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
            Write-Loom "Created registry path $Path"
        }

        if ([string]$Value -eq "<RemoveEntry>") {
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop
            Write-Loom "Removed $Path\$Name"
            return
        }

        $typed = $Value
        switch ([string]$Type) {
            "DWord" { $typed = [int]$Value }
            "QWord" { $typed = [int64]$Value }
            "Binary" { $typed = [byte[]]@($Value) }
            default { $typed = [string]$Value }
        }
        New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $typed -Force -ErrorAction Stop | Out-Null
        Write-Loom "Set $Path\$Name ($Type) to $Value"
    } catch {
        Write-Loom "Registry change failed for $Path\$Name : $($_.Exception.Message)" -Level "ERROR"
    }
}

function Set-LoomService {
    param([string]$Name, [string]$StartupType)
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ([string]$service.StartType -eq $StartupType) {
            Write-Loom "Service $Name is already $StartupType"
            return
        }
        if ($StartupType -eq "AutomaticDelayedStart") {
            & sc.exe config $Name start= delayed-auto | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed with exit code $LASTEXITCODE" }
        } else {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        }
        Write-Loom "Service $Name startup set to $StartupType"
    } catch {
        if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
            Write-Loom "Service $Name was not found" -Level "WARN"
        } else {
            Write-Loom "Unable to set service $Name to $StartupType : $($_.Exception.Message)" -Level "ERROR"
        }
    }
}

$script:ExplorerReady = $false
function Invoke-WinUtilExplorerUpdate {
    param([string]$action = "refresh")
    if ($action -eq "restart") {
        & taskkill.exe /F /IM explorer.exe | Out-Null
        Start-Process explorer.exe
        return
    }
    if (-not $script:ExplorerReady) {
        if (-not ("Loom.Win32" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Loom {
  public static class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
  }
}
"@
        }
        $script:ExplorerReady = $true
    }
    $result = [IntPtr]::Zero
    [Loom.Win32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, "ImmersiveColorSet", 2, 100, [ref]$result) | Out-Null
}
function Invoke-WinutilThemeChange { param($theme) }

function Invoke-LoomScript {
    param([string]$Source, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Source)) { return }
    try {
        $block = [scriptblock]::Create($Source)
        & $block
        Write-Loom "Ran script for $Name"
    } catch {
        Write-Loom "Script for $Name failed: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Remove-LoomAppx {
    param([string[]]$Names)
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        Write-Loom "Removing AppX $name"
        $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$name*" })
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            } catch {
                Write-Loom "Could not remove $($pkg.PackageFullName): $($_.Exception.Message)" -Level "WARN"
            }
        }
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$name*" })
        foreach ($prov in $provisioned) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            } catch {
                Write-Loom "Could not deprovision $($prov.PackageName): $($_.Exception.Message)" -Level "WARN"
            }
        }
    }
}

function Invoke-LoomTweak {
    param([string]$Key, [bool]$Undo = $false)
    $table = Get-Tweaks
    $entry = $table.$Key
    if (-not $entry) { throw "Unknown tweak $Key" }
    $label = if ($entry.Content) { [string]$entry.Content } else { $Key }
    Write-Loom ("{0} {1}" -f $(if ($Undo) { "Undoing" } else { "Applying" }), $label)

    $regField = if ($Undo) { "OriginalValue" } else { "Value" }
    $svcField = if ($Undo) { "OriginalType" } else { "StartupType" }
    $expectedSvc = if ($Undo) { "StartupType" } else { "OriginalType" }
    $scriptField = if ($Undo) { "UndoScript" } else { "InvokeScript" }

    foreach ($item in (As-List $entry.service)) {
        $change = $true
        try {
            $service = Get-Service -Name $item.Name -ErrorAction Stop
            $expected = [string]$item.$expectedSvc
            if ($expected -and [string]$service.StartType -ne $expected) {
                $change = $false
                Write-Loom "Leaving service $($item.Name) at $($service.StartType); this tweak expected $expected" -Level "WARN"
            }
        } catch {
            if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
                $change = $false
                Write-Loom "Service $($item.Name) was not found" -Level "WARN"
            } else { throw }
        }
        if ($change) { Set-LoomService -Name $item.Name -StartupType $item.$svcField }
    }

    foreach ($reg in (As-List $entry.registry)) {
        if ($reg.Values) { continue }
        Set-LoomRegistry -Name $reg.Name -Path $reg.Path -Type $reg.Type -Value $reg.$regField
    }

    foreach ($scr in (As-List $entry.$scriptField)) {
        Invoke-LoomScript -Source ([string]$scr) -Name $Key
    }

    if (-not $Undo) {
        $packages = @(As-List $entry.appx | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($packages.Count -gt 0) { Remove-LoomAppx -Names $packages }
    }
}

function Set-LoomCombo {
    param([string]$Key, [string]$State)
    $entry = (Get-Tweaks).$Key
    if (-not $entry) { throw "Unknown preference $Key" }
    Write-Loom "Setting $($entry.Content) to $State"
    foreach ($reg in (As-List $entry.registry)) {
        if (-not $reg.Values) { continue }
        $mapped = $reg.Values.$State
        if ($null -eq $mapped) { throw "Preference $Key has no value for $State" }
        Set-LoomRegistry -Name $reg.Name -Path $reg.Path -Type $reg.Type -Value $mapped
    }
}

function Get-LoomComboState {
    param($Registry)
    $settings = @(As-List $Registry)
    if ($settings.Count -eq 0 -or -not $settings[0].Values) { return $null }
    foreach ($state in $settings[0].Values.PSObject.Properties) {
        $matches = $true
        foreach ($setting in $settings) {
            $current = $null
            $exists = $false
            try {
                if (Test-Path $setting.Path) {
                    $item = Get-ItemProperty -Path $setting.Path -ErrorAction Stop
                    if ($item.PSObject.Properties.Name -contains $setting.Name) {
                        $current = $item.$($setting.Name)
                        $exists = $true
                    }
                }
            } catch { $exists = $false }
            $actual = if ($exists -and $null -ne $current) { $current } else { $setting.DefaultValue }
            $configured = $setting.Values.$($state.Name)
            $expected = if ([string]$configured -eq "<RemoveEntry>") { $setting.DefaultValue } else { $configured }
            if ([string]$actual -ne [string]$expected) { $matches = $false; break }
        }
        if ($matches) { return [string]$state.Name }
    }
    return $null
}

function Get-LoomToggleState {
    param($Entry)
    foreach ($reg in (As-List $Entry.registry)) {
        $state = $null
        if (Test-Path $reg.Path -ErrorAction SilentlyContinue) {
            $state = (Get-ItemProperty -Path $reg.Path -ErrorAction SilentlyContinue).$($reg.Name)
        }
        if ($null -eq $state) {
            if ([string]$reg.DefaultState -eq "true") { $state = $reg.Value }
            elseif ([string]$reg.DefaultState -eq "false") { $state = $reg.OriginalValue }
        }
        if ([string]$state -ne [string]$reg.Value) { return $false }
    }
    return $true
}

function Test-BadId([string]$Value) {
    return [string]::IsNullOrWhiteSpace($Value) -or $Value -eq "na"
}

function Resolve-LoomPackage($App, [string]$Preference) {
    $winget = [string]$App.winget
    $choco = [string]$App.choco
    if ($Preference -eq "choco") {
        if (-not (Test-BadId $choco)) { return @{ Manager = "choco"; Id = $choco } }
        if (-not (Test-BadId $winget)) { return @{ Manager = "winget"; Id = $winget } }
    } else {
        if (-not (Test-BadId $winget)) { return @{ Manager = "winget"; Id = $winget } }
        if (-not (Test-BadId $choco)) { return @{ Manager = "choco"; Id = $choco } }
    }
    return $null
}

function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return }
    Write-Loom "WinGet is missing. Repairing it." -Percent 2
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Force -ErrorAction Stop
    Repair-WinGetPackageManager -AllUsers
}

function Ensure-Choco {
    if (Get-Command choco -ErrorAction SilentlyContinue) { return }
    Write-Loom "Installing Chocolatey" -Percent 2
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Invoke-WingetPackage {
    param([string]$PackageAction, [string]$Id)
    $reboot = @{
        3010 = "installed, a restart is needed"
        1641 = "installed, the installer started a restart"
        -1978334967 = "installed, a restart is needed"
        -1978334965 = "installed, the installer started a restart"
    }
    $nothing = @{
        -1978335135 = "already installed"
        -1978335189 = "no applicable update"
    }
    $source = "winget"
    $packageId = $Id
    if ($Id.StartsWith("msstore:")) {
        $source = "msstore"
        $packageId = $Id.Substring(8)
    }
    $args = switch ($PackageAction) {
        "Uninstall" { @("uninstall", "--id", $packageId, "--source", $source, "--silent") }
        "Upgrade" {
            if ($packageId -eq "all") { @("upgrade", "--all", "--include-unknown", "--silent", "--accept-package-agreements", "--accept-source-agreements") }
            else { @("upgrade", "--id", $packageId, "--source", $source, "--include-unknown", "--silent", "--accept-package-agreements", "--accept-source-agreements") }
        }
        default { @("install", "--id", $packageId, "--source", $source, "--silent", "--accept-package-agreements", "--accept-source-agreements") }
    }
    Write-Loom "$PackageAction $packageId"
    & winget @args
    $code = $LASTEXITCODE
    $outcome = "Failed"
    $detail = "WinGet exit $code"
    if ($code -eq 0) { $outcome = "Succeeded"; $detail = "completed" }
    elseif ($reboot.ContainsKey($code)) { $outcome = "Succeeded"; $detail = $reboot[$code] }
    elseif ($nothing.ContainsKey($code)) { $outcome = "Skipped"; $detail = $nothing[$code] }
    elseif ($code -eq -1978335107) { $outcome = "Skipped"; $detail = "installed for the current user; an elevated install cannot change it" }
    if ($outcome -eq "Failed") { Write-Loom "$packageId failed: $detail" -Level "ERROR" }
    else { Write-Loom "$packageId $outcome. $detail" }
    return [pscustomobject]@{ Package = $packageId; Manager = "winget"; Outcome = $outcome; Detail = $detail; ExitCode = $code }
}

function Invoke-ChocoPackage {
    param([string]$PackageAction, [string[]]$Ids)
    $verb = switch ($PackageAction) { "Uninstall" { "uninstall" } "Upgrade" { "upgrade" } default { "install" } }
    $results = @()
    foreach ($id in $Ids) {
        Write-Loom "$PackageAction $id with Chocolatey"
        & choco $verb $id -y --no-progress
        $code = $LASTEXITCODE
        $outcome = if ($code -eq 0) { "Succeeded" } else { "Failed" }
        if ($outcome -eq "Failed") { Write-Loom "$id failed with exit $code" -Level "ERROR" }
        $results += [pscustomobject]@{ Package = $id; Manager = "choco"; Outcome = $outcome; Detail = "exit $code"; ExitCode = $code }
    }
    return $results
}

function Set-LoomDns {
    param([string]$Provider)
    if ([string]::IsNullOrWhiteSpace($Provider) -or $Provider -eq "Default") { return $true }
    $chosen = $Provider
    if ($chosen -eq "Fastest") {
        Write-Loom "Measuring DNS latency"
        $best = $null
        foreach ($item in (Get-DnsTable).PSObject.Properties) {
            if (-not $item.Value.BenchmarkEligible) { continue }
            $ip = [string]$item.Value.Primary
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $reply = $ping.Send($ip, 800)
                if ($reply.Status -eq "Success" -and ($null -eq $best -or $reply.RoundtripTime -lt $best.Ms)) {
                    $best = [pscustomobject]@{ Name = $item.Name; Ms = $reply.RoundtripTime }
                }
            } catch {}
        }
        if (-not $best) {
            Write-Loom "Could not measure a DNS provider. Current DNS was left unchanged." -Level "ERROR"
            return $false
        }
        $chosen = $best.Name
        Write-Loom "Fastest DNS is $chosen ($($best.Ms) ms)"
    }

    $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" })
    if ($adapters.Count -eq 0) {
        Write-Loom "No connected network adapters" -Level "WARN"
        return $false
    }
    foreach ($adapter in $adapters) {
        if ($chosen -eq "DHCP") {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses
            Write-Loom "Reset DNS to DHCP on $($adapter.Name)"
            continue
        }
        $dns = (Get-DnsTable).$chosen
        if (-not $dns) { throw "Unknown DNS provider $chosen" }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($dns.Primary, $dns.Secondary)
        if ($dns.Primary6 -and $dns.Secondary6) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($dns.Primary6, $dns.Secondary6) -ErrorAction SilentlyContinue
        }
        Write-Loom "Set $($adapter.Name) DNS to $chosen"
    }
    return $true
}

function Enable-LoomTasks([string[]]$Paths) {
    foreach ($taskPath in $Paths) {
        Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    }
}
function Disable-LoomTasks([string[]]$Paths) {
    foreach ($taskPath in $Paths) {
        Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    }
}

$script:UpdateTasks = @(
    "\Microsoft\Windows\InstallService\",
    "\Microsoft\Windows\UpdateOrchestrator\",
    "\Microsoft\Windows\UpdateAssistant\",
    "\Microsoft\Windows\WaaSMedic\",
    "\Microsoft\Windows\WindowsUpdate\",
    "\Microsoft\WindowsUpdate\"
)

function Invoke-LoomUpdates {
    param([string]$Profile)
    switch ($Profile) {
        "recommended" {
            Write-Loom "Applying the recommended Windows Update profile" -Percent 5
            $policy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            $au = Join-Path $policy "AU"
            Remove-ItemProperty -Path $au -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
            foreach ($name in @("BITS", "wuauserv")) { Set-Service -Name $name -StartupType Manual -ErrorAction SilentlyContinue }
            Set-Service -Name UsoSvc -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service UsoSvc -ErrorAction SilentlyContinue
            Enable-LoomTasks $script:UpdateTasks
            foreach ($pair in @(
                @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"; Name = "PreventDeviceMetadataFromNetwork"; Value = 1 },
                @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"; Name = "DontPromptForWindowsUpdate"; Value = 1 },
                @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"; Name = "DontSearchWindowsUpdate"; Value = 1 },
                @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"; Name = "DriverUpdateWizardWuSearchEnabled"; Value = 0 }
            )) {
                if (-not (Test-Path $pair.Path)) { New-Item -Path $pair.Path -Force | Out-Null }
                Set-ItemProperty -Path $pair.Path -Name $pair.Name -Type DWord -Value $pair.Value
            }
            if (-not (Test-Path $policy)) { New-Item -Path $policy -Force | Out-Null }
            Set-ItemProperty -Path $policy -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1
            Set-ItemProperty -Path $policy -Name "DeferFeatureUpdates" -Type DWord -Value 1
            Set-ItemProperty -Path $policy -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
            Set-ItemProperty -Path $policy -Name "DeferQualityUpdates" -Type DWord -Value 1
            Set-ItemProperty -Path $policy -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4
            if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }
            Remove-ItemProperty -Path $au -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $au -Name "AUOptions" -Type DWord -Value 3
            Set-ItemProperty -Path $au -Name "AUPowerManagement" -Type DWord -Value 0
            Write-Loom "Recommended update profile applied. Restart Windows to finish." -Percent 100
        }
        "default" {
            Write-Loom "Restoring Windows Update defaults" -Percent 10
            $paths = @{
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" = @("NoAutoUpdate", "AUOptions", "NoAutoRebootWithLoggedOnUsers", "AUPowerManagement")
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" = @("ExcludeWUDriversInQualityUpdate", "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays")
                "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" = @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" = @("PreventDeviceMetadataFromNetwork")
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" = @("DontPromptForWindowsUpdate", "DontSearchWindowsUpdate", "DriverUpdateWizardWuSearchEnabled")
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" = @("DODownloadMode")
            }
            foreach ($path in $paths.Keys) {
                foreach ($name in $paths[$path]) { Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue }
            }
            Set-Service -Name BITS -StartupType Manual -ErrorAction SilentlyContinue
            Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
            Set-Service -Name UsoSvc -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service UsoSvc -ErrorAction SilentlyContinue
            Enable-LoomTasks $script:UpdateTasks
            Write-Loom "Windows Update defaults restored. Restart Windows to finish." -Percent 100
        }
        "disable" {
            Write-Loom "Disabling automatic Windows Update" -Percent 10
            $au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }
            Set-ItemProperty -Path $au -Name "NoAutoUpdate" -Type DWord -Value 1
            Set-ItemProperty -Path $au -Name "AUOptions" -Type DWord -Value 1
            $do = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
            if (-not (Test-Path $do)) { New-Item -Path $do -Force | Out-Null }
            Set-ItemProperty -Path $do -Name "DODownloadMode" -Type DWord -Value 0
            foreach ($name in @("BITS", "wuauserv", "UsoSvc")) {
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Loom "Stopped $name"
            }
            Remove-Item -Path "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
            Disable-LoomTasks $script:UpdateTasks
            Write-Loom "Automatic updates are disabled. Security updates will not install until you restore defaults. Restart Windows." -Percent 100
        }
        default { throw "Unknown update profile $Profile" }
    }
}

function Invoke-LoomRepair {
    $steps = @(
        @{ Label = "Checking the disk"; Arguments = "/c chkdsk C: /scan /perf"; Ok = @(0, 1, 2) },
        @{ Label = "Scanning protected system files"; Arguments = "/c sfc /scannow"; Ok = @(0) },
        @{ Label = "Repairing the Windows image"; Arguments = "/c dism /online /cleanup-image /restorehealth"; Ok = @(0, 3010) }
    )
    $index = 0
    foreach ($step in $steps) {
        $index++
        $percent = [int]((($index - 1) / $steps.Count) * 100)
        Write-Loom $step.Label -Percent $percent
        $process = Start-Process cmd.exe -ArgumentList $step.Arguments -NoNewWindow -Wait -PassThru
        if ($step.Ok -notcontains $process.ExitCode) {
            throw "$($step.Label) failed with exit code $($process.ExitCode)."
        }
        Write-Loom "$($step.Label) finished (exit $($process.ExitCode))"
    }
}

function Repair-LoomUpdate {
    Write-Loom "Resetting Windows Update components" -Percent 5
    foreach ($name in @("BITS", "wuauserv", "appidsvc", "cryptsvc")) {
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        Write-Loom "Stopped $name"
    }
    Remove-Item "$env:ALLUSERSPROFILE\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue
    if (Test-Path "$env:SystemRoot\SoftwareDistribution\Download") {
        Rename-Item "$env:SystemRoot\SoftwareDistribution\Download" "Download.bak" -ErrorAction SilentlyContinue
    }
    Remove-Item "$env:SystemRoot\WindowsUpdate.log" -ErrorAction SilentlyContinue
    $dlls = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll", "jscript.dll", "vbscript.dll",
        "scrrun.dll", "msxml.dll", "msxml3.dll", "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll",
        "dssenh.dll", "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll", "oleaut32.dll",
        "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll", "wuaueng.dll", "wuaueng1.dll", "wucltui.dll",
        "wups.dll", "wups2.dll", "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    Push-Location "$env:SystemRoot\System32"
    foreach ($dll in $dlls) { Start-Process regsvr32.exe -ArgumentList "/s", $dll -Wait -WindowStyle Hidden }
    Pop-Location
    foreach ($name in @("AccountDomainSid", "PingID", "SusClientId")) {
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate" -Name $name -ErrorAction SilentlyContinue
    }
    foreach ($name in @("ExcludeWUDriversInQualityUpdate", "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays")) {
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name $name -ErrorAction SilentlyContinue
    }
    & netsh winsock reset | Out-Null
    & netsh winhttp reset proxy | Out-Null
    Get-BitsTransfer -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    Set-Service BITS -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service wuauserv -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service CryptSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service BITS -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Start-Service CryptSvc -ErrorAction SilentlyContinue
    try { (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow() } catch {
        Write-Loom "Windows Update discovery could not be started: $($_.Exception.Message)" -Level "WARN"
    }
    Write-Loom "Windows Update components were reset. Restart Windows." -Percent 100
}

function Install-LoomAppx {
    param($App)
    $name = [string]$App.PackageId
    $store = [string]$App.StoreId
    Write-Loom "Installing $($App.Content)"
    $manifest = $null
    $installed = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    foreach ($pkg in $installed) {
        $candidate = Join-Path $pkg.InstallLocation "AppxManifest.xml"
        if (Test-Path -LiteralPath $candidate) { $manifest = $candidate; break }
    }
    if ($manifest) {
        try {
            Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction Stop
            return [pscustomobject]@{ Package = $name; Outcome = "Succeeded"; Detail = "registered local package" }
        } catch {
            Write-Loom "Local registration failed for $name : $($_.Exception.Message)" -Level "WARN"
        }
    }
    if (Test-BadId $store) {
        Write-Loom "No local package or Store id for $name" -Level "ERROR"
        return [pscustomobject]@{ Package = $name; Outcome = "Failed"; Detail = "nothing to install" }
    }
    Ensure-Winget
    return Invoke-WingetPackage -PackageAction "Install" -Id "msstore:$store"
}

function Get-Pwsh7 {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe")) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Invoke-LoomActionButton {
    param([string]$Key)
    switch ($Key) {
        "WPFFixesNTPPool" {
            Start-Service w32time
            & w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL
            Restart-Service w32time
            & w32tm /resync
            Write-Loom "Time sync now uses pool.ntp.org"
        }
        "WPFPanelAutologin" {
            $dest = Join-Path $env:LOCALAPPDATA "Loom\tools\Autologon.exe"
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Invoke-WebRequest -Uri "https://live.sysinternals.com/Autologon.exe" -OutFile $dest -UseBasicParsing
            Start-Process -FilePath $dest -ArgumentList "/accepteula"
            Write-Loom "Opened Sysinternals Autologon"
        }
        "WPFFixesUpdate" { Repair-LoomUpdate }
        "WPFFixesNetwork" {
            & netsh winsock reset
            & netsh int ip reset
            Write-Loom "Network stack reset. Restart Windows."
        }
        "WPFPanelDISM" { Invoke-LoomRepair }
        "WPFFixesWinget" {
            Install-PackageProvider -Name NuGet -Force | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Force
            Repair-WinGetPackageManager -AllUsers
            Write-Loom "WinGet repair finished"
        }
        "WPFWinUtilSSHServer" {
            $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction SilentlyContinue
            if (-not $cap -or $cap.State -ne "Installed") {
                Write-Loom "Installing OpenSSH Server"
                Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"
            }
            Set-Service sshd -StartupType Automatic
            Start-Service sshd
            Set-Service ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service ssh-agent -ErrorAction SilentlyContinue
            if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
            }
            Write-Loom "OpenSSH Server is enabled"
        }
        "WPFWinUtilInstallPSProfile" {
            $pwsh = Get-Pwsh7
            if (-not $pwsh) {
                Ensure-Winget
                Invoke-WingetPackage -PackageAction "Install" -Id "Microsoft.PowerShell" | Out-Null
                $pwsh = Get-Pwsh7
            }
            if (-not $pwsh) { throw "PowerShell 7 is not available, so the profile was not installed." }
            Write-Loom "Installing the PowerShell profile"
            & $pwsh -NoProfile -Command "`$ErrorActionPreference='Stop'; irm 'https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1' | iex"
            if ($LASTEXITCODE -ne 0) { throw "Profile setup exited with code $LASTEXITCODE." }
            Write-Loom "PowerShell profile installed. Open a new PowerShell 7 window."
        }
        "WPFWinUtilUninstallPSProfile" {
            $pwsh = Get-Pwsh7
            if (-not $pwsh) { throw "PowerShell 7 is not installed." }
            $profilePath = (& $pwsh -NoProfile -Command '$PROFILE' | Select-Object -First 1).Trim()
            $backup = "$profilePath.bak"
            if (Test-Path -LiteralPath $backup) {
                Move-Item -LiteralPath $backup -Destination $profilePath -Force
                Write-Loom "Restored the previous PowerShell profile"
            } elseif (Test-Path -LiteralPath $profilePath) {
                Remove-Item -LiteralPath $profilePath -Force
                Write-Loom "Removed the PowerShell profile"
            } else {
                Write-Loom "No PowerShell 7 profile was found" -Level "WARN"
            }
        }
        "WPFOOSUbutton" {
            $dest = Join-Path $env:LOCALAPPDATA "Loom\tools\OOSU10.exe"
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Write-Loom "Downloading O&O ShutUp10++"
            Invoke-WebRequest -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -OutFile $dest -UseBasicParsing
            Start-Process -FilePath $dest
            Write-Loom "Launched O&O ShutUp10++"
        }
        "WPFAddUltPerf" {
            $duplicated = & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
            if ($LASTEXITCODE -ne 0) { throw "Could not create the Ultimate Performance plan." }
            $guid = ([regex]::Match(($duplicated | Out-String), "[A-Fa-f0-9-]{36}")).Value
            if (-not $guid) { throw "powercfg did not return a plan id." }
            & powercfg /setactive $guid
            Write-Loom "Ultimate Performance is the active power plan"
        }
        "WPFRemoveUltPerf" {
            & powercfg /restoredefaultschemes
            if ($LASTEXITCODE -ne 0) { throw "Could not restore the default power plans." }
            Write-Loom "Power plans were restored to Windows defaults"
        }
        default {
            $entry = (Get-Features).$Key
            if ($entry -and $entry.InvokeScript) {
                foreach ($scr in (As-List $entry.InvokeScript)) {
                    $text = [string]$scr
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    if ($text -match '^(?i)[a-z]:\\' -or $text -match '\.(msc|cpl|exe)$' -or $text -match '^(?i)(control|compmgmt|ncpa|main|powercfg|appwiz|intl|wscui|mmsys|sysdm|timedate|firewall|rstrui)(\.cpl|\.msc|\.exe)?$') {
                        Start-Process $text
                        Write-Loom "Opened $text"
                    } else {
                        Invoke-LoomScript -Source $text -Name $Key
                    }
                }
                return
            }
            throw "Unknown action $Key"
        }
    }
}

function Find-Oscdimg {
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($root in @(
        "${env:ProgramFiles(x86)}\Windows Kits",
        "$env:ProgramFiles\Windows Kits",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        "$env:ProgramFiles\WinGet\Packages"
    )) {
        if ($root -and (Test-Path $root)) {
            $found = Get-ChildItem $root -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return $null
}

function Get-IsoVolume([string]$ImagePath) {
    $image = Get-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue
    if (-not $image -or -not $image.Attached) {
        Mount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null
    }
    for ($i = 0; $i -lt 15; $i++) {
        $disk = Get-DiskImage -ImagePath $ImagePath | Get-Disk -ErrorAction SilentlyContinue
        if ($disk) {
            $part = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Select-Object -First 1
            if ($part) { return $part.DriveLetter }
        }
        Start-Sleep -Seconds 1
    }
    throw "The ISO mounted, but Windows did not assign a drive letter."
}

function Invoke-Robocopy([string]$Source, [string]$Destination, [string[]]$Extra) {
    & robocopy $Source $Destination @Extra
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE." }
}

try {
    $body = Get-LoomPayload
    switch ($Action) {
        "ping" {
            $os = Get-CimInstance Win32_OperatingSystem
            Exit-Loom @{
                ok = $true
                admin = [bool](Test-LoomAdmin)
                windows = "$($os.Caption) $($os.Version)"
                winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
                choco = [bool](Get-Command choco -ErrorAction SilentlyContinue)
            }
        }
        "states" {
            Ensure-HKU
            $table = Get-Tweaks
            $toggles = @{}
            $combos = @{}
            foreach ($prop in $table.PSObject.Properties) {
                if ($prop.Value.Type -eq "Toggle") { $toggles[$prop.Name] = [bool](Get-LoomToggleState $prop.Value) }
                if ($prop.Value.Type -eq "Combobox" -and $prop.Value.registry) {
                    $combos[$prop.Name] = Get-LoomComboState $prop.Value.registry
                }
            }
            Exit-Loom @{ ok = $true; toggles = $toggles; combos = $combos }
        }
        "apply-tweaks" {
            if (-not (Test-LoomAdmin)) { throw "Loom needs to run as administrator to change Windows." }
            $keys = @(As-List $body.keys)
            $undo = [bool]$body.undo
            if ($keys.Count -eq 0 -and ([string]$body.dns -eq "" -or [string]$body.dns -eq "Default")) {
                throw "Select at least one tweak."
            }
            $ordered = @($keys | Where-Object { $_ -ne "WPFTweaksRestorePoint" })
            if (-not $undo -and ($keys -contains "WPFTweaksRestorePoint")) {
                Write-Loom "Creating a restore point before the other tweaks" -Percent 0
                Invoke-LoomTweak -Key "WPFTweaksRestorePoint"
            }
            if (-not $undo -and $body.dns -and [string]$body.dns -ne "Default") {
                if (-not (Set-LoomDns -Provider ([string]$body.dns))) { throw "DNS was not changed, so the remaining tweaks were skipped." }
            }
            $done = 0
            foreach ($key in $ordered) {
                $done++
                $percent = [int](($done / [Math]::Max($ordered.Count, 1)) * 100)
                Invoke-LoomTweak -Key $key -Undo:$undo
                Write-Loom "Finished $key" -Percent $percent
            }
            Exit-Loom @{ ok = (-not $script:HadError); count = $keys.Count }
        }
        "combo" {
            if (-not (Test-LoomAdmin)) { throw "Loom needs to run as administrator to change this preference." }
            Set-LoomCombo -Key ([string]$body.key) -State ([string]$body.state)
            Exit-Loom @{ ok = (-not $script:HadError) }
        }
        "packages" {
            if (-not (Test-LoomAdmin)) { throw "Loom needs to run as administrator to install software." }
            $mode = [string]$body.mode
            $preference = if ([string]$body.manager -eq "choco") { "choco" } else { "winget" }
            if ($mode -eq "upgrade-all") {
                if ($preference -eq "choco") {
                    Ensure-Choco
                    $results = @(Invoke-ChocoPackage -PackageAction "Upgrade" -Ids @("all"))
                } else {
                    Ensure-Winget
                    $results = @(Invoke-WingetPackage -PackageAction "Upgrade" -Id "all")
                }
                Exit-Loom @{ ok = (-not $script:HadError); results = $results }
            }
            $apps = Read-LoomJson "applications.json"
            $ids = @(As-List $body.ids)
            if ($ids.Count -eq 0) { throw "Select at least one application." }
            $verb = if ($mode -eq "uninstall") { "Uninstall" } else { "Install" }
            $results = @()
            $index = 0
            $needsWinget = $false
            $needsChoco = $false
            $plan = @()
            foreach ($id in $ids) {
                $app = $apps.$id
                if (-not $app) { Write-Loom "Unknown application $id" -Level "WARN"; continue }
                $resolved = Resolve-LoomPackage $app $preference
                if (-not $resolved) { Write-Loom "$($app.content) has no package id" -Level "WARN"; continue }
                $plan += [pscustomobject]@{ Name = $app.content; Manager = $resolved.Manager; Id = $resolved.Id }
                if ($resolved.Manager -eq "winget") { $needsWinget = $true } else { $needsChoco = $true }
            }
            if ($needsWinget) { Ensure-Winget }
            if ($needsChoco) { Ensure-Choco }
            foreach ($item in $plan) {
                $index++
                $percent = [int]((($index - 1) / [Math]::Max($plan.Count, 1)) * 100)
                Write-Loom "$verb $($item.Name) ($index/$($plan.Count))" -Percent $percent
                if ($item.Manager -eq "choco") { $results += @(Invoke-ChocoPackage -PackageAction $verb -Ids @($item.Id)) }
                else { $results += @(Invoke-WingetPackage -PackageAction $verb -Id $item.Id) }
            }
            Exit-Loom @{ ok = (-not $script:HadError); results = $results }
        }
        "installed" {
            $preference = if ([string]$body.manager -eq "choco") { "choco" } else { "winget" }
            $apps = Read-LoomJson "applications.json"
            $found = @()
            if ($preference -eq "choco") {
                if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { Exit-Loom @{ ok = $true; ids = @() } }
                $listed = (& choco list --limit-output | Out-String)
                foreach ($prop in $apps.PSObject.Properties) {
                    $id = [string]$prop.Value.choco
                    if ((Test-BadId $id)) { continue }
                    if ($listed -match ("(?im)^{0}\|" -f [regex]::Escape($id))) { $found += $prop.Name }
                }
            } else {
                if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Exit-Loom @{ ok = $true; ids = @() } }
                Write-Loom "Asking WinGet which apps are installed"
                $listed = (& winget list --accept-source-agreements --disable-interactivity | Out-String)
                foreach ($prop in $apps.PSObject.Properties) {
                    $id = [string]$prop.Value.winget
                    if ((Test-BadId $id)) { continue }
                    if ($listed -like "*$id*") { $found += $prop.Name }
                }
            }
            Exit-Loom @{ ok = $true; ids = $found }
        }
        "features" {
            if (-not (Test-LoomAdmin)) { throw "Loom needs to run as administrator to enable Windows features." }
            $table = Get-Features
            $keys = @(As-List $body.keys)
            if ($keys.Count -eq 0) { throw "Select at least one feature." }
            $index = 0
            foreach ($key in $keys) {
                $index++
                $entry = $table.$key
                if (-not $entry) { Write-Loom "Unknown feature $key" -Level "WARN"; continue }
                Write-Loom "Enabling $($entry.Content)" -Percent ([int]((($index - 1) / $keys.Count) * 100))
                $failed = $false
                foreach ($name in (As-List $entry.feature)) {
                    if ([string]::IsNullOrWhiteSpace([string]$name)) { continue }
                    try {
                        Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop | Out-Null
                        Write-Loom "Enabled $name"
                    } catch {
                        $failed = $true
                        Write-Loom "Could not enable $name : $($_.Exception.Message)" -Level "ERROR"
                    }
                }
                if (-not $failed) {
                    foreach ($scr in (As-List $entry.InvokeScript)) { Invoke-LoomScript -Source ([string]$scr) -Name $key }
                }
            }
            Exit-Loom @{ ok = (-not $script:HadError) }
        }
        "button" {
            if (-not (Test-LoomAdmin)) { throw "Loom needs to run as administrator for this action." }
            Invoke-LoomActionButton -Key ([string]$body.key)
            Exit-Loom @{ ok = (-not $script:HadError) }
        }
        "updates" {
            if (-not (Test-LoomAdmin)) { throw "Loom needs to run as administrator to change Windows Update." }
            if ([string]$body.profile -eq "disable" -and -not [bool]$body.confirm) {
                throw "Disabling Windows Update was not confirmed."
            }
            Invoke-LoomUpdates -Profile ([string]$body.profile)
            Exit-Loom @{ ok = $true }
        }
        "appx" {
            if (-not (Test-LoomAdmin)) { throw "Loom needs to run as administrator to change inbox apps." }
            $catalog = Read-LoomJson "appx.json"
            $keys = @(As-List $body.ids)
            if ($keys.Count -eq 0) { throw "Select at least one app." }
            $mode = [string]$body.mode
            if ($mode -eq "remove") {
                $names = @()
                foreach ($key in $keys) {
                    if ($catalog.$key) { $names += [string]$catalog.$key.PackageId }
                }
                Remove-LoomAppx -Names $names
            } else {
                foreach ($key in $keys) {
                    if ($catalog.$key) { Install-LoomAppx $catalog.$key | Out-Null }
                }
            }
            Exit-Loom @{ ok = (-not $script:HadError) }
        }
        "appx-installed" {
            $catalog = Read-LoomJson "appx.json"
            $installed = @(Get-AppxPackage -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $found = @()
            foreach ($prop in $catalog.PSObject.Properties) {
                if ($installed -contains [string]$prop.Value.PackageId) { $found += $prop.Name }
            }
            Exit-Loom @{ ok = $true; ids = $found }
        }
        "iso-mount" {
            if (-not (Test-LoomAdmin)) { throw "Mounting a Windows image needs an administrator." }
            $path = [string]$body.path
            if (-not (Test-Path -LiteralPath $path)) { throw "ISO not found." }
            Write-Loom "Mounting ISO" -Percent 10
            $letter = Get-IsoVolume $path
            $root = "${letter}:\"
            $wim = Join-Path $root "sources\install.wim"
            $kind = "wim"
            if (-not (Test-Path -LiteralPath $wim)) {
                $wim = Join-Path $root "sources\install.esd"
                $kind = "esd"
            }
            if (-not (Test-Path -LiteralPath $wim)) { throw "This ISO has no sources\install.wim or install.esd." }
            $images = @(Get-WindowsImage -ImagePath $wim)
            $editions = @()
            foreach ($image in $images) {
                $detail = Get-WindowsImage -ImagePath $wim -Index $image.ImageIndex
                $editions += [pscustomobject]@{
                    index = $image.ImageIndex
                    name = [string]$image.ImageName
                    edition = [string]$detail.EditionId
                    size = [int64]$image.ImageSize
                }
            }
            $sizeGb = [math]::Round((Get-Item -LiteralPath $path).Length / 1GB, 2)
            Write-Loom "Mounted at ${letter}: ($($editions.Count) editions)" -Percent 100
            Exit-Loom @{ ok = $true; letter = [string]$letter; image = $wim; kind = $kind; editions = $editions; sizeGb = $sizeGb }
        }
        "iso-modify" {
            if (-not (Test-LoomAdmin)) { throw "Preparing Windows setup needs an administrator." }
            $path = [string]$body.path
            $index = [int]$body.index
            $edition = [string]$body.edition
            $inject = [bool]$body.injectDrivers
            $letter = Get-IsoVolume $path
            $source = "${letter}:\"
            $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $work = Join-Path $env:TEMP "Loom_WinISO_$stamp"
            $contents = Join-Path $work "iso"
            New-Item -ItemType Directory -Path $contents -Force | Out-Null
            Write-Loom "Copying the ISO. This needs several gigabytes of free space." -Percent 8
            Invoke-Robocopy $source $contents @("/E", "/NFL", "/NDL", "/NJH", "/NJS")
            $local = Join-Path $contents "sources\install.wim"
            $localKind = "wim"
            if (-not (Test-Path -LiteralPath $local)) {
                $local = Join-Path $contents "sources\install.esd"
                $localKind = "esd"
            }
            Get-ChildItem $contents -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.IsReadOnly = $false }
            $answer = Join-Path $engineDir "autounattend.xml"
            if (-not (Test-Path -LiteralPath $answer)) { throw "The Windows answer file is missing from Loom." }
            Copy-Item -LiteralPath $answer -Destination (Join-Path $contents "autounattend.xml") -Force
            if ($edition) {
                @"
[EditionID]
$edition
[Channel]
Retail
"@ | Set-Content -LiteralPath (Join-Path $contents "sources\ei.cfg") -Encoding Ascii
                Write-Loom "Pinned edition $edition"
            }
            Write-Loom "Wrote the answer file: local account, requirement bypass, and the staged first-logon cleanup." -Percent 55
            if ($inject) {
                if ($localKind -ne "wim") {
                    Write-Loom "Driver injection needs install.wim. This ISO uses install.esd, so the image was left unchanged." -Level "WARN"
                } else {
                    $drivers = Join-Path $work "drivers"
                    New-Item -ItemType Directory -Path $drivers -Force | Out-Null
                    Write-Loom "Exporting this PC's drivers" -Percent 62
                    & pnputil.exe /export-driver * $drivers | Out-Null
                    foreach ($target in @(
                        @{ Path = (Join-Path $contents "sources\boot.wim"); Index = 2 },
                        @{ Path = $local; Index = $index }
                    )) {
                        if (-not (Test-Path -LiteralPath $target.Path)) { continue }
                        $mount = Join-Path $work ("mount" + $target.Index)
                        New-Item -ItemType Directory -Path $mount -Force | Out-Null
                        $saved = $false
                        try {
                            Write-Loom "Adding drivers to $(Split-Path $target.Path -Leaf)" -Percent 75
                            Mount-WindowsImage -ImagePath $target.Path -Index $target.Index -Path $mount -ErrorAction Stop | Out-Null
                            $added = 0
                            Get-ChildItem $drivers -Filter *.inf -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                                try {
                                    Add-WindowsDriver -Path $mount -Driver $_.FullName -ErrorAction Stop | Out-Null
                                    $added++
                                } catch {}
                            }
                            if ($added -gt 0) {
                                Dismount-WindowsImage -Path $mount -Save -ErrorAction Stop | Out-Null
                                $saved = $true
                                Write-Loom "Added $added driver package(s)"
                            } else {
                                Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
                                Write-Loom "No compatible drivers were added" -Level "WARN"
                            }
                        } catch {
                            if (-not $saved) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null }
                            Write-Loom "Driver injection stopped: $($_.Exception.Message)" -Level "WARN"
                        }
                    }
                }
            }
            Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue | Out-Null
            Write-Loom "Setup files are ready." -Percent 100
            Exit-Loom @{ ok = $true; contents = $contents; work = $work }
        }
        "iso-export" {
            $contents = [string]$body.contents
            $output = [string]$body.output
            if (-not (Test-Path -LiteralPath $contents)) { throw "Prepare the image before saving an ISO." }
            $oscdimg = Find-Oscdimg
            if (-not $oscdimg) {
                Write-Loom "Installing oscdimg"
                Ensure-Winget
                & winget install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
                $oscdimg = Find-Oscdimg
            }
            if (-not $oscdimg) { throw "oscdimg.exe is not available. Install the Windows ADK Deployment Tools, or Microsoft.OSCDIMG with WinGet, then try again." }
            $parent = Split-Path $output -Parent
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Write-Loom "Building the ISO" -Percent 20
            $boot = "2#p0,e,b`"$contents\boot\etfsboot.com`"#pEF,e,b`"$contents\efi\microsoft\boot\efisys.bin`""
            & $oscdimg -m -o -u2 -udfver102 "-bootdata:$boot" "-lLOOM_WIN11" $contents $output
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw "oscdimg failed with exit code $LASTEXITCODE." }
            Write-Loom "Saved $output" -Percent 100
            Exit-Loom @{ ok = $true; output = $output }
        }
        "iso-usb-list" {
            $disks = @(Get-Disk | Where-Object { $_.BusType -eq "USB" } | Sort-Object Number)
            $items = @()
            foreach ($disk in $disks) {
                $items += [pscustomobject]@{
                    number = [int]$disk.Number
                    name = [string]$disk.FriendlyName
                    sizeGb = [math]::Round($disk.Size / 1GB, 1)
                    style = [string]$disk.PartitionStyle
                }
            }
            Exit-Loom @{ ok = $true; disks = $items }
        }
        "iso-usb-write" {
            if (-not (Test-LoomAdmin)) { throw "Writing a USB drive needs an administrator." }
            if (-not [bool]$body.confirm) { throw "USB erase was not confirmed." }
            $contents = [string]$body.contents
            $number = [int]$body.disk
            if (-not (Test-Path -LiteralPath $contents)) { throw "Prepare the image before writing a USB drive." }
            $esd = Join-Path $contents "sources\install.esd"
            if ((Test-Path -LiteralPath $esd) -and ((Get-Item -LiteralPath $esd).Length -ge 4GB)) {
                throw "This image contains an install.esd larger than 4 GB. FAT32 cannot hold it. Save an ISO instead."
            }
            $disk = Get-Disk -Number $number -ErrorAction Stop
            $systemDisk = (Get-Partition | Where-Object { $_.DriveLetter -eq "C" } | Select-Object -First 1).DiskNumber
            if ($disk.BusType -ne "USB") { throw "Disk $number is not a USB drive. Loom will not erase it." }
            if ($number -eq $systemDisk) { throw "Disk $number contains Windows. Loom will not erase it." }
            Write-Loom "Erasing USB disk $number ($($disk.FriendlyName))" -Percent 8
            $scriptFile = Join-Path $env:TEMP "loom-diskpart.txt"
            "select disk $number`nclean`nexit" | Set-Content -LiteralPath $scriptFile -Encoding Ascii
            & diskpart /s $scriptFile | Out-Null
            Start-Sleep -Seconds 2
            $again = Get-Disk -Number $number
            if ($again.PartitionStyle -eq "RAW") { Initialize-Disk -Number $number -PartitionStyle GPT }
            else { Set-Disk -Number $number -PartitionStyle GPT }
            $sizeMb = [int][Math]::Floor((Get-Disk -Number $number).Size / 1MB)
            $create = "create partition primary"
            if ($sizeMb -gt 32768) { $create = "create partition primary size=32768" }
            @("select disk $number", $create, "exit") | Set-Content -LiteralPath $scriptFile -Encoding Ascii
            & diskpart /s $scriptFile | Out-Null
            Start-Sleep -Seconds 2
            $part = Get-Partition -DiskNumber $number | Where-Object { $_.Type -eq "Basic" } | Select-Object -Last 1
            if (-not $part) { throw "The USB partition was not created." }
            $label = "LOOM" + (Get-Date -Format "MMdd")
            $part | Format-Volume -FileSystem FAT32 -NewFileSystemLabel $label -Force -Confirm:$false | Out-Null
            $used = @((Get-PSDrive -PSProvider FileSystem).Name)
            $letter = $null
            foreach ($char in [char[]](68..90)) {
                if ($used -notcontains [string]$char) { $letter = [string]$char; break }
            }
            if (-not $letter) { throw "No free drive letter between D and Z." }
            Set-Partition -DiskNumber $number -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter
            $dest = "${letter}:\"
            Write-Loom "Copying Windows onto $dest" -Percent 40
            $wim = Join-Path $contents "sources\install.wim"
            if ((Test-Path -LiteralPath $wim) -and ((Get-Item $wim).Length -gt 3800MB)) {
                New-Item -ItemType Directory -Path (Join-Path $dest "sources") -Force | Out-Null
                Split-WindowsImage -ImagePath $wim -SplitImagePath (Join-Path $dest "sources\install.swm") -FileSize 3800 -CheckIntegrity
                Invoke-Robocopy $contents $dest @("/E", "/XF", "install.wim", "/NFL", "/NDL", "/NJH", "/NJS")
            } else {
                Invoke-Robocopy $contents $dest @("/E", "/NFL", "/NDL", "/NJH", "/NJS")
            }
            Write-Loom "USB drive is ready." -Percent 100
            Exit-Loom @{ ok = $true; letter = $letter }
        }
        "iso-clean" {
            $path = [string]$body.path
            $work = [string]$body.work
            if ($path -and (Test-Path -LiteralPath $path)) {
                Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue | Out-Null
            }
            if ($work -and (Test-Path -LiteralPath $work)) {
                Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            }
            Exit-Loom @{ ok = $true }
        }
        default { throw "Unknown action $Action" }
    }
} catch {
    Write-Loom $_.Exception.Message -Level "ERROR"
    Exit-Loom @{ ok = $false; error = $_.Exception.Message } 1
}
