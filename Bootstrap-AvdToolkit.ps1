# AVD Audit Toolkit - Bootstrap Script
# Run this in Azure Cloud Shell to create all the scripts locally
# Or save to your own GitHub repo

Write-Host "Creating AVD Audit Toolkit files..." -ForegroundColor Cyan

# Create directory
$dir = "$HOME/avd-audit-toolkit"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Set-Location $dir

#region Get-AvdInventory.ps1
@'
<#
.SYNOPSIS
    AVD Environment Inventory - Maps host pools, app groups, workspaces, session hosts, scaling plans.
.PARAMETER SubscriptionId
    Optional. Target a specific subscription.
.EXAMPLE
    ./Get-AvdInventory.ps1 -SubscriptionId "xxx"
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$OutputPath = "outputs"
)

$ErrorActionPreference = "Continue"

Write-Host "`n========================================"  -ForegroundColor Cyan
Write-Host "  AVD Environment Inventory Scanner"       -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name Az.DesktopVirtualization)) {
    Install-Module Az.DesktopVirtualization -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.DesktopVirtualization -ErrorAction SilentlyContinue

$context = Get-AzContext
if (-not $context) { Write-Host "Run Connect-AzAccount first." -ForegroundColor Red; exit 1 }
Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green

if ($SubscriptionId) {
    $subs = Get-AzSubscription -SubscriptionId $SubscriptionId
} else {
    $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

Write-Host "Scanning $($subs.Count) subscription(s)...`n" -ForegroundColor Cyan

$results = @()

foreach ($sub in $subs) {
    Write-Host ">>> Subscription: $($sub.Name)" -ForegroundColor Cyan
    try { Select-AzSubscription -SubscriptionId $sub.Id | Out-Null } catch { continue }

    $hostPools = Get-AzWvdHostPool -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    $workspaces = Get-AzWvdWorkspace -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    $scalingPlans = Get-AzWvdScalingPlan -SubscriptionId $sub.Id -ErrorAction SilentlyContinue

    if (-not $hostPools) { Write-Host "  No host pools found" -ForegroundColor Gray; continue }

    foreach ($hp in $hostPools) {
        Write-Host "  Processing: $($hp.Name)" -ForegroundColor Yellow
        $rgName = $hp.Id.Split("/")[4]

        $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue
        $appGroups = Get-AzWvdApplicationGroup -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Where-Object { $_.HostPoolArmPath -eq $hp.Id }

        $plansForPool = $scalingPlans | Where-Object { $_.HostPoolReference.HostPoolArmPath -contains $hp.Id }
        $diag = Get-AzDiagnosticSetting -ResourceId $hp.Id -ErrorAction SilentlyContinue

        $availableHosts = ($sessionHosts | Where-Object { $_.Status -eq "Available" }).Count

        $results += [PSCustomObject]@{
            SubscriptionName   = $sub.Name
            ResourceGroup      = $rgName
            HostPoolName       = $hp.Name
            HostPoolType       = $hp.HostPoolType
            LoadBalancerType   = $hp.LoadBalancerType
            MaxSessionLimit    = $hp.MaxSessionLimit
            Location           = $hp.Location
            StartVMOnConnect   = $hp.StartVMOnConnect
            TotalSessionHosts  = $sessionHosts.Count
            AvailableHosts     = $availableHosts
            AppGroupCount      = $appGroups.Count
            ScalingPlanCount   = $plansForPool.Count
            ScalingPlans       = ($plansForPool.Name -join ",")
            DiagnosticsEnabled = [bool]$diag
        }
    }
}

Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
$results | Format-Table HostPoolName, HostPoolType, LoadBalancerType, @{L='Hosts';E={"$($_.AvailableHosts)/$($_.TotalSessionHosts)"}}, @{L='Scaling';E={if($_.ScalingPlanCount -gt 0){"Yes"}else{"NO"}}}, @{L='Diag';E={if($_.DiagnosticsEnabled){"Yes"}else{"NO"}}} -AutoSize

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$results | Export-Csv "$OutputPath/AvdInventory-$timestamp.csv" -NoTypeInformation
$results | ConvertTo-Json -Depth 5 | Out-File "$OutputPath/AvdInventory-$timestamp.json"
Write-Host "`nExported: AvdInventory-$timestamp.csv" -ForegroundColor Green
'@ | Set-Content "$dir/Get-AvdInventory.ps1"
#endregion

#region Get-AvdSessions.ps1
@'
<#
.SYNOPSIS
    AVD Sessions Snapshot - Current user load per host pool and session host.
.PARAMETER SubscriptionId
    Optional. Target a specific subscription.
#>
[CmdletBinding()]
param([string]$SubscriptionId, [string]$OutputPath = "outputs")

$ErrorActionPreference = "Continue"
Write-Host "`n=== AVD Sessions Snapshot ===" -ForegroundColor Cyan
Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor Gray

if (-not (Get-Module -ListAvailable -Name Az.DesktopVirtualization)) {
    Install-Module Az.DesktopVirtualization -Scope CurrentUser -Force
}
Import-Module Az.DesktopVirtualization -ErrorAction SilentlyContinue

if ($SubscriptionId) { $subs = Get-AzSubscription -SubscriptionId $SubscriptionId }
else { $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } }

$hostRows = @(); $poolSummary = @()

foreach ($sub in $subs) {
    Select-AzSubscription -SubscriptionId $sub.Id | Out-Null
    $hostPools = Get-AzWvdHostPool -SubscriptionId $sub.Id -ErrorAction SilentlyContinue

    foreach ($hp in $hostPools) {
        $rgName = $hp.Id.Split("/")[4]
        $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue
        $userSessions = Get-AzWvdUserSession -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue

        $poolActive = 0; $poolDisc = 0

        foreach ($sh in $sessionHosts) {
            $shName = $sh.Name.Split("/")[-1].Split(".")[0]
            $sessForHost = $userSessions | Where-Object { $_.Name -like "*$shName*" }
            $active = ($sessForHost | Where-Object { $_.SessionState -eq "Active" }).Count
            $disc = ($sessForHost | Where-Object { $_.SessionState -eq "Disconnected" }).Count
            $poolActive += $active; $poolDisc += $disc

            $hostRows += [PSCustomObject]@{
                HostPool = $hp.Name; SessionHost = $shName; Status = $sh.Status
                AllowNew = $sh.AllowNewSession; Active = $active; Disconnected = $disc
                Total = $sessForHost.Count; Max = $hp.MaxSessionLimit
            }
        }

        $avail = ($sessionHosts | Where-Object { $_.Status -eq "Available" }).Count
        $poolSummary += [PSCustomObject]@{
            HostPool = $hp.Name; Type = $hp.HostPoolType; Hosts = "$avail/$($sessionHosts.Count)"
            Active = $poolActive; Disconnected = $poolDisc; Total = $poolActive + $poolDisc
        }
    }
}

Write-Host "=== POOL SUMMARY ===" -ForegroundColor Cyan
$poolSummary | Format-Table -AutoSize

Write-Host "=== SESSION HOST DETAILS ===" -ForegroundColor Cyan
$hostRows | Format-Table HostPool, SessionHost, Status, Active, Disconnected, Total, Max -AutoSize

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$hostRows | Export-Csv "$OutputPath/AvdSessions-$timestamp.csv" -NoTypeInformation
Write-Host "`nExported: AvdSessions-$timestamp.csv" -ForegroundColor Green
'@ | Set-Content "$dir/Get-AvdSessions.ps1"
#endregion

#region Get-AvdAutoscaleReadiness.ps1
@'
<#
.SYNOPSIS
    AVD Autoscale Readiness Assessment
#>
[CmdletBinding()]
param([string]$SubscriptionId, [string]$OutputPath = "outputs")

$ErrorActionPreference = "Continue"
Write-Host "`n=== AVD Autoscale Readiness ===" -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name Az.DesktopVirtualization)) {
    Install-Module Az.DesktopVirtualization -Scope CurrentUser -Force
}
Import-Module Az.DesktopVirtualization -ErrorAction SilentlyContinue

if ($SubscriptionId) { $subs = Get-AzSubscription -SubscriptionId $SubscriptionId }
else { $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } }

$results = @()

foreach ($sub in $subs) {
    Select-AzSubscription -SubscriptionId $sub.Id | Out-Null
    $hostPools = Get-AzWvdHostPool -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    $scalingPlans = Get-AzWvdScalingPlan -SubscriptionId $sub.Id -ErrorAction SilentlyContinue

    foreach ($hp in $hostPools) {
        $rgName = $hp.Id.Split("/")[4]
        $issues = @(); $ready = @()

        if ($hp.HostPoolType -eq "Pooled") { $ready += "Pooled type" } else { $issues += "Personal - no scaling plans" }
        if ($hp.LoadBalancerType -eq "DepthFirst") { $ready += "DepthFirst LB" } else { $issues += "Not DepthFirst" }
        if ($hp.MaxSessionLimit -gt 0) { $ready += "MaxSession: $($hp.MaxSessionLimit)" } else { $issues += "No max session limit" }
        if ($hp.StartVMOnConnect) { $ready += "StartVMOnConnect" } else { $issues += "No StartVMOnConnect" }

        $plan = $scalingPlans | Where-Object { $_.HostPoolReference.HostPoolArmPath -contains $hp.Id }
        if ($plan) { $ready += "Has scaling plan" } else { $issues += "No scaling plan" }

        $diag = Get-AzDiagnosticSetting -ResourceId $hp.Id -ErrorAction SilentlyContinue
        if ($diag) { $ready += "Diagnostics enabled" } else { $issues += "No diagnostics" }

        $score = [math]::Round(($ready.Count / ($ready.Count + $issues.Count)) * 100)

        $results += [PSCustomObject]@{
            HostPool = $hp.Name; Type = $hp.HostPoolType; LoadBalancer = $hp.LoadBalancerType
            HasScaling = [bool]$plan; StartVM = $hp.StartVMOnConnect; Diag = [bool]$diag
            Score = "$score%"; Issues = ($issues -join "; ")
        }
    }
}

Write-Host "`n=== ASSESSMENT ===" -ForegroundColor Cyan
$results | Format-Table HostPool, Type, LoadBalancer, @{L='Scaling';E={if($_.HasScaling){"Yes"}else{"NO"}}}, @{L='StartVM';E={if($_.StartVM){"Yes"}else{"No"}}}, Score -AutoSize

Write-Host "`n=== QUICK WINS ===" -ForegroundColor Yellow
$noScale = $results | Where-Object { -not $_.HasScaling -and $_.Type -eq "Pooled" }
if ($noScale) { Write-Host "Add scaling plans to: $($noScale.HostPool -join ', ')" }
$noStart = $results | Where-Object { -not $_.StartVM -and $_.Type -eq "Pooled" }
if ($noStart) { Write-Host "Enable StartVMOnConnect: $($noStart.HostPool -join ', ')" }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$results | Export-Csv "$OutputPath/AvdAutoscaleAssessment-$timestamp.csv" -NoTypeInformation
Write-Host "`nExported: AvdAutoscaleAssessment-$timestamp.csv" -ForegroundColor Green
'@ | Set-Content "$dir/Get-AvdAutoscaleReadiness.ps1"
#endregion

#region Get-AvdAppGroupAssignments.ps1
@'
<#
.SYNOPSIS
    Get all AVD Application Group assignments (groups AND users)
.PARAMETER GroupsOnly
    Only output group assignments
#>
[CmdletBinding()]
param([string]$SubscriptionId, [switch]$GroupsOnly, [string]$OutputPath = "outputs")

$ErrorActionPreference = "Continue"
Write-Host "`n=== AVD App Group Assignments ===" -ForegroundColor Cyan

Import-Module Az.DesktopVirtualization, Az.Resources -ErrorAction SilentlyContinue

if ($SubscriptionId) { $subs = Get-AzSubscription -SubscriptionId $SubscriptionId }
else { $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } }

$results = @(); $cache = @{}

function Resolve-Principal($id) {
    if ($cache[$id]) { return $cache[$id] }
    $r = @{Id=$id; Type="Unknown"; Name=$id}
    try { $g = Get-AzADGroup -ObjectId $id -EA Stop; $r.Type="Group"; $r.Name=$g.DisplayName }
    catch { try { $u = Get-AzADUser -ObjectId $id -EA Stop; $r.Type="User"; $r.Name=$u.DisplayName } catch {} }
    $cache[$id] = $r; return $r
}

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null
    $appGroups = Get-AzWvdApplicationGroup -ErrorAction SilentlyContinue

    foreach ($ag in $appGroups) {
        Write-Host "  $($ag.Name)" -ForegroundColor Yellow
        $path = "/subscriptions/$($sub.Id)/resourceGroups/$($ag.ResourceGroupName)/providers/Microsoft.DesktopVirtualization/applicationGroups/$($ag.Name)/assignments?api-version=2024-04-03"
        $resp = Invoke-AzRestMethod -Path $path -Method GET -EA SilentlyContinue
        $assignments = ($resp.Content | ConvertFrom-Json).value

        if (-not $assignments) {
            $results += [PSCustomObject]@{AppGroup=$ag.Name; Type=$ag.ApplicationGroupType; PrincipalType="NONE"; Principal="[No assignments]"}
            continue
        }

        foreach ($a in $assignments) {
            $p = Resolve-Principal $a.principalId
            if ($GroupsOnly -and $p.Type -ne "Group") { continue }
            $results += [PSCustomObject]@{AppGroup=$ag.Name; Type=$ag.ApplicationGroupType; PrincipalType=$p.Type; Principal=$p.Name; ObjectId=$a.principalId}
        }
    }
}

Write-Host "`n=== GROUP ASSIGNMENTS ===" -ForegroundColor Cyan
$results | Where-Object { $_.PrincipalType -eq "Group" } | Format-Table AppGroup, Principal -AutoSize

Write-Host "`n=== UNIQUE GROUPS ===" -ForegroundColor Cyan
$results | Where-Object { $_.PrincipalType -eq "Group" } | Select-Object -ExpandProperty Principal -Unique | Sort-Object | ForEach-Object { Write-Host "  - $_" }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$results | Export-Csv "$OutputPath/AvdAppGroupAssignments-$timestamp.csv" -NoTypeInformation
Write-Host "`nExported: AvdAppGroupAssignments-$timestamp.csv" -ForegroundColor Green
'@ | Set-Content "$dir/Get-AvdAppGroupAssignments.ps1"
#endregion

#region Get-AvdAppToGroupMapping.ps1
@'
<#
.SYNOPSIS
    Maps published AVD applications to their assigned AAD groups
#>
[CmdletBinding()]
param([string]$SubscriptionId, [switch]$ExportForNewGroups, [string]$OutputPath = "outputs")

$ErrorActionPreference = "Continue"
Write-Host "`n=== AVD Application -> Group Mapping ===" -ForegroundColor Cyan

Import-Module Az.DesktopVirtualization, Az.Resources -ErrorAction SilentlyContinue

if ($SubscriptionId) { $subs = Get-AzSubscription -SubscriptionId $SubscriptionId }
else { $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } }

$mapping = @(); $cache = @{}

function Get-PrincipalName($id) {
    if ($cache[$id]) { return $cache[$id] }
    try { $g = Get-AzADGroup -ObjectId $id -EA Stop; $cache[$id] = $g.DisplayName; return $g.DisplayName }
    catch { $cache[$id] = $null; return $null }
}

foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null
    $appGroups = Get-AzWvdApplicationGroup -EA SilentlyContinue

    foreach ($ag in $appGroups) {
        Write-Host "  $($ag.Name)" -ForegroundColor Yellow

        # Get assignments
        $path = "/subscriptions/$($sub.Id)/resourceGroups/$($ag.ResourceGroupName)/providers/Microsoft.DesktopVirtualization/applicationGroups/$($ag.Name)/assignments?api-version=2024-04-03"
        $resp = Invoke-AzRestMethod -Path $path -Method GET -EA SilentlyContinue
        $assignments = ($resp.Content | ConvertFrom-Json).value

        $groups = @()
        foreach ($a in $assignments) {
            $name = Get-PrincipalName $a.principalId
            if ($name) { $groups += $name }
        }
        $groupStr = if ($groups) { $groups -join "; " } else { "[None]" }

        if ($ag.ApplicationGroupType -eq "RemoteApp") {
            $apps = Get-AzWvdApplication -ResourceGroupName $ag.ResourceGroupName -ApplicationGroupName $ag.Name -EA SilentlyContinue
            foreach ($app in $apps) {
                $mapping += [PSCustomObject]@{Application=$app.FriendlyName; AppGroup=$ag.Name; AssignedGroups=$groupStr}
            }
            if (-not $apps) {
                $mapping += [PSCustomObject]@{Application="[No apps]"; AppGroup=$ag.Name; AssignedGroups=$groupStr}
            }
        } else {
            $mapping += [PSCustomObject]@{Application="[Full Desktop]"; AppGroup=$ag.Name; AssignedGroups=$groupStr}
        }
    }
}

Write-Host "`n=== APPLICATION -> GROUP MAPPING ===" -ForegroundColor Cyan
$mapping | Format-Table Application, AppGroup, AssignedGroups -AutoSize

Write-Host "`n=== ALL UNIQUE AAD GROUPS ===" -ForegroundColor Cyan
$allGroups = ($mapping | Where-Object { $_.AssignedGroups -ne "[None]" } | ForEach-Object { $_.AssignedGroups -split "; " }) | Sort-Object -Unique
$allGroups | ForEach-Object { Write-Host "  - $_" }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$mapping | Export-Csv "$OutputPath/AvdAppToGroupMapping-$timestamp.csv" -NoTypeInformation
Write-Host "`nExported: AvdAppToGroupMapping-$timestamp.csv" -ForegroundColor Green
'@ | Set-Content "$dir/Get-AvdAppToGroupMapping.ps1"
#endregion

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Toolkit created in: $dir" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host @"

Scripts:
  - Get-AvdInventory.ps1          Full environment audit
  - Get-AvdSessions.ps1           Current sessions/load
  - Get-AvdAutoscaleReadiness.ps1 Scaling assessment
  - Get-AvdAppGroupAssignments.ps1 App group assignments
  - Get-AvdAppToGroupMapping.ps1  App -> AAD group mapping

Run any script:
  cd $dir
  ./Get-AvdInventory.ps1

"@ -ForegroundColor White
