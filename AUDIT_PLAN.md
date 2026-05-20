# AVD Audit Plan

This plan gives a repeatable structure for reviewing an Azure Virtual Desktop estate before enabling autoscale.

## Phase 1: Discovery

Goal: establish a current-state view of the AVD environment.

| Task | Tool | Output |
| --- | --- | --- |
| Inventory host pools, VMs, app groups, workspaces, and scaling plans | `Get-AvdInventory.ps1` | estate summary and inventory files |
| Capture current session load | `Get-AvdSessions.ps1` | per-host and per-pool utilization |
| Assess autoscale readiness | `Get-AvdAutoscaleReadiness.ps1` | issues, readiness score, suggested commands |
| Map application access | `Get-AvdAppToGroupMapping.ps1` | application-to-group matrix |
| Review application-group assignments | `Get-AvdAppGroupAssignments.ps1` | assignment export for access review |

## Phase 2: Quick Wins

For pooled host pools, review:

- Start VM on Connect
- DepthFirst load balancing
- max session limits
- diagnostics coverage
- existing scaling-plan attachment

Apply changes first to a pilot pool with clear rollback instructions.

## Phase 3: Scaling Plan Design

Define schedules by workload, not by guesswork alone. A typical weekday office pattern has:

- ramp-up before users arrive
- peak business-hours capacity
- ramp-down after core hours
- off-peak minimum capacity

Avoid using one schedule for every pool unless the usage pattern really is the same.

## Phase 4: Validation

Monitor:

- host start and stop events
- connection failures
- user reports during ramp-up and ramp-down
- disconnected-session counts
- cost trend against baseline

Keep diagnostics enabled long enough to see normal weekday behaviour.

## Phase 5: Access and Architecture Review

Autoscale work often reveals adjacent cleanup tasks:

- app groups with broad or direct assignments
- unclear production/non-production boundaries
- inconsistent host-pool naming
- missing ownership tags
- legacy images or unmanaged host replacement

Track these separately from the autoscale rollout so a cost-saving task does not silently become a full architecture migration.

## Output Handling

The scripts generate operational data. Store generated files in `outputs/`, keep that folder out of git, and anonymise outputs before sharing outside the owning team.
