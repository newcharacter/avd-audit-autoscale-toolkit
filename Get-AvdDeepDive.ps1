<#
.SYNOPSIS
    AVD Deep Dive - Comprehensive environment dump for planning documents.

.DESCRIPTION
    Captures everything needed to make the audit plan specific:
    - Host pools with full config
    - VM sizes, counts, specs
    - Network config (VNet, subnet, NSG)
    - Storage (OS disks, FSLogix if detectable)
    - Load balancer settings
    - Applications and their distribution
    - AAD group assignments
    - Current session load
    - Scaling plan details (if any)

    Output is formatted for copy/paste into planning docs.

.EXAMPLE
    ./Get-AvdDeepDive.ps1 | Tee-Object -FilePath "AvdDeepDive.txt"

.PARAMETER InstallMissingModules
    Optional. Install missing Az modules into the current user scope.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$OutputPath = "outputs",
    [switch]$InstallMissingModules
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Collect all data
$allData = @{
    GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    HostPools = @()
    VMs = @()
    Networks = @()
    Storage = @()
    Apps = @()
    Assignments = @()
    ScalingPlans = @()
    Summary = @{}
}

Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  AVD DEEP DIVE - COMPREHENSIVE ENVIRONMENT AUDIT" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "================================================================================" -ForegroundColor Cyan

# Ensure modules
@("Az.DesktopVirtualization", "Az.Compute", "Az.Network", "Az.Resources") | ForEach-Object {
    if (-not (Get-Module -ListAvailable -Name $_)) {
        if (-not $InstallMissingModules) {
            Write-Host "Missing module: $_. Install it first or rerun with -InstallMissingModules." -ForegroundColor Red
            exit 1
        }
        Write-Host "Installing $_..." -ForegroundColor Yellow
        Install-Module $_ -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $_ -ErrorAction SilentlyContinue
}

$context = Get-AzContext
if (-not $context) { Write-Host "Run Connect-AzAccount first." -ForegroundColor Red; exit 1 }

Write-Host "`nConnected as: $($context.Account.Id)" -ForegroundColor Green
Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Gray

if ($SubscriptionId) { $subs = Get-AzSubscription -SubscriptionId $SubscriptionId }
else { $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } }

# ============================================================================
# SECTION 1: HOST POOLS & CONFIGURATION
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Yellow
Write-Host "  SECTION 1: HOST POOLS & CONFIGURATION" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Yellow

$totalHostPools = 0
$totalSessionHosts = 0
$totalPooled = 0
$totalPersonal = 0
$poolsWithScaling = 0
$poolsWithDiag = 0

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null
    Write-Host "`n>>> SUBSCRIPTION: $($sub.Name)" -ForegroundColor Cyan

    $hostPools = Get-AzWvdHostPool -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    $scalingPlans = Get-AzWvdScalingPlan -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    $workspaces = Get-AzWvdWorkspace -SubscriptionId $sub.Id -ErrorAction SilentlyContinue

    if (-not $hostPools) { Write-Host "  No host pools found" -ForegroundColor Gray; continue }

    foreach ($hp in $hostPools) {
        $totalHostPools++
        if ($hp.HostPoolType -eq "Pooled") { $totalPooled++ } else { $totalPersonal++ }

        $rgName = $hp.Id.Split("/")[4]
        Write-Host "`n  HOST POOL: $($hp.Name)" -ForegroundColor White
        Write-Host "  ─────────────────────────────────────────" -ForegroundColor Gray

        # Basic config
        Write-Host "    Type:              $($hp.HostPoolType)" -ForegroundColor Gray
        Write-Host "    Load Balancer:     $($hp.LoadBalancerType)" -ForegroundColor Gray
        Write-Host "    Max Sessions:      $($hp.MaxSessionLimit)" -ForegroundColor Gray
        Write-Host "    Start VM Connect:  $($hp.StartVMOnConnect)" -ForegroundColor Gray
        Write-Host "    Validation Env:    $($hp.ValidationEnvironment)" -ForegroundColor Gray
        Write-Host "    Location:          $($hp.Location)" -ForegroundColor Gray
        Write-Host "    Resource Group:    $rgName" -ForegroundColor Gray

        # Scaling plan
        $plan = $scalingPlans | Where-Object { $_.HostPoolReference.HostPoolArmPath -contains $hp.Id }
        if ($plan) {
            $poolsWithScaling++
            Write-Host "    Scaling Plan:      $($plan.Name) [ATTACHED]" -ForegroundColor Green
        } else {
            Write-Host "    Scaling Plan:      NONE" -ForegroundColor Red
        }

        # Diagnostics
        $diag = Get-AzDiagnosticSetting -ResourceId $hp.Id -ErrorAction SilentlyContinue
        if ($diag) {
            $poolsWithDiag++
            Write-Host "    Diagnostics:       ENABLED" -ForegroundColor Green
        } else {
            Write-Host "    Diagnostics:       DISABLED" -ForegroundColor Red
        }

        # Session hosts
        $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue
        $shCount = if ($sessionHosts) { $sessionHosts.Count } else { 0 }
        $totalSessionHosts += $shCount
        $available = ($sessionHosts | Where-Object { $_.Status -eq "Available" }).Count
        $shutdown = ($sessionHosts | Where-Object { $_.Status -eq "Shutdown" }).Count
        $unavailable = ($sessionHosts | Where-Object { $_.Status -eq "Unavailable" }).Count

        Write-Host "    Session Hosts:     $shCount total ($available available, $shutdown shutdown, $unavailable unavailable)" -ForegroundColor Gray

        # User sessions
        $userSessions = Get-AzWvdUserSession -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue
        $activeCount = ($userSessions | Where-Object { $_.SessionState -eq "Active" }).Count
        $discCount = ($userSessions | Where-Object { $_.SessionState -eq "Disconnected" }).Count
        Write-Host "    Current Sessions:  $($userSessions.Count) total ($activeCount active, $discCount disconnected)" -ForegroundColor Gray

        # App groups
        $appGroups = Get-AzWvdApplicationGroup -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Where-Object { $_.HostPoolArmPath -eq $hp.Id }
        Write-Host "    App Groups:        $($appGroups.Count)" -ForegroundColor Gray
        foreach ($ag in $appGroups) {
            $agType = $ag.ApplicationGroupType
            Write-Host "      - $($ag.Name) [$agType]" -ForegroundColor DarkGray
        }

        # Store for later
        $allData.HostPools += [PSCustomObject]@{
            Subscription = $sub.Name
            ResourceGroup = $rgName
            Name = $hp.Name
            Type = $hp.HostPoolType
            LoadBalancer = $hp.LoadBalancerType
            MaxSessions = $hp.MaxSessionLimit
            StartVMOnConnect = $hp.StartVMOnConnect
            Location = $hp.Location
            SessionHostCount = $shCount
            AvailableHosts = $available
            ShutdownHosts = $shutdown
            CurrentSessions = $userSessions.Count
            ActiveSessions = $activeCount
            HasScalingPlan = [bool]$plan
            ScalingPlanName = $plan.Name
            HasDiagnostics = [bool]$diag
            AppGroupCount = $appGroups.Count
        }
    }
}

# ============================================================================
# SECTION 2: VIRTUAL MACHINES & SPECS
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Yellow
Write-Host "  SECTION 2: VIRTUAL MACHINES & SPECS" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Yellow

$vmSizes = @{}
$vmImages = @{}
$vmOsDisks = @{}

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null

    $hostPools = Get-AzWvdHostPool -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    foreach ($hp in $hostPools) {
        $rgName = $hp.Id.Split("/")[4]
        $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue

        Write-Host "`n  VMs for: $($hp.Name)" -ForegroundColor White

        foreach ($sh in $sessionHosts) {
            $vmName = $sh.Name.Split("/")[-1].Split(".")[0]

            # Try to get VM details
            $vm = Get-AzVM -Name $vmName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
            if (-not $vm) {
                # Try other RGs
                $vm = Get-AzVM -Name $vmName -ErrorAction SilentlyContinue
            }

            if ($vm) {
                $size = $vm.HardwareProfile.VmSize
                if ($vmSizes.ContainsKey($size)) { $vmSizes[$size]++ } else { $vmSizes[$size] = 1 }

                # Image info
                $imgRef = $vm.StorageProfile.ImageReference
                $imgStr = if ($imgRef.Id) {
                    $imgRef.Id.Split("/")[-1]
                } elseif ($imgRef.Offer) {
                    "$($imgRef.Publisher)/$($imgRef.Offer)/$($imgRef.Sku)"
                } else { "Custom/Unknown" }
                if ($vmImages.ContainsKey($imgStr)) { $vmImages[$imgStr]++ } else { $vmImages[$imgStr] = 1 }

                # OS Disk
                $osDisk = $vm.StorageProfile.OsDisk
                $diskType = "Unknown"
                try {
                    $disk = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $osDisk.Name -ErrorAction SilentlyContinue
                    if ($disk) { $diskType = $disk.Sku.Name }
                } catch {}
                if ($vmOsDisks.ContainsKey($diskType)) { $vmOsDisks[$diskType]++ } else { $vmOsDisks[$diskType] = 1 }

                # Network
                $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
                $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction SilentlyContinue
                $subnetId = $nic.IpConfigurations[0].Subnet.Id
                $vnetName = $subnetId.Split("/")[-3]
                $subnetName = $subnetId.Split("/")[-1]

                Write-Host "    $vmName" -ForegroundColor Gray
                Write-Host "      Size: $size | Disk: $diskType | VNet: $vnetName/$subnetName" -ForegroundColor DarkGray

                $allData.VMs += [PSCustomObject]@{
                    HostPool = $hp.Name
                    VMName = $vmName
                    Size = $size
                    Image = $imgStr
                    OsDiskType = $diskType
                    OsDiskSize = $osDisk.DiskSizeGB
                    VNet = $vnetName
                    Subnet = $subnetName
                    Status = $sh.Status
                    Sessions = $sh.Session
                }
            } else {
                Write-Host "    $vmName - [VM details not accessible]" -ForegroundColor DarkGray
            }
        }
    }
}

Write-Host "`n  VM SIZE DISTRIBUTION:" -ForegroundColor White
$vmSizes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Host "    $($_.Key): $($_.Value) VMs" -ForegroundColor Gray
}

Write-Host "`n  IMAGE DISTRIBUTION:" -ForegroundColor White
$vmImages.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Host "    $($_.Key): $($_.Value) VMs" -ForegroundColor Gray
}

Write-Host "`n  OS DISK TYPES:" -ForegroundColor White
$vmOsDisks.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Host "    $($_.Key): $($_.Value) VMs" -ForegroundColor Gray
}

# ============================================================================
# SECTION 3: NETWORK CONFIGURATION
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Yellow
Write-Host "  SECTION 3: NETWORK CONFIGURATION" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Yellow

$vnets = @{}
foreach ($vm in $allData.VMs) {
    $key = "$($vm.VNet)/$($vm.Subnet)"
    if (-not $vnets[$key]) { $vnets[$key] = @{ Count = 0; HostPools = @() } }
    $vnets[$key].Count++
    if ($vm.HostPool -notin $vnets[$key].HostPools) { $vnets[$key].HostPools += $vm.HostPool }
}

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null
    Write-Host "`n  Subscription: $($sub.Name)" -ForegroundColor Cyan

    foreach ($vnetKey in $vnets.Keys) {
        $vnetName = $vnetKey.Split("/")[0]
        $subnetName = $vnetKey.Split("/")[1]

        $vnet = Get-AzVirtualNetwork -Name $vnetName -ErrorAction SilentlyContinue
        if ($vnet) {
            Write-Host "`n    VNET: $vnetName" -ForegroundColor White
            Write-Host "      Address Space: $($vnet.AddressSpace.AddressPrefixes -join ', ')" -ForegroundColor Gray
            Write-Host "      Location: $($vnet.Location)" -ForegroundColor Gray

            $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
            if ($subnet) {
                Write-Host "      Subnet: $subnetName ($($subnet.AddressPrefix))" -ForegroundColor Gray

                # NSG - initialize before check to avoid uninitialized variable
                $nsgName = $null
                if ($subnet.NetworkSecurityGroup) {
                    $nsgName = $subnet.NetworkSecurityGroup.Id.Split("/")[-1]
                    Write-Host "      NSG: $nsgName" -ForegroundColor Gray
                } else {
                    Write-Host "      NSG: None attached" -ForegroundColor Yellow
                }
            }

            Write-Host "      AVD Hosts: $($vnets[$vnetKey].Count) VMs" -ForegroundColor Gray
            Write-Host "      Host Pools: $($vnets[$vnetKey].HostPools -join ', ')" -ForegroundColor Gray

            $allData.Networks += [PSCustomObject]@{
                VNet = $vnetName
                AddressSpace = ($vnet.AddressSpace.AddressPrefixes -join ', ')
                Subnet = $subnetName
                SubnetPrefix = $subnet.AddressPrefix
                NSG = $nsgName
                VMCount = $vnets[$vnetKey].Count
                HostPools = ($vnets[$vnetKey].HostPools -join ', ')
            }
        }
    }
}

# ============================================================================
# SECTION 4: APPLICATIONS & DISTRIBUTION
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Yellow
Write-Host "  SECTION 4: APPLICATIONS & DISTRIBUTION" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Yellow

$appCount = 0
$desktopCount = 0

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null

    $appGroups = Get-AzWvdApplicationGroup -SubscriptionId $sub.Id -ErrorAction SilentlyContinue

    foreach ($ag in $appGroups) {
        Write-Host "`n  APP GROUP: $($ag.Name) [$($ag.ApplicationGroupType)]" -ForegroundColor White

        if ($ag.ApplicationGroupType -eq "RemoteApp") {
            $apps = Get-AzWvdApplication -ResourceGroupName $ag.ResourceGroupName -ApplicationGroupName $ag.Name -ErrorAction SilentlyContinue
            $appCount += $apps.Count
            Write-Host "    Published Apps: $($apps.Count)" -ForegroundColor Gray

            foreach ($app in $apps) {
                Write-Host "      - $($app.FriendlyName)" -ForegroundColor DarkGray
                $allData.Apps += [PSCustomObject]@{
                    AppGroup = $ag.Name
                    AppGroupType = $ag.ApplicationGroupType
                    AppName = $app.Name
                    FriendlyName = $app.FriendlyName
                    FilePath = $app.FilePath
                    CommandLine = $app.CommandLineSetting
                }
            }
        } else {
            $desktopCount++
            Write-Host "    [Full Desktop]" -ForegroundColor Gray
            $allData.Apps += [PSCustomObject]@{
                AppGroup = $ag.Name
                AppGroupType = $ag.ApplicationGroupType
                AppName = "SessionDesktop"
                FriendlyName = "[Full Desktop]"
                FilePath = ""
                CommandLine = ""
            }
        }

        # Assignments
        $path = "/subscriptions/$($sub.Id)/resourceGroups/$($ag.ResourceGroupName)/providers/Microsoft.DesktopVirtualization/applicationGroups/$($ag.Name)/assignments?api-version=2024-04-03"
        $resp = Invoke-AzRestMethod -Path $path -Method GET -ErrorAction SilentlyContinue
        $assignments = ($resp.Content | ConvertFrom-Json).value

        $groupCount = 0
        $userCount = 0
        foreach ($a in $assignments) {
            try {
                $g = Get-AzADGroup -ObjectId $a.principalId -ErrorAction Stop
                $groupCount++
                $allData.Assignments += [PSCustomObject]@{
                    AppGroup = $ag.Name
                    PrincipalType = "Group"
                    PrincipalName = $g.DisplayName
                    PrincipalId = $a.principalId
                }
            } catch {
                try {
                    $u = Get-AzADUser -ObjectId $a.principalId -ErrorAction Stop
                    $userCount++
                    $allData.Assignments += [PSCustomObject]@{
                        AppGroup = $ag.Name
                        PrincipalType = "User"
                        PrincipalName = $u.DisplayName
                        PrincipalId = $a.principalId
                    }
                } catch {}
            }
        }
        Write-Host "    Assignments: $groupCount groups, $userCount direct users" -ForegroundColor Gray
    }
}

# ============================================================================
# SECTION 5: SCALING PLANS DETAIL
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Yellow
Write-Host "  SECTION 5: SCALING PLANS DETAIL" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Yellow

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null

    $scalingPlans = Get-AzWvdScalingPlan -SubscriptionId $sub.Id -ErrorAction SilentlyContinue

    if (-not $scalingPlans) {
        Write-Host "`n  No scaling plans found in $($sub.Name)" -ForegroundColor Yellow
        continue
    }

    foreach ($sp in $scalingPlans) {
        Write-Host "`n  SCALING PLAN: $($sp.Name)" -ForegroundColor White
        Write-Host "    Timezone: $($sp.TimeZone)" -ForegroundColor Gray
        Write-Host "    Host Pools:" -ForegroundColor Gray
        foreach ($hpRef in $sp.HostPoolReference) {
            $hpName = $hpRef.HostPoolArmPath.Split("/")[-1]
            $enabled = if ($hpRef.ScalingPlanEnabled) { "Enabled" } else { "Disabled" }
            Write-Host "      - $hpName [$enabled]" -ForegroundColor DarkGray
        }

        Write-Host "    Schedules:" -ForegroundColor Gray
        foreach ($sched in $sp.Schedule) {
            Write-Host "      $($sched.Name): $($sched.DaysOfWeek -join ',')" -ForegroundColor DarkGray
            Write-Host "        Ramp-up: $($sched.RampUpStartTime.Hour):$($sched.RampUpStartTime.Minute.ToString('00')) | Min Hosts: $($sched.RampUpMinimumHostsPct)%" -ForegroundColor DarkGray
            Write-Host "        Peak: $($sched.PeakStartTime.Hour):$($sched.PeakStartTime.Minute.ToString('00'))" -ForegroundColor DarkGray
            Write-Host "        Ramp-down: $($sched.RampDownStartTime.Hour):$($sched.RampDownStartTime.Minute.ToString('00')) | Force Logoff: $($sched.RampDownForceLogoffUser)" -ForegroundColor DarkGray
            Write-Host "        Off-peak: $($sched.OffPeakStartTime.Hour):$($sched.OffPeakStartTime.Minute.ToString('00'))" -ForegroundColor DarkGray
        }

        $allData.ScalingPlans += [PSCustomObject]@{
            Name = $sp.Name
            Timezone = $sp.TimeZone
            HostPools = ($sp.HostPoolReference | ForEach-Object { $_.HostPoolArmPath.Split("/")[-1] }) -join ", "
            Schedules = $sp.Schedule.Count
        }
    }
}

# ============================================================================
# SECTION 6: FSLOGIX / PROFILE STORAGE (Best Effort)
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Yellow
Write-Host "  SECTION 6: STORAGE & FSLOGIX (Best Effort Detection)" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Yellow

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null

    # Look for Azure Files shares that might be FSLogix
    $storageAccounts = Get-AzStorageAccount -ErrorAction SilentlyContinue

    foreach ($sa in $storageAccounts) {
        if ($sa.Kind -eq "FileStorage" -or $sa.Name -match "fslogix|profile|avd") {
            Write-Host "`n  STORAGE ACCOUNT: $($sa.StorageAccountName)" -ForegroundColor White
            Write-Host "    Kind: $($sa.Kind)" -ForegroundColor Gray
            Write-Host "    SKU: $($sa.Sku.Name)" -ForegroundColor Gray
            Write-Host "    Location: $($sa.Location)" -ForegroundColor Gray

            try {
                $ctx = $sa.Context
                $shares = Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue
                foreach ($share in $shares) {
                    Write-Host "    Share: $($share.Name)" -ForegroundColor Gray
                }
            } catch {
                Write-Host "    [Cannot enumerate shares - check permissions]" -ForegroundColor Yellow
            }

            $allData.Storage += [PSCustomObject]@{
                StorageAccount = $sa.StorageAccountName
                Kind = $sa.Kind
                SKU = $sa.Sku.Name
                Location = $sa.Location
            }
        }
    }

    # Look for Azure NetApp Files
    $anfAccounts = Get-AzNetAppFilesAccount -ErrorAction SilentlyContinue
    foreach ($anf in $anfAccounts) {
        Write-Host "`n  NETAPP ACCOUNT: $($anf.Name)" -ForegroundColor White
        Write-Host "    Location: $($anf.Location)" -ForegroundColor Gray

        $allData.Storage += [PSCustomObject]@{
            StorageAccount = $anf.Name
            Kind = "NetAppFiles"
            SKU = "N/A"
            Location = $anf.Location
        }
    }
}

if ($allData.Storage.Count -eq 0) {
    Write-Host "`n  No obvious FSLogix/profile storage detected." -ForegroundColor Yellow
    Write-Host "  Check VM config or GPO for FSLogix VHDLocations setting." -ForegroundColor Yellow
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "  SUMMARY - USE THESE VALUES IN YOUR PLAN" -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green

Write-Host @"

ENVIRONMENT OVERVIEW
--------------------
Total Subscriptions Scanned:    $($subs.Count)
Total Host Pools:               $totalHostPools
  - Pooled:                     $totalPooled
  - Personal:                   $totalPersonal
Total Session Hosts (VMs):      $totalSessionHosts
Host Pools with Scaling Plans:  $poolsWithScaling / $totalHostPools
Host Pools with Diagnostics:    $poolsWithDiag / $totalHostPools

VM SIZES IN USE
---------------
"@ -ForegroundColor White

$vmSizes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Host "$($_.Key): $($_.Value) VMs" -ForegroundColor Gray
}

Write-Host @"

IMAGES IN USE
-------------
"@ -ForegroundColor White

$vmImages.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Host "$($_.Key): $($_.Value) VMs" -ForegroundColor Gray
}

Write-Host @"

APPLICATIONS
------------
Total RemoteApps Published:     $appCount
Full Desktop App Groups:        $desktopCount
Total App Groups:               $($allData.Apps | Select-Object AppGroup -Unique).Count

AAD ASSIGNMENTS
---------------
Total Group Assignments:        $(($allData.Assignments | Where-Object { $_.PrincipalType -eq 'Group' }).Count)
Unique Groups Used:             $(($allData.Assignments | Where-Object { $_.PrincipalType -eq 'Group' } | Select-Object PrincipalName -Unique).Count)
Direct User Assignments:        $(($allData.Assignments | Where-Object { $_.PrincipalType -eq 'User' }).Count)

"@ -ForegroundColor White

# Export everything
$allData.Summary = @{
    TotalHostPools = $totalHostPools
    PooledHostPools = $totalPooled
    PersonalHostPools = $totalPersonal
    TotalSessionHosts = $totalSessionHosts
    PoolsWithScaling = $poolsWithScaling
    PoolsWithDiagnostics = $poolsWithDiag
    TotalApps = $appCount
    DesktopAppGroups = $desktopCount
    VMSizes = $vmSizes
    Images = $vmImages
}

$jsonPath = Join-Path $OutputPath "AvdDeepDive-$timestamp.json"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$allData | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding UTF8

$allData.HostPools | Export-Csv (Join-Path $OutputPath "AvdDeepDive-HostPools-$timestamp.csv") -NoTypeInformation
$allData.VMs | Export-Csv (Join-Path $OutputPath "AvdDeepDive-VMs-$timestamp.csv") -NoTypeInformation
$allData.Apps | Export-Csv (Join-Path $OutputPath "AvdDeepDive-Apps-$timestamp.csv") -NoTypeInformation
$allData.Assignments | Export-Csv (Join-Path $OutputPath "AvdDeepDive-Assignments-$timestamp.csv") -NoTypeInformation

Write-Host "================================================================================" -ForegroundColor Green
Write-Host "  EXPORTS" -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "JSON (all data):    AvdDeepDive-$timestamp.json" -ForegroundColor White
Write-Host "Host Pools CSV:     AvdDeepDive-HostPools-$timestamp.csv" -ForegroundColor White
Write-Host "VMs CSV:            AvdDeepDive-VMs-$timestamp.csv" -ForegroundColor White
Write-Host "Apps CSV:           AvdDeepDive-Apps-$timestamp.csv" -ForegroundColor White
Write-Host "Assignments CSV:    AvdDeepDive-Assignments-$timestamp.csv" -ForegroundColor White

Write-Host "`n>>> Copy the SUMMARY section above into your planning document <<<" -ForegroundColor Cyan
Write-Host ">>> Or send me the JSON file and I'll update the plan with real values <<<`n" -ForegroundColor Cyan
