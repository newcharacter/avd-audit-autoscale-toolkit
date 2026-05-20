<#
.SYNOPSIS
    AVD Autoscale Readiness Assessment - Evaluates current setup and generates recommendations.

.DESCRIPTION
    Analyzes your AVD environment and provides:
    - Current scaling configuration status
    - Autoscale readiness checklist
    - Recommended scaling plan configurations
    - Sample scaling plan deployment commands

.PARAMETER SubscriptionId
    Optional. Target a specific subscription.

.PARAMETER InstallMissingModules
    Optional. Install missing Az modules into the current user scope.

.EXAMPLE
    ./Get-AvdAutoscaleReadiness.ps1 -SubscriptionId "xxx"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "outputs",

    [Parameter(Mandatory = $false)]
    [switch]$InstallMissingModules
)

$ErrorActionPreference = "Continue"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AVD Autoscale Readiness Assessment" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Ensure modules
if (-not (Get-Module -ListAvailable -Name Az.DesktopVirtualization)) {
    if (-not $InstallMissingModules) {
        Write-Host "Missing module: Az.DesktopVirtualization. Install it first or rerun with -InstallMissingModules." -ForegroundColor Red
        exit 1
    }
    Write-Host "Installing Az.DesktopVirtualization module..." -ForegroundColor Yellow
    Install-Module Az.DesktopVirtualization -Scope CurrentUser -Force -AllowClobber
}

Import-Module Az.DesktopVirtualization -ErrorAction SilentlyContinue

# Verify connection
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Not logged in. Run Connect-AzAccount first." -ForegroundColor Red
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

$assessmentResults = @()
$recommendations = @()

foreach ($sub in $subs) {
    Write-Host ">>> Subscription: $($sub.Name)" -ForegroundColor Cyan
    Select-AzSubscription -SubscriptionId $sub.Id | Out-Null

    $hostPools = @()
    $scalingPlans = @()

    try { $hostPools = Get-AzWvdHostPool -SubscriptionId $sub.Id -ErrorAction SilentlyContinue } catch { }
    try { $scalingPlans = Get-AzWvdScalingPlan -SubscriptionId $sub.Id -ErrorAction SilentlyContinue } catch { }

    foreach ($hp in $hostPools) {
        Write-Host "  Assessing: $($hp.Name)" -ForegroundColor Yellow

        $rgName = $hp.Id.Split("/")[4]
        $issues = @()
        $readyItems = @()

        # Check 1: Is it a pooled host pool? (Personal doesn't support scaling plans)
        $isPooled = $hp.HostPoolType -eq "Pooled"
        if ($isPooled) {
            $readyItems += "Pooled host pool type (required for scaling plans)"
        } else {
            $issues += "Personal host pool - native scaling plans only work with Pooled type"
        }

        # Check 2: Load balancer type
        if ($hp.LoadBalancerType -eq "DepthFirst") {
            $readyItems += "DepthFirst load balancing (optimal for autoscale cost savings)"
        } else {
            $issues += "Using $($hp.LoadBalancerType) - consider DepthFirst for better autoscale efficiency"
        }

        # Check 3: Max session limit configured
        if ($hp.MaxSessionLimit -and $hp.MaxSessionLimit -gt 0) {
            $readyItems += "Max session limit set: $($hp.MaxSessionLimit)"
            if ($hp.MaxSessionLimit -gt 20) {
                $issues += "High max session limit ($($hp.MaxSessionLimit)) - verify VM size supports this"
            }
        } else {
            $issues += "No max session limit configured - required for autoscale"
        }

        # Check 4: Existing scaling plan
        $attachedPlan = $scalingPlans | Where-Object {
            $_.HostPoolReference.HostPoolArmPath -contains $hp.Id
        }

        if ($attachedPlan) {
            $readyItems += "Scaling plan attached: $($attachedPlan.Name)"
        } else {
            $issues += "No scaling plan attached"
        }

        # Check 5: Session hosts exist
        $sessionHosts = @()
        try {
            $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rgName -HostPoolName $hp.Name -ErrorAction SilentlyContinue
        } catch { }

        if ($sessionHosts.Count -gt 0) {
            $readyItems += "Session hosts configured: $($sessionHosts.Count)"
        } else {
            $issues += "No session hosts in pool"
        }

        # Check 6: StartVMOnConnect
        if ($hp.StartVMOnConnect) {
            $readyItems += "Start VM on Connect enabled (good for aggressive scaling down)"
        } else {
            $issues += "Start VM on Connect disabled - enable for better autoscale experience"
        }

        # Check 7: Diagnostics for metrics
        $diag = $null
        try {
            $diag = Get-AzDiagnosticSetting -ResourceId $hp.Id -ErrorAction SilentlyContinue
        } catch { }

        if ($diag) {
            $readyItems += "Diagnostics enabled (metrics available for analysis)"
        } else {
            $issues += "No diagnostics configured - enable for scaling insights"
        }

        # Determine readiness score
        $score = [math]::Round(($readyItems.Count / ($readyItems.Count + $issues.Count)) * 100)

        $assessmentResults += [PSCustomObject]@{
            SubscriptionName = $sub.Name
            ResourceGroup    = $rgName
            HostPoolName     = $hp.Name
            HostPoolType     = $hp.HostPoolType
            LoadBalancer     = $hp.LoadBalancerType
            MaxSessions      = $hp.MaxSessionLimit
            SessionHostCount = $sessionHosts.Count
            HasScalingPlan   = [bool]$attachedPlan
            ScalingPlanName  = if ($attachedPlan) { $attachedPlan.Name } else { "-" }
            StartVMOnConnect = $hp.StartVMOnConnect
            DiagEnabled      = [bool]$diag
            ReadinessScore   = "$score%"
            ReadyItems       = ($readyItems -join "; ")
            Issues           = ($issues -join "; ")
        }

        # Generate recommendation if no scaling plan
        if ($isPooled -and -not $attachedPlan) {
            $recommendations += [PSCustomObject]@{
                HostPool = $hp.Name
                ResourceGroup = $rgName
                Location = $hp.Location
                Recommendation = "Create scaling plan"
                Details = @"
Suggested scaling plan for $($hp.Name):

# Create scaling plan (run in PowerShell with Az.DesktopVirtualization)

`$schedules = @(
    @{
        Name = 'WeekdaySchedule'
        DaysOfWeek = @('Monday','Tuesday','Wednesday','Thursday','Friday')
        RampUpStartTime = @{ Hour = 7; Minute = 0 }
        RampUpLoadBalancingAlgorithm = 'BreadthFirst'
        RampUpMinimumHostsPct = 20
        RampUpCapacityThresholdPct = 60
        PeakStartTime = @{ Hour = 9; Minute = 0 }
        PeakLoadBalancingAlgorithm = 'DepthFirst'
        RampDownStartTime = @{ Hour = 17; Minute = 0 }
        RampDownLoadBalancingAlgorithm = 'DepthFirst'
        RampDownMinimumHostsPct = 10
        RampDownCapacityThresholdPct = 90
        RampDownForceLogoffUser = `$false
        RampDownWaitTimeMinute = 30
        RampDownNotificationMessage = 'Session will end in 30 minutes'
        RampDownStopHostsWhen = 'ZeroSessions'
        OffPeakStartTime = @{ Hour = 19; Minute = 0 }
        OffPeakLoadBalancingAlgorithm = 'DepthFirst'
    }
)

New-AzWvdScalingPlan ``
    -ResourceGroupName '$rgName' ``
    -Name 'sp-$($hp.Name)' ``
    -Location '$($hp.Location)' ``
    -HostPoolType 'Pooled' ``
    -TimeZone 'GMT Standard Time' ``
    -Schedule `$schedules ``
    -HostPoolReference @(@{ HostPoolArmPath = '$($hp.Id)'; ScalingPlanEnabled = `$true })
"@
            }
        }
    }
}

# Output assessment
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  ASSESSMENT RESULTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$assessmentResults | Format-Table @{L='Host Pool';E={$_.HostPoolName}},
                                   @{L='Type';E={$_.HostPoolType}},
                                   @{L='LB';E={$_.LoadBalancer}},
                                   @{L='Hosts';E={$_.SessionHostCount}},
                                   @{L='Scaling';E={if($_.HasScalingPlan){"Yes"}else{"NO"}}},
                                   @{L='StartVM';E={if($_.StartVMOnConnect){"Yes"}else{"No"}}},
                                   @{L='Diag';E={if($_.DiagEnabled){"Yes"}else{"No"}}},
                                   @{L='Ready';E={$_.ReadinessScore}} -AutoSize

# Detailed issues
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  DETAILED FINDINGS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

foreach ($result in $assessmentResults) {
    Write-Host "$($result.HostPoolName)" -ForegroundColor Yellow
    Write-Host "  Readiness: $($result.ReadinessScore)" -ForegroundColor $(if ([int]($result.ReadinessScore -replace '%','') -ge 70) { "Green" } else { "Yellow" })

    if ($result.ReadyItems) {
        Write-Host "  [OK] $($result.ReadyItems)" -ForegroundColor Green
    }
    if ($result.Issues) {
        Write-Host "  [!!] $($result.Issues)" -ForegroundColor Red
    }
    Write-Host ""
}

# Output recommendations
if ($recommendations.Count -gt 0) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  SCALING PLAN RECOMMENDATIONS" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    foreach ($rec in $recommendations) {
        Write-Host "--- $($rec.HostPool) ---" -ForegroundColor Yellow
        Write-Host $rec.Details -ForegroundColor Gray
        Write-Host ""
    }

    # Save recommendations to file
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    $recPath = Join-Path $OutputPath "ScalingPlanRecommendations.ps1"
    $recommendations | ForEach-Object { $_.Details } | Out-File $recPath -Encoding UTF8
    Write-Host "Scaling plan commands saved to: $recPath" -ForegroundColor Green
}

# Quick wins summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  QUICK WINS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$noScaling = $assessmentResults | Where-Object { -not $_.HasScalingPlan -and $_.HostPoolType -eq "Pooled" }
if ($noScaling.Count -gt 0) {
    Write-Host "1. Attach scaling plans to: $($noScaling.HostPoolName -join ', ')" -ForegroundColor White
}

$noStartVM = $assessmentResults | Where-Object { -not $_.StartVMOnConnect -and $_.HostPoolType -eq "Pooled" }
if ($noStartVM.Count -gt 0) {
    Write-Host "2. Enable 'Start VM on Connect' for: $($noStartVM.HostPoolName -join ', ')" -ForegroundColor White
    Write-Host "   Command: Update-AzWvdHostPool -ResourceGroupName <rg> -Name <pool> -StartVMOnConnect:`$true" -ForegroundColor Gray
}

$wrongLB = $assessmentResults | Where-Object { $_.LoadBalancer -ne "DepthFirst" -and $_.HostPoolType -eq "Pooled" }
if ($wrongLB.Count -gt 0) {
    Write-Host "3. Switch to DepthFirst load balancing: $($wrongLB.HostPoolName -join ', ')" -ForegroundColor White
    Write-Host "   Command: Update-AzWvdHostPool -ResourceGroupName <rg> -Name <pool> -LoadBalancerType DepthFirst" -ForegroundColor Gray
}

$noDiag = $assessmentResults | Where-Object { -not $_.DiagEnabled }
if ($noDiag.Count -gt 0) {
    Write-Host "4. Enable diagnostics for metrics: $($noDiag.HostPoolName -join ', ')" -ForegroundColor White
}

# Export
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$assessmentResults | Export-Csv -Path (Join-Path $OutputPath "AvdAutoscaleAssessment-$timestamp.csv") -NoTypeInformation -Encoding UTF8

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Assessment exported to: AvdAutoscaleAssessment-$timestamp.csv" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
