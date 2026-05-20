# AVD Audit & Autoscale Toolkit

Small PowerShell toolkit for Azure Virtual Desktop (AVD) discovery, session-load review, application assignment mapping, and autoscale readiness checks.

It is intentionally read-heavy. The scripts collect evidence and produce local reports; they do not change host-pool settings unless you copy and run the generated recommendation commands yourself.

## What It Does

- inventories host pools, workspaces, app groups, session hosts, VMs, scaling plans, and diagnostics
- captures current session pressure by pool and host
- scores pooled host pools for autoscale readiness
- maps RemoteApps and desktop app groups to assigned Entra ID groups
- writes timestamped CSV/JSON reports to `outputs/`

## Quick Start

Run from Azure Cloud Shell PowerShell, or from a local PowerShell session with the Az modules installed and an authenticated Azure context.

```powershell
git clone https://github.com/newcharacter/avd-audit-autoscale-toolkit.git
cd avd-audit-autoscale-toolkit

Connect-AzAccount

# Optional: target one subscription
$subscriptionId = "<subscription-id>"

./Get-AvdInventory.ps1 -SubscriptionId $subscriptionId
./Get-AvdSessions.ps1 -SubscriptionId $subscriptionId
./Get-AvdAutoscaleReadiness.ps1 -SubscriptionId $subscriptionId
```

If a required Az module is missing, install it yourself or rerun the script with `-InstallMissingModules`.

```powershell
./Get-AvdInventory.ps1 -SubscriptionId $subscriptionId -InstallMissingModules
```

## Scripts

| Script | Purpose | Typical output |
| --- | --- | --- |
| `Get-AvdInventory.ps1` | Inventory host pools, app groups, workspaces, VMs, scaling plans, and diagnostics state. | `AvdInventory-*.csv`, `AvdInventory-*.json` |
| `Get-AvdSessions.ps1` | Capture current session-host load and pool-level utilization. | `AvdSessions-*.csv`, `AvdPoolSummary-*.csv` |
| `Get-AvdAutoscaleReadiness.ps1` | Score pooled host pools for autoscale readiness and generate suggested scaling-plan commands. | `AvdAutoscaleAssessment-*.csv`, `ScalingPlanRecommendations.ps1` |
| `Get-AvdDeepDive.ps1` | Export a broader estate snapshot across host pools, VMs, networks, apps, assignments, scaling plans, and storage signals. | `AvdDeepDive-*.json`, multiple CSVs |
| `Get-AvdAppGroupAssignments.ps1` | Export application-group role assignments for access review. | `AvdAppGroupAssignments-*.csv` |
| `Get-AvdAppToGroupMapping.ps1` | Map published RemoteApps and desktop app groups to assigned Entra ID groups. | `AvdAppToGroupMapping-*.csv` |

All scripts accept `-SubscriptionId` where appropriate. If omitted, scripts scan enabled subscriptions visible to the current Azure account.

## Safe Handling

Generated reports can contain sensitive information: subscription IDs, resource names, host names, application names, group names, user principal names, and internal network details.

The repo ignores generated report files by default, including:

- `outputs/`
- `Avd*.csv`
- `Avd*.json`
- `Avd*.xlsx`
- `Avd*.xlsb`
- `ScalingPlanRecommendations.ps1`
- group list exports

Keep generated outputs private unless they have been reviewed and anonymised. `Get-AvdSessions.ps1 -ShowUsers`, deep-dive assignment exports, and app/group mapping exports may include personal data.

## Suggested Workflow

1. Run `Get-AvdInventory.ps1` to understand the estate.
2. Run `Get-AvdSessions.ps1` during representative business hours.
3. Run `Get-AvdAutoscaleReadiness.ps1` to identify low-risk autoscale changes.
4. Review the generated scaling commands before running anything.
5. Enable diagnostics where historical usage data is required for capacity planning.
6. Use the assignment mapping scripts for access reviews, then store those outputs securely.

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

## Before Sharing Outputs

Remove or anonymise:

- Azure subscription and tenant identifiers
- resource group, workspace, host-pool, VM, VNet, subnet, and storage names
- application names that reveal business systems
- Entra ID group names
- user principal names and display names
- internal URLs and IP addresses

## License

MIT. See `LICENSE`.
