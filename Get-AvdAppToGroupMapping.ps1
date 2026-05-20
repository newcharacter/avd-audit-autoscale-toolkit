<#
.SYNOPSIS
    Maps published AVD applications to their assigned AAD groups.

.DESCRIPTION
    Shows which AAD groups can access each individual published application (RemoteApp).

    In AVD, assignments are made at the Application Group level, not per-app.
    This script resolves that relationship so you can see:

    Application Name → App Group → Assigned AAD Groups

    Useful for:
    - Access reviews ("who can access Excel?")
    - Creating new on-prem groups to mirror AVD access
    - Auditing application permissions

.PARAMETER SubscriptionId
    Optional. Target specific subscription.

.PARAMETER ExportForNewGroups
    Optional. Outputs a simplified format suitable for creating new AD groups.

.EXAMPLE
    ./Get-AvdAppToGroupMapping.ps1

.EXAMPLE
    ./Get-AvdAppToGroupMapping.ps1 -ExportForNewGroups
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [switch]$ExportForNewGroups,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "outputs"
)

$ErrorActionPreference = "Continue"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AVD Application → Group Mapping" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Ensure modules
$requiredModules = @("Az.Accounts", "Az.DesktopVirtualization", "Az.Resources")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}

# Verify connection
$context = Get-AzContext
if (-not $context) {
    Write-Host "Not logged in. Run Connect-AzAccount first." -ForegroundColor Red
    exit 1
}

Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green

# Get subscriptions
if ($SubscriptionId) {
    $subs = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
} else {
    $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

$appMapping = @()
$principalCache = @{}

function Resolve-Principal {
    param([string]$PrincipalId)

    if ($principalCache.ContainsKey($PrincipalId)) {
        return $principalCache[$PrincipalId]
    }

    $result = [PSCustomObject]@{
        ObjectId = $PrincipalId
        Type = "Unknown"
        DisplayName = $PrincipalId
    }

    try {
        $g = Get-AzADGroup -ObjectId $PrincipalId -ErrorAction Stop
        $result.Type = "Group"
        $result.DisplayName = $g.DisplayName
    } catch {
        try {
            $u = Get-AzADUser -ObjectId $PrincipalId -ErrorAction Stop
            $result.Type = "User"
            $result.DisplayName = "$($u.DisplayName) ($($u.UserPrincipalName))"
        } catch {
            try {
                $sp = Get-AzADServicePrincipal -ObjectId $PrincipalId -ErrorAction Stop
                $result.Type = "ServicePrincipal"
                $result.DisplayName = $sp.DisplayName
            } catch { }
        }
    }

    $principalCache[$PrincipalId] = $result
    return $result
}

foreach ($sub in $subs) {
    Write-Host "`n>>> Subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -Subscription $sub.Id | Out-Null

    $appGroups = Get-AzWvdApplicationGroup -ErrorAction SilentlyContinue
    if (-not $appGroups) { continue }

    foreach ($ag in $appGroups) {
        Write-Host "  App Group: $($ag.Name) [$($ag.ApplicationGroupType)]" -ForegroundColor Yellow

        # Get assignments for this app group
        $assignPath = "/subscriptions/$($sub.Id)/resourceGroups/$($ag.ResourceGroupName)/providers/Microsoft.DesktopVirtualization/applicationGroups/$($ag.Name)/assignments?api-version=2024-04-03"
        $resp = Invoke-AzRestMethod -Path $assignPath -Method GET -ErrorAction SilentlyContinue
        $assignments = @()
        if ($resp -and $resp.Content) {
            $assignments = ($resp.Content | ConvertFrom-Json).value
        }

        # Resolve assignments to names (groups only for this report)
        $assignedGroups = @()
        $assignedUsers = @()
        foreach ($a in $assignments) {
            if (-not $a.principalId) { continue }
            $principal = Resolve-Principal -PrincipalId $a.principalId
            if ($principal.Type -eq "Group") {
                $assignedGroups += $principal.DisplayName
            } elseif ($principal.Type -eq "User") {
                $assignedUsers += $principal.DisplayName
            }
        }

        $groupsString = if ($assignedGroups.Count -gt 0) { $assignedGroups -join "; " } else { "[No groups assigned]" }
        $usersString = if ($assignedUsers.Count -gt 0) { $assignedUsers -join "; " } else { "" }

        # Get applications in this app group
        if ($ag.ApplicationGroupType -eq "RemoteApp") {
            # RemoteApp - list individual applications
            $apps = Get-AzWvdApplication -ResourceGroupName $ag.ResourceGroupName -ApplicationGroupName $ag.Name -ErrorAction SilentlyContinue

            if ($apps -and $apps.Count -gt 0) {
                foreach ($app in $apps) {
                    Write-Host "    App: $($app.FriendlyName)" -ForegroundColor Gray

                    $appMapping += [PSCustomObject]@{
                        SubscriptionName = $sub.Name
                        ResourceGroup = $ag.ResourceGroupName
                        ApplicationGroupName = $ag.Name
                        ApplicationGroupType = $ag.ApplicationGroupType
                        ApplicationName = $app.Name
                        ApplicationFriendlyName = $app.FriendlyName
                        ApplicationPath = $app.FilePath
                        AssignedAADGroups = $groupsString
                        AssignedUsers = $usersString
                        TotalGroupCount = $assignedGroups.Count
                        TotalUserCount = $assignedUsers.Count
                    }
                }
            } else {
                # RemoteApp group with no apps published
                $appMapping += [PSCustomObject]@{
                    SubscriptionName = $sub.Name
                    ResourceGroup = $ag.ResourceGroupName
                    ApplicationGroupName = $ag.Name
                    ApplicationGroupType = $ag.ApplicationGroupType
                    ApplicationName = "[No applications published]"
                    ApplicationFriendlyName = "[Empty App Group]"
                    ApplicationPath = ""
                    AssignedAADGroups = $groupsString
                    AssignedUsers = $usersString
                    TotalGroupCount = $assignedGroups.Count
                    TotalUserCount = $assignedUsers.Count
                }
            }
        } else {
            # Desktop app group - the "application" is the full desktop
            $appMapping += [PSCustomObject]@{
                SubscriptionName = $sub.Name
                ResourceGroup = $ag.ResourceGroupName
                ApplicationGroupName = $ag.Name
                ApplicationGroupType = $ag.ApplicationGroupType
                ApplicationName = "SessionDesktop"
                ApplicationFriendlyName = "[Full Desktop]"
                ApplicationPath = ""
                AssignedAADGroups = $groupsString
                AssignedUsers = $usersString
                TotalGroupCount = $assignedGroups.Count
                TotalUserCount = $assignedUsers.Count
            }
        }
    }
}

# Output results
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  APPLICATION → GROUP MAPPING" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Group by application for readability
$appMapping | Sort-Object ApplicationFriendlyName, ApplicationGroupName |
    Format-Table @{L='Application';E={$_.ApplicationFriendlyName}},
                 @{L='App Group';E={$_.ApplicationGroupName}},
                 @{L='Assigned AAD Groups';E={
                     if ($_.AssignedAADGroups.Length -gt 50) {
                         $_.AssignedAADGroups.Substring(0,47) + "..."
                     } else {
                         $_.AssignedAADGroups
                     }
                 }},
                 @{L='#Grps';E={$_.TotalGroupCount}},
                 @{L='#Users';E={$_.TotalUserCount}} -AutoSize

# Summary: unique applications and their groups
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SUMMARY BY APPLICATION" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$uniqueApps = $appMapping | Where-Object { $_.ApplicationFriendlyName -ne "[Empty App Group]" -and $_.ApplicationFriendlyName -ne "[Full Desktop]" } |
              Group-Object ApplicationFriendlyName

foreach ($appGroup in ($uniqueApps | Sort-Object Name)) {
    Write-Host "$($appGroup.Name)" -ForegroundColor Yellow
    $groups = ($appGroup.Group | Select-Object -ExpandProperty AssignedAADGroups -Unique) -join "; "
    Write-Host "  Groups: $groups" -ForegroundColor White
    Write-Host ""
}

# Unique AAD groups across all apps
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ALL UNIQUE AAD GROUPS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$allGroups = @()
foreach ($row in $appMapping) {
    if ($row.AssignedAADGroups -and $row.AssignedAADGroups -ne "[No groups assigned]") {
        $allGroups += $row.AssignedAADGroups -split "; "
    }
}
$uniqueGroups = $allGroups | Sort-Object -Unique

Write-Host "Found $($uniqueGroups.Count) unique AAD groups assigned to AVD apps:`n" -ForegroundColor White
$uniqueGroups | ForEach-Object { Write-Host "  - $_" }

# Export
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# Main CSV
$csvPath = Join-Path $OutputPath "AvdAppToGroupMapping-$timestamp.csv"
$appMapping | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# Simplified export for creating new groups
if ($ExportForNewGroups) {
    $newGroupsPath = Join-Path $OutputPath "AvdGroupsForAD-$timestamp.csv"

    $forAD = $appMapping | Where-Object { $_.AssignedAADGroups -ne "[No groups assigned]" } |
             Select-Object ApplicationFriendlyName, ApplicationGroupName, AssignedAADGroups |
             Sort-Object ApplicationFriendlyName

    $forAD | Export-Csv -Path $newGroupsPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nSimplified export for AD: $newGroupsPath" -ForegroundColor Green
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  OUTPUT" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Full mapping: $csvPath" -ForegroundColor White

Write-Host "`nDone.`n" -ForegroundColor Green
