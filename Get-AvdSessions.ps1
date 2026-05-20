<#
.SYNOPSIS
    AVD Sessions Snapshot - Current user load per host pool and session host.

.DESCRIPTION
    Shows real-time session counts, states, and user distribution across AVD infrastructure.
    Use this to understand current load patterns and identify over/under-utilization.

.PARAMETER SubscriptionId
    Optional. Target a specific subscription.

.PARAMETER HostPoolName
    Optional. Target a specific host pool.

.PARAMETER ShowUsers
    Optional. Include user principal names in output (may be sensitive).

.PARAMETER InstallMissingModules
    Optional. Install missing Az modules into the current user scope.

.EXAMPLE
    ./Get-AvdSessions.ps1 -SubscriptionId "xxx"

.EXAMPLE
    ./Get-AvdSessions.ps1 -HostPoolName "HP-Prod-Apps"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$HostPoolName,

    [Parameter(Mandatory = $false)]
    [switch]$ShowUsers,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "outputs",

    [Parameter(Mandatory = $false)]
    [switch]$InstallMissingModules
)

$ErrorActionPreference = "Continue"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AVD Sessions Snapshot" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "========================================`n" -ForegroundColor Cyan

# Ensure AVD module
if (-not (Get-Module -ListAvailable -Name Az.DesktopVirtualization)) {
    if (-not $InstallMissingModules) {
        Write-Host "Missing module: Az.DesktopVirtualization. Install it first or rerun with -InstallMissingModules." -ForegroundColor Red
        exit 1
    }
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
} catch {
    Write-Host "Azure connection error: $_" -ForegroundColor Red
    exit 1
}

# Get subscriptions
if ($SubscriptionId) {
    $subs = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
} else {
    $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

$hostRows = @()
$poolSummary = @()
$userSessions = @()

foreach ($sub in $subs) {
    Select-AzSubscription -SubscriptionId $sub.Id | Out-Null

    $hostPools = @()
    try {
        $hostPools = Get-AzWvdHostPool -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    } catch { continue }

    if ($HostPoolName) {
        $hostPools = $hostPools | Where-Object { $_.Name -eq $HostPoolName }
    }

    foreach ($hp in $hostPools) {
        $rgName = $hp.Id.Split("/")[4]

        Write-Host "Processing: $($hp.Name)" -ForegroundColor Yellow

        $sessionHosts = @()
        $allUserSessions = @()

        try {
            $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue
        } catch { }

        try {
            $allUserSessions = Get-AzWvdUserSession -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue
        } catch { }

        $poolTotalActive = 0
        $poolTotalDisconnected = 0
        $poolTotalPending = 0

        foreach ($sh in $sessionHosts) {
            $nameParts = $sh.Name.Split("/")
            $sessionHostFqdn = $nameParts[-1]
            $shortName = $sessionHostFqdn.Split(".")[0]

            # Find sessions for this host
            $sessionsForHost = $allUserSessions | Where-Object {
                $_.Name -like "*$sessionHostFqdn*" -or $_.Name -like "*$shortName*"
            }

            $active = ($sessionsForHost | Where-Object { $_.SessionState -eq "Active" }).Count
            $disconnected = ($sessionsForHost | Where-Object { $_.SessionState -eq "Disconnected" }).Count
            $pending = ($sessionsForHost | Where-Object { $_.SessionState -eq "Pending" }).Count
            $total = $sessionsForHost.Count

            $poolTotalActive += $active
            $poolTotalDisconnected += $disconnected
            $poolTotalPending += $pending

            # Calculate utilization
            $utilization = 0
            if ($hp.MaxSessionLimit -and $hp.MaxSessionLimit -gt 0) {
                $utilization = [math]::Round(($total / $hp.MaxSessionLimit) * 100, 1)
            }

            $hostRows += [PSCustomObject]@{
                SubscriptionName = $sub.Name
                ResourceGroup    = $rgName
                HostPoolName     = $hp.Name
                SessionHost      = $shortName
                Status           = $sh.Status
                AllowNewSession  = $sh.AllowNewSession
                ActiveSessions   = $active
                Disconnected     = $disconnected
                Pending          = $pending
                TotalSessions    = $total
                MaxSessions      = $hp.MaxSessionLimit
                Utilization      = "$utilization%"
                LastHeartbeat    = $sh.LastHeartBeat
                UpdateState      = $sh.UpdateState
            }

            # Collect user details if requested
            if ($ShowUsers) {
                foreach ($sess in $sessionsForHost) {
                    $userSessions += [PSCustomObject]@{
                        HostPool       = $hp.Name
                        SessionHost    = $shortName
                        UserPrincipal  = $sess.UserPrincipalName
                        SessionState   = $sess.SessionState
                        CreateTime     = $sess.CreateTime
                        ApplicationType = $sess.ApplicationType
                    }
                }
            }
        }

        # Pool summary
        $availableHosts = ($sessionHosts | Where-Object { $_.Status -eq "Available" }).Count
        $totalHosts = $sessionHosts.Count
        $avgSessionsPerHost = if ($availableHosts -gt 0) { [math]::Round(($poolTotalActive + $poolTotalDisconnected) / $availableHosts, 1) } else { 0 }

        $poolSummary += [PSCustomObject]@{
            HostPoolName        = $hp.Name
            HostPoolType        = $hp.HostPoolType
            LoadBalancer        = $hp.LoadBalancerType
            MaxSessionLimit     = $hp.MaxSessionLimit
            TotalHosts          = $totalHosts
            AvailableHosts      = $availableHosts
            ActiveSessions      = $poolTotalActive
            DisconnectedSessions = $poolTotalDisconnected
            TotalSessions       = $poolTotalActive + $poolTotalDisconnected + $poolTotalPending
            AvgSessionsPerHost  = $avgSessionsPerHost
            CapacityUsed        = if ($availableHosts -gt 0 -and $hp.MaxSessionLimit -gt 0) {
                "$([math]::Round((($poolTotalActive + $poolTotalDisconnected) / ($availableHosts * $hp.MaxSessionLimit)) * 100, 1))%"
            } else { "N/A" }
        }
    }
}

# Output pool summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  HOST POOL SUMMARY" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$poolSummary | Format-Table @{L='Host Pool';E={$_.HostPoolName}},
                            @{L='Type';E={$_.HostPoolType}},
                            @{L='Hosts';E={"$($_.AvailableHosts)/$($_.TotalHosts)"}},
                            @{L='Active';E={$_.ActiveSessions}},
                            @{L='Disconn';E={$_.DisconnectedSessions}},
                            @{L='Total';E={$_.TotalSessions}},
                            @{L='Avg/Host';E={$_.AvgSessionsPerHost}},
                            @{L='Capacity';E={$_.CapacityUsed}} -AutoSize

# Output per-host details
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SESSION HOST DETAILS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$hostRows | Sort-Object HostPoolName, SessionHost |
    Format-Table @{L='Host Pool';E={$_.HostPoolName}},
                 @{L='Session Host';E={$_.SessionHost}},
                 @{L='Status';E={$_.Status}},
                 @{L='Allow';E={if($_.AllowNewSession){"Yes"}else{"NO"}}},
                 @{L='Active';E={$_.ActiveSessions}},
                 @{L='Disc';E={$_.Disconnected}},
                 @{L='Total';E={$_.TotalSessions}},
                 @{L='Max';E={$_.MaxSessions}},
                 @{L='Util';E={$_.Utilization}} -AutoSize

# Highlight issues
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OBSERVATIONS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$idleHosts = $hostRows | Where-Object { $_.Status -eq "Available" -and $_.TotalSessions -eq 0 }
if ($idleHosts.Count -gt 0) {
    Write-Host "[INFO] Idle hosts (Available but 0 sessions): $($idleHosts.Count)" -ForegroundColor Yellow
    $idleHosts | ForEach-Object { Write-Host "  - $($_.SessionHost) in $($_.HostPoolName)" }
}

$overloadedHosts = $hostRows | Where-Object {
    $_.MaxSessions -gt 0 -and $_.TotalSessions -ge ($_.MaxSessions * 0.8)
}
if ($overloadedHosts.Count -gt 0) {
    Write-Host "`n[WARN] Heavily loaded hosts (>80% capacity):" -ForegroundColor Red
    $overloadedHosts | ForEach-Object { Write-Host "  - $($_.SessionHost): $($_.TotalSessions)/$($_.MaxSessions) sessions" }
}

$blockedHosts = $hostRows | Where-Object { $_.Status -eq "Available" -and -not $_.AllowNewSession }
if ($blockedHosts.Count -gt 0) {
    Write-Host "`n[WARN] Hosts blocking new sessions:" -ForegroundColor Yellow
    $blockedHosts | ForEach-Object { Write-Host "  - $($_.SessionHost) in $($_.HostPoolName)" }
}

$shutdownHosts = $hostRows | Where-Object { $_.Status -eq "Shutdown" }
if ($shutdownHosts.Count -gt 0) {
    Write-Host "`n[INFO] Shutdown hosts: $($shutdownHosts.Count)" -ForegroundColor Gray
}

$unavailableHosts = $hostRows | Where-Object { $_.Status -eq "Unavailable" }
if ($unavailableHosts.Count -gt 0) {
    Write-Host "`n[ALERT] Unavailable hosts: $($unavailableHosts.Count)" -ForegroundColor Red
    $unavailableHosts | ForEach-Object { Write-Host "  - $($_.SessionHost) in $($_.HostPoolName)" }
}

# High disconnected session counts
$highDisconnected = $poolSummary | Where-Object { $_.DisconnectedSessions -gt 10 }
if ($highDisconnected.Count -gt 0) {
    Write-Host "`n[INFO] Pools with many disconnected sessions (consider session limits/timeouts):" -ForegroundColor Yellow
    $highDisconnected | ForEach-Object { Write-Host "  - $($_.HostPoolName): $($_.DisconnectedSessions) disconnected" }
}

# Export
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$hostRows | Export-Csv -Path (Join-Path $OutputPath "AvdSessions-$timestamp.csv") -NoTypeInformation -Encoding UTF8
$poolSummary | Export-Csv -Path (Join-Path $OutputPath "AvdPoolSummary-$timestamp.csv") -NoTypeInformation -Encoding UTF8

if ($ShowUsers -and $userSessions.Count -gt 0) {
    $userSessions | Export-Csv -Path (Join-Path $OutputPath "AvdUserSessions-$timestamp.csv") -NoTypeInformation -Encoding UTF8
    Write-Host "`nUser sessions exported to: AvdUserSessions-$timestamp.csv" -ForegroundColor Gray
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  OUTPUT FILES" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Sessions: AvdSessions-$timestamp.csv" -ForegroundColor White
Write-Host "Pool Summary: AvdPoolSummary-$timestamp.csv" -ForegroundColor White

Write-Host "`nSnapshot complete.`n" -ForegroundColor Green
