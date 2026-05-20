<#
.SYNOPSIS
    AVD Environment Inventory - Maps host pools, app groups, workspaces, session hosts, scaling plans.

.DESCRIPTION
    Run this in Azure Cloud Shell (PowerShell) or on a machine with Az + Az.DesktopVirtualization modules.
    Outputs a table to screen plus CSV/JSON files for reporting.

.PARAMETER SubscriptionId
    Optional. Target a specific subscription. If omitted, scans all subscriptions you have access to.

.PARAMETER OutputPath
    Optional. Directory for output files. Defaults to outputs/.

.EXAMPLE
    # In Cloud Shell:
    ./Get-AvdInventory.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

    # Scan all accessible subscriptions:
    ./Get-AvdInventory.ps1

.NOTES
    Author: AVD Audit Toolkit
    Requires: Az.DesktopVirtualization module (auto-installs if missing)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "outputs"
)

$ErrorActionPreference = "Continue"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AVD Environment Inventory Scanner" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Ensure AVD module is available
if (-not (Get-Module -ListAvailable -Name Az.DesktopVirtualization)) {
    Write-Host "Installing Az.DesktopVirtualization module..." -ForegroundColor Yellow
    Install-Module Az.DesktopVirtualization -Scope CurrentUser -Force -AllowClobber
}

Import-Module Az.DesktopVirtualization -ErrorAction SilentlyContinue

# Verify Az connection
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Not logged in to Azure. Run Connect-AzAccount first." -ForegroundColor Red
        exit 1
    }
    Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host "Azure connection error: $_" -ForegroundColor Red
    exit 1
}

# Get target subscriptions
if ($SubscriptionId) {
    $subs = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
} else {
    $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

Write-Host "Scanning $($subs.Count) subscription(s)...`n" -ForegroundColor Cyan

$results = @()
$allVMs = @()
$allScalingPlans = @()
$allAppGroups = @()
$allWorkspaces = @()

foreach ($sub in $subs) {
    Write-Host ">>> Subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan

    try {
        Select-AzSubscription -SubscriptionId $sub.Id | Out-Null
    } catch {
        Write-Host "  [SKIP] Cannot access subscription: $_" -ForegroundColor Yellow
        continue
    }

    # Get all AVD objects in subscription
    $hostPools = @()
    $workspaces = @()
    $scalingPlans = @()

    try {
        $hostPools = Get-AzWvdHostPool -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    } catch { }

    try {
        $workspaces = Get-AzWvdWorkspace -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
        $allWorkspaces += $workspaces
    } catch { }

    try {
        $scalingPlans = Get-AzWvdScalingPlan -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
        $allScalingPlans += $scalingPlans
    } catch { }

    if (-not $hostPools -or $hostPools.Count -eq 0) {
        Write-Host "  No host pools found in this subscription.`n" -ForegroundColor Gray
        continue
    }

    Write-Host "  Found $($hostPools.Count) host pool(s)" -ForegroundColor Green

    foreach ($hp in $hostPools) {
        Write-Host "    Processing: $($hp.Name)" -ForegroundColor Yellow

        $rgName = $hp.Id.Split("/")[4]  # Extract RG from resource ID

        # Session hosts in this pool
        $sessionHosts = @()
        try {
            $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue
        } catch { }

        # App groups associated with this host pool
        $appGroups = @()
        try {
            $allAgs = Get-AzWvdApplicationGroup -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
            $appGroups = $allAgs | Where-Object { $_.HostPoolArmPath -eq $hp.Id }
            $allAppGroups += $appGroups
        } catch { }

        # Applications within app groups (for RemoteApp pools)
        $appNames = @()
        foreach ($ag in $appGroups) {
            if ($ag.ApplicationGroupType -eq "RemoteApp") {
                try {
                    $agRg = $ag.Id.Split("/")[4]
                    $apps = Get-AzWvdApplication -ResourceGroupName $agRg -ApplicationGroupName $ag.Name -ErrorAction SilentlyContinue
                    $appNames += $apps.FriendlyName
                } catch { }
            }
        }

        # Workspaces referencing these app groups
        $appGroupIds = $appGroups.Id
        $wsForPool = @()
        if ($appGroupIds) {
            $wsForPool = $workspaces | Where-Object {
                $_.ApplicationGroupReference -and
                ($_.ApplicationGroupReference | Where-Object { $appGroupIds -contains $_ })
            }
        }

        # Scaling plans referencing this host pool
        $plansForPool = @()
        if ($scalingPlans) {
            $plansForPool = $scalingPlans | Where-Object {
                $_.HostPoolReference.HostPoolArmPath -contains $hp.Id
            }
        }

        # Diagnostics settings
        $diag = $null
        $diagTarget = ""
        try {
            $diag = Get-AzDiagnosticSetting -ResourceId $hp.Id -ErrorAction SilentlyContinue
            if ($diag) {
                $diagTarget = if ($diag.WorkspaceId) { $diag.WorkspaceId }
                              elseif ($diag.StorageAccountId) { $diag.StorageAccountId }
                              else { "Configured" }
            }
        } catch { }

        # VM details from session hosts
        $vmDetails = @()
        $vmNames = @()
        foreach ($sh in $sessionHosts) {
            $nameParts = $sh.Name.Split("/")
            if ($nameParts.Count -ge 2) {
                $sessionHostFqdn = $nameParts[-1]
                $shortName = $sessionHostFqdn.Split(".")[0]
                $vmNames += $shortName

                # Try to get VM details
                try {
                    $vm = Get-AzVM -Name $shortName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
                    if ($vm) {
                        $vmDetails += [PSCustomObject]@{
                            Name = $shortName
                            Size = $vm.HardwareProfile.VmSize
                            OsType = $vm.StorageProfile.OsDisk.OsType
                            ImageRef = if ($vm.StorageProfile.ImageReference.Id) {
                                $vm.StorageProfile.ImageReference.Id.Split("/")[-1]
                            } elseif ($vm.StorageProfile.ImageReference.Offer) {
                                "$($vm.StorageProfile.ImageReference.Publisher)/$($vm.StorageProfile.ImageReference.Offer)/$($vm.StorageProfile.ImageReference.Sku)"
                            } else { "Unknown" }
                        }
                        $allVMs += $vm
                    }
                } catch { }
            }
        }

        $vmSizes = ($vmDetails.Size | Sort-Object -Unique) -join ","
        $vmImages = ($vmDetails.ImageRef | Sort-Object -Unique) -join ","

        # Count hosts by status
        $availableHosts = ($sessionHosts | Where-Object { $_.Status -eq "Available" }).Count
        $unavailableHosts = ($sessionHosts | Where-Object { $_.Status -eq "Unavailable" }).Count
        $shutdownHosts = ($sessionHosts | Where-Object { $_.Status -eq "Shutdown" }).Count

        # Build tags string
        $tagString = ""
        if ($hp.Tag) {
            $tagString = ($hp.Tag.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ";"
        }

        # Determine environment from tags/name
        $envGuess = "Unknown"
        if ($hp.Name -match "prod|prd" -and $hp.Name -notmatch "non-?prod|nprd|nonprod") {
            $envGuess = "Production"
        } elseif ($hp.Name -match "non-?prod|nprd|nonprod|dev|test|uat|staging") {
            $envGuess = "Non-Production"
        } elseif ($tagString -match "env.*=.*prod") {
            $envGuess = "Production"
        }

        $results += [PSCustomObject]@{
            SubscriptionName    = $sub.Name
            SubscriptionId      = $sub.Id
            ResourceGroup       = $rgName
            HostPoolName        = $hp.Name
            FriendlyName        = $hp.FriendlyName
            Environment         = $envGuess
            HostPoolType        = $hp.HostPoolType            # Pooled / Personal
            LoadBalancerType    = $hp.LoadBalancerType        # BreadthFirst / DepthFirst / Persistent
            MaxSessionLimit     = $hp.MaxSessionLimit
            Location            = $hp.Location
            ValidationEnv       = $hp.ValidationEnvironment
            StartVMOnConnect    = $hp.StartVMOnConnect
            Tags                = $tagString
            AppGroupCount       = $appGroups.Count
            AppGroups           = ($appGroups.Name -join ",")
            AppGroupTypes       = ($appGroups.ApplicationGroupType | Sort-Object -Unique) -join ","
            PublishedApps       = ($appNames | Sort-Object -Unique) -join ","
            WorkspaceCount      = $wsForPool.Count
            Workspaces          = ($wsForPool.Name -join ",")
            TotalSessionHosts   = $sessionHosts.Count
            AvailableHosts      = $availableHosts
            UnavailableHosts    = $unavailableHosts
            ShutdownHosts       = $shutdownHosts
            SessionHostNames    = ($vmNames -join ",")
            VmSizes             = $vmSizes
            VmImages            = $vmImages
            ScalingPlanCount    = $plansForPool.Count
            ScalingPlans        = ($plansForPool.Name -join ",")
            DiagnosticsEnabled  = [bool]$diag
            DiagnosticsTarget   = $diagTarget
            RegistrationExpiry  = $hp.RegistrationInfoExpirationTime
        }
    }
    Write-Host ""
}

if ($results.Count -eq 0) {
    Write-Host "No AVD host pools found in any subscription." -ForegroundColor Yellow
    exit 0
}

# Summary statistics
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nHost Pools Found: $($results.Count)" -ForegroundColor White
Write-Host "  - Pooled: $(($results | Where-Object {$_.HostPoolType -eq 'Pooled'}).Count)"
Write-Host "  - Personal: $(($results | Where-Object {$_.HostPoolType -eq 'Personal'}).Count)"

$totalHosts = ($results | Measure-Object -Property TotalSessionHosts -Sum).Sum
$totalAvailable = ($results | Measure-Object -Property AvailableHosts -Sum).Sum
Write-Host "`nTotal Session Hosts: $totalHosts" -ForegroundColor White
Write-Host "  - Available: $totalAvailable"
Write-Host "  - Shutdown: $(($results | Measure-Object -Property ShutdownHosts -Sum).Sum)"
Write-Host "  - Unavailable: $(($results | Measure-Object -Property UnavailableHosts -Sum).Sum)"

$poolsWithScaling = ($results | Where-Object { $_.ScalingPlanCount -gt 0 }).Count
Write-Host "`nScaling Plans:" -ForegroundColor White
Write-Host "  - Host pools WITH scaling: $poolsWithScaling"
Write-Host "  - Host pools WITHOUT scaling: $($results.Count - $poolsWithScaling)" -ForegroundColor $(if ($results.Count - $poolsWithScaling -gt 0) { "Yellow" } else { "White" })

$poolsWithDiag = ($results | Where-Object { $_.DiagnosticsEnabled }).Count
Write-Host "`nDiagnostics:" -ForegroundColor White
Write-Host "  - Host pools WITH diagnostics: $poolsWithDiag"
Write-Host "  - Host pools WITHOUT diagnostics: $($results.Count - $poolsWithDiag)" -ForegroundColor $(if ($results.Count - $poolsWithDiag -gt 0) { "Yellow" } else { "White" })

# Output table
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  HOST POOL DETAILS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$results | Sort-Object SubscriptionName, ResourceGroup, HostPoolName |
    Format-Table @{L='Pool';E={$_.HostPoolName}},
                 @{L='Type';E={$_.HostPoolType}},
                 @{L='LB';E={$_.LoadBalancerType}},
                 @{L='MaxSess';E={$_.MaxSessionLimit}},
                 @{L='Hosts';E={"$($_.AvailableHosts)/$($_.TotalSessionHosts)"}},
                 @{L='AppGrps';E={$_.AppGroupCount}},
                 @{L='Scaling';E={if($_.ScalingPlanCount -gt 0){"Yes"}else{"NO"}}},
                 @{L='Diag';E={if($_.DiagnosticsEnabled){"Yes"}else{"NO"}}},
                 @{L='Env';E={$_.Environment}} -AutoSize

# Export files
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$csvPath = Join-Path $OutputPath "AvdInventory-$timestamp.csv"
$jsonPath = Join-Path $OutputPath "AvdInventory-$timestamp.json"

$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$results | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Encoding UTF8

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  OUTPUT FILES" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "CSV: $csvPath" -ForegroundColor White
Write-Host "JSON: $jsonPath" -ForegroundColor White

# Also output scaling plan details if any exist
if ($allScalingPlans.Count -gt 0) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  SCALING PLANS DETAIL" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $allScalingPlans | ForEach-Object {
        Write-Host "Plan: $($_.Name)" -ForegroundColor Yellow
        Write-Host "  Schedule: $($_.ScheduleTimeZone)"
        Write-Host "  Host Pools: $(($_.HostPoolReference.HostPoolArmPath | ForEach-Object { $_.Split('/')[-1] }) -join ', ')"
        Write-Host ""
    }
}

Write-Host "`nInventory scan complete.`n" -ForegroundColor Green
