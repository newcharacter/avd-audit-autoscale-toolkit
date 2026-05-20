# Contributing

Contributions are welcome if they keep the toolkit generic and safe to publish.

## Ground Rules

- Do not commit generated reports from real Azure environments.
- Do not commit screenshots, spreadsheets, host names, group names, user principal names, subscription IDs, tenant IDs, or internal URLs.
- Use placeholders in examples.
- Keep scripts read-heavy by default. Any write action should be explicit, documented, and easy to review.
- Prefer small changes with clear before/after behaviour.

## Local Checks

Before opening a pull request:

```powershell
# Optional if available
Invoke-ScriptAnalyzer -Path . -Recurse
```

Also run a text scan for environment-specific strings before publishing changes.
