<#
.SYNOPSIS
    Get all AVD Application Group assignments (groups AND users) across subscriptions.

.DESCRIPTION
    Exports a CSV showing every principal (AAD group, user, service principal) assigned
    to each AVD Application Group. Works reliably in Azure Cloud Shell.

    Unlike the broken Copilot scripts, this one:
    - Uses pure Az PowerShell (no az CLI extension issues)
    - Gets BOTH groups and users (so you won't get empty output)
    - Handles multi-subscription environments
    - Actually resolves display names

.PARAMETER SubscriptionId
    Optional. Target specific subscription. Omit to scan all accessible subscriptions.

.PARAMETER GroupsOnly
    Optional. Only output group assignments (skip users/service principals).

.PARAMETER InstallMissingModules
    Optional. Install missing Az modules into the current user scope.

.EXAMPLE
    ./Get-AvdAppGroupAssignments.ps1

.EXAMPLE
    ./Get-AvdAppGroupAssignments.ps1 -SubscriptionId "xxx" -GroupsOnly
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [switch]$GroupsOnly,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "outputs",

    [Parameter(Mandatory = $false)]
    [switch]$InstallMissingModules
)

$ErrorActionPreference = "Continue"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AVD App Group Assignment Export" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Ensure modules are loaded (Cloud Shell has these pre-installed)
$requiredModules = @("Az.Accounts", "Az.DesktopVirtualization", "Az.Resources")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        if (-not $InstallMissingModules) {
            Write-Host "Missing module: $mod. Install it first or rerun with -InstallMissingModules." -ForegroundColor Red
            exit 1
        }
        Write-Host "Installing $mod..." -ForegroundColor Yellow
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}

# Verify connection
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Not logged in. Run Connect-AzAccount first." -ForegroundColor Red
        exit 1
    }
    Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green
    Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Gray
} catch {
    Write-Host "Azure connection error: $_" -ForegroundColor Red
    exit 1
}

# Get subscriptions
if ($SubscriptionId) {
    $subs = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
    Write-Host "Targeting subscription: $($subs.Name)" -ForegroundColor Cyan
} else {
    $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
    Write-Host "Scanning $($subs.Count) subscription(s)..." -ForegroundColor Cyan
}

$results = @()
$principalCache = @{}  # Cache principal lookups for speed

# Helper function to resolve principal with caching
function Resolve-Principal {
    param([string]$PrincipalId)

    if ($principalCache.ContainsKey($PrincipalId)) {
        return $principalCache[$PrincipalId]
    }

    $result = [PSCustomObject]@{
        ObjectId = $PrincipalId
        Type = "Unknown"
        DisplayName = ""
        UPN = ""
    }

    # Try Group
    try {
        $g = Get-AzADGroup -ObjectId $PrincipalId -ErrorAction Stop
        $result.Type = "Group"
        $result.DisplayName = $g.DisplayName
        $principalCache[$PrincipalId] = $result
        return $result
    } catch { }

    # Try User
    try {
        $u = Get-AzADUser -ObjectId $PrincipalId -ErrorAction Stop
        $result.Type = "User"
        $result.DisplayName = $u.DisplayName
        $result.UPN = $u.UserPrincipalName
        $principalCache[$PrincipalId] = $result
        return $result
    } catch { }

    # Try Service Principal
    try {
        $sp = Get-AzADServicePrincipal -ObjectId $PrincipalId -ErrorAction Stop
        $result.Type = "ServicePrincipal"
        $result.DisplayName = $sp.DisplayName
        $principalCache[$PrincipalId] = $result
        return $result
    } catch { }

    $principalCache[$PrincipalId] = $result
    return $result
}

$totalAppGroups = 0
$totalAssignments = 0

foreach ($sub in $subs) {
    Write-Host "`n>>> Subscription: $($sub.Name)" -ForegroundColor Cyan

    try {
        Set-AzContext -Subscription $sub.Id | Out-Null
    } catch {
        Write-Host "  [SKIP] Cannot access subscription" -ForegroundColor Yellow
        continue
    }

    # Get all Application Groups
    $appGroups = @()
    try {
        $appGroups = Get-AzWvdApplicationGroup -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  [SKIP] Cannot list app groups: $_" -ForegroundColor Yellow
        continue
    }

    if (-not $appGroups -or $appGroups.Count -eq 0) {
        Write-Host "  No application groups found" -ForegroundColor Gray
        continue
    }

    Write-Host "  Found $($appGroups.Count) application group(s)" -ForegroundColor Green
    $totalAppGroups += $appGroups.Count

    foreach ($ag in $appGroups) {
        Write-Host "    Processing: $($ag.Name)" -ForegroundColor Yellow

        # Get assignments via ARM REST API
        $assignPath = "/subscriptions/$($sub.Id)/resourceGroups/$($ag.ResourceGroupName)/providers/Microsoft.DesktopVirtualization/applicationGroups/$($ag.Name)/assignments?api-version=2024-04-03"

        try {
            $resp = Invoke-AzRestMethod -Path $assignPath -Method GET -ErrorAction Stop
            $assignments = ($resp.Content | ConvertFrom-Json).value
        } catch {
            Write-Host "      [WARN] Could not get assignments: $_" -ForegroundColor Yellow
            continue
        }

        if (-not $assignments -or $assignments.Count -eq 0) {
            # Record app group with no assignments
            $results += [PSCustomObject]@{
                SubscriptionName = $sub.Name
                SubscriptionId = $sub.Id
                ResourceGroup = $ag.ResourceGroupName
                ApplicationGroup = $ag.Name
                AppGroupType = $ag.ApplicationGroupType
                HostPoolPath = $ag.HostPoolArmPath
                PrincipalObjectId = ""
                PrincipalType = "NONE"
                PrincipalDisplayName = "[No assignments]"
                PrincipalUPN = ""
            }
            continue
        }

        foreach ($a in $assignments) {
            $principalId = $a.principalId
            if (-not $principalId) { continue }

            # Resolve principal
            $principal = Resolve-Principal -PrincipalId $principalId

            # Skip if GroupsOnly and not a group
            if ($GroupsOnly -and $principal.Type -ne "Group") {
                continue
            }

            $totalAssignments++

            $results += [PSCustomObject]@{
                SubscriptionName = $sub.Name
                SubscriptionId = $sub.Id
                ResourceGroup = $ag.ResourceGroupName
                ApplicationGroup = $ag.Name
                AppGroupType = $ag.ApplicationGroupType
                HostPoolPath = $ag.HostPoolArmPath
                PrincipalObjectId = $principalId
                PrincipalType = $principal.Type
                PrincipalDisplayName = $principal.DisplayName
                PrincipalUPN = $principal.UPN
            }
        }
    }
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Application Groups scanned: $totalAppGroups" -ForegroundColor White
Write-Host "Total assignments found: $totalAssignments" -ForegroundColor White

$groupAssignments = ($results | Where-Object { $_.PrincipalType -eq "Group" }).Count
$userAssignments = ($results | Where-Object { $_.PrincipalType -eq "User" }).Count
$spAssignments = ($results | Where-Object { $_.PrincipalType -eq "ServicePrincipal" }).Count
$noAssignments = ($results | Where-Object { $_.PrincipalType -eq "NONE" }).Count

Write-Host "  - Groups: $groupAssignments" -ForegroundColor Green
Write-Host "  - Users: $userAssignments" -ForegroundColor Cyan
Write-Host "  - Service Principals: $spAssignments" -ForegroundColor Gray
Write-Host "  - App Groups with no assignments: $noAssignments" -ForegroundColor Yellow

# Output table (groups only for readability)
if ($results.Count -gt 0) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  GROUP ASSIGNMENTS" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $groupResults = $results | Where-Object { $_.PrincipalType -eq "Group" }
    if ($groupResults.Count -gt 0) {
        $groupResults | Sort-Object ApplicationGroup, PrincipalDisplayName |
            Format-Table @{L='App Group';E={$_.ApplicationGroup}},
                         @{L='Type';E={$_.AppGroupType}},
                         @{L='Assigned Group';E={$_.PrincipalDisplayName}} -AutoSize
    } else {
        Write-Host "No group assignments found (all assignments are users/SPs)" -ForegroundColor Yellow
    }

    # Show unique groups
    $uniqueGroups = $results | Where-Object { $_.PrincipalType -eq "Group" } |
                    Select-Object -ExpandProperty PrincipalDisplayName -Unique |
                    Sort-Object

    if ($uniqueGroups.Count -gt 0) {
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "  UNIQUE AAD GROUPS ($($uniqueGroups.Count) total)" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        $uniqueGroups | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }
    }
}

# Export
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$csvPath = Join-Path $OutputPath "AvdAppGroupAssignments-$timestamp.csv"

$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  OUTPUT FILE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "CSV: $csvPath" -ForegroundColor White
Write-Host "`nIn Cloud Shell: Use the file browser (top-right) to download" -ForegroundColor Gray

Write-Host "`nDone.`n" -ForegroundColor Green
