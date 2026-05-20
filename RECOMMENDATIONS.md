# AVD Autoscale Recommendations Template

Use this template after running the audit scripts. Fill in values from your own generated outputs, then keep the completed document private unless it has been anonymised.

## Current State

| Metric | Value |
| --- | --- |
| Total host pools | |
| Pooled host pools | |
| Personal host pools | |
| Total session hosts | |
| Host pools with scaling plans | |
| Host pools without scaling plans | |
| Host pools with diagnostics | |
| Total application groups | |
| Direct user assignments | |
| Unique Entra ID groups assigned | |

## Recommendation 1: Use Native AVD Scaling Plans

For pooled host pools, prefer Azure Virtual Desktop scaling plans before introducing custom automation. Native scaling plans reduce idle compute cost, scale up before business demand, and integrate with the AVD control plane.

Baseline approach:

- Use DepthFirst load balancing outside ramp-up periods to pack users onto fewer hosts.
- Set max session limits based on workload type and VM SKU.
- Keep a minimum host percentage during ramp-up and peak windows.
- Avoid forced logoff in production unless the user-impact policy is agreed.
- Use Start VM on Connect where aggressive scale-down is required.

## Recommendation 2: Enable Diagnostics Before Final Sizing

Scaling decisions are much better with actual connection, session, and agent-health telemetry. Enable diagnostics to a Log Analytics workspace before presenting final savings projections.

Track:

- session concurrency by host pool
- disconnected-session patterns
- host availability and agent health
- connection failures
- scale-up and scale-down events

## Recommendation 3: Separate Production and Non-Production Policies

Production and non-production pools usually need different autoscale behaviour.

Suggested policy differences:

| Area | Production | Non-production |
| --- | --- | --- |
| Off-peak capacity | Keep minimum safety capacity | Allow full shutdown where acceptable |
| Force logoff | Usually avoid | Can be considered with warning |
| Change window | Controlled | More flexible |
| Alerting | Required | Useful but lower priority |

## Recommendation 4: Standardise Images and Tags

Autoscale is easier to operate when host pools are built from consistent images and tagged predictably.

Suggested tags:

- `Environment`
- `Owner`
- `Workload`
- `Criticality`
- `CostCentre`

Suggested image practice:

- build images through a repeatable process
- version images in Azure Compute Gallery
- test in non-production before production rollout
- drain old hosts before replacement

## Recommendation 5: Review Application Assignments

Use the assignment and app-to-group mapping scripts to spot access-review issues:

- direct user assignments where group-based access would be cleaner
- orphaned application groups
- duplicate or inconsistent group names
- applications assigned to overly broad groups
- app groups with no published apps

Treat these exports as sensitive because they may include application names, group names, and user identities.

## Implementation Sequence

1. Run inventory and sessions scripts.
2. Confirm host-pool ownership and criticality.
3. Enable diagnostics where missing.
4. Apply low-risk host-pool settings to a pilot pool.
5. Create a scaling plan for the pilot pool.
6. Monitor user experience and scaling behaviour.
7. Roll out to remaining pooled host pools.
8. Review generated exports and delete or archive them securely.
