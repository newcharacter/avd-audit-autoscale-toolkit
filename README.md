# AVD Audit & Autoscale Toolkit

PowerShell scripts for auditing Azure Virtual Desktop (AVD) estates, reviewing session-host usage, mapping application-group assignments, and producing autoscale-readiness recommendations.

This repository contains generic tooling only. Do not commit generated exports from real environments.

## Quick Start

Run from Azure Cloud Shell PowerShell, or from a local PowerShell session with the required Az modules and an authenticated Azure context.

```powershell
git clone https://github.com/newcharacter/avd-audit-autoscale-toolkit.git
cd avd-audit-autoscale-toolkit

# Optional: target one subscription
$subscriptionId = "<subscription-id>"

./Get-AvdInventory.ps1 -SubscriptionId $subscriptionId
./Get-AvdSessions.ps1 -SubscriptionId $subscriptionId
./Get-AvdAutoscaleReadiness.ps1 -SubscriptionId $subscriptionId
```

By default, generated reports are written to `outputs/`, which is ignored by git.

## Scripts

| Script | Purpose |
| --- | --- |
| `Get-AvdInventory.ps1` | Inventory host pools, app groups, workspaces, VMs, scaling plans, and diagnostics state. |
| `Get-AvdSessions.ps1` | Capture current session-host load and pool-level utilization. |
| `Get-AvdAutoscaleReadiness.ps1` | Score pooled host pools for autoscale readiness and generate suggested scaling-plan commands. |
| `Get-AvdDeepDive.ps1` | Export a broader AVD estate snapshot across host pools, VMs, networks, apps, assignments, scaling plans, and storage signals. |
| `Get-AvdAppGroupAssignments.ps1` | Export application-group role assignments for access review. |
| `Get-AvdAppToGroupMapping.ps1` | Map published RemoteApps and desktop app groups to assigned Entra ID groups. |
| `Bootstrap-AvdToolkit.ps1` | Recreate a compact copy of the core toolkit scripts in a target folder. |

All scripts accept `-SubscriptionId` where appropriate. If omitted, scripts scan enabled subscriptions visible to the current Azure account.

## Safety Notes

AVD audit outputs can contain sensitive information, including subscription IDs, resource names, host names, application names, group names, user principal names, and internal network details.

Keep generated files private unless you have reviewed and anonymised them. The following are intentionally ignored by git:

- `outputs/`
- generated `Avd*.csv` and `Avd*.json` files
- generated `ScalingPlanRecommendations.ps1`
- spreadsheet exports such as `.xlsx` and `.xlsb`

`Get-AvdSessions.ps1 -ShowUsers`, deep-dive assignment exports, and app/group mapping exports may include personal data. Use them for internal reviews only unless anonymised.

## Common Workflow

1. Run `Get-AvdInventory.ps1` to understand the estate.
2. Run `Get-AvdSessions.ps1` during representative business hours.
3. Run `Get-AvdAutoscaleReadiness.ps1` to identify low-risk autoscale changes.
4. Review generated scaling commands before running them.
5. Enable diagnostics where historical usage data is required for capacity planning.

## Autoscale Quick Reference

Enable Start VM on Connect:

```powershell
Update-AzWvdHostPool `
    -ResourceGroupName "<resource-group>" `
    -Name "<host-pool>" `
    -StartVMOnConnect:$true
```

Switch pooled host pools to DepthFirst load balancing:

```powershell
Update-AzWvdHostPool `
    -ResourceGroupName "<resource-group>" `
    -Name "<host-pool>" `
    -LoadBalancerType DepthFirst
```

Create a basic weekday scaling plan:

```powershell
$schedule = @{
    Name = "WeekdaySchedule"
    DaysOfWeek = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
    RampUpStartTime = @{ Hour = 7; Minute = 0 }
    RampUpLoadBalancingAlgorithm = "BreadthFirst"
    RampUpMinimumHostsPct = 20
    RampUpCapacityThresholdPct = 60
    PeakStartTime = @{ Hour = 9; Minute = 0 }
    PeakLoadBalancingAlgorithm = "DepthFirst"
    RampDownStartTime = @{ Hour = 17; Minute = 0 }
    RampDownLoadBalancingAlgorithm = "DepthFirst"
    RampDownMinimumHostsPct = 10
    RampDownCapacityThresholdPct = 90
    RampDownForceLogoffUser = $false
    RampDownWaitTimeMinute = 30
    RampDownNotificationMessage = "Your session may end in 30 minutes. Please save your work."
    RampDownStopHostsWhen = "ZeroSessions"
    OffPeakStartTime = @{ Hour = 19; Minute = 0 }
    OffPeakLoadBalancingAlgorithm = "DepthFirst"
}

New-AzWvdScalingPlan `
    -ResourceGroupName "<resource-group>" `
    -Name "<scaling-plan-name>" `
    -Location "<azure-region>" `
    -HostPoolType "Pooled" `
    -TimeZone "<windows-time-zone>" `
    -Schedule @($schedule) `
    -HostPoolReference @(@{
        HostPoolArmPath = "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.DesktopVirtualization/hostPools/<host-pool>"
        ScalingPlanEnabled = $true
    })
```

Enable host-pool diagnostics:

```powershell
$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName "<log-analytics-resource-group>" `
    -Name "<workspace-name>"

$hostPool = Get-AzWvdHostPool `
    -ResourceGroupName "<resource-group>" `
    -Name "<host-pool>"

Set-AzDiagnosticSetting `
    -ResourceId $hostPool.Id `
    -WorkspaceId $workspace.ResourceId `
    -Enabled $true `
    -Category @("Checkpoint", "Error", "Management", "Connection", "HostRegistration", "AgentHealthStatus")
```

## Reviewing Generated Outputs

Before sharing reports externally, remove or anonymise:

- Azure subscription and tenant identifiers
- resource group, workspace, host-pool, VM, VNet, subnet, and storage names
- application names that reveal business systems
- Entra ID group names
- user principal names and display names
- internal URLs and IP addresses
