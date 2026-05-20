# What This Repo Is For

This repository is a small Azure Virtual Desktop audit toolkit. It helps an engineer quickly answer:

- What AVD host pools exist?
- Which hosts, app groups, workspaces, scaling plans, and diagnostics settings are present?
- How busy are the hosts right now?
- Which host pools are ready for autoscale?
- Which app groups and applications are assigned to which Entra ID groups?

It is designed for discovery and planning. It does not automatically change host-pool settings unless you copy and run the generated recommendation commands yourself.

## What Belongs Here

- generic PowerShell scripts
- generic documentation and templates
- examples that use placeholders only
- guardrails for handling generated reports safely

## What Does Not Belong Here

- real customer or employer exports
- subscription IDs, tenant IDs, host names, VM names, VNet/subnet names, or resource-group names from live environments
- app inventories from live environments
- group/user assignment exports
- user principal names, staff names, or email addresses
- internal URLs, IP addresses, screenshots, or spreadsheets

## Public-Repo Rule

If a file was produced by running the toolkit against a real Azure environment, assume it is private until reviewed and anonymised.
