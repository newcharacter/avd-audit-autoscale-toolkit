# Security Policy

## Reporting a Problem

Please do not open a public issue containing secrets, tenant details, subscription IDs, host names, user principal names, screenshots from live environments, or generated audit exports.

If you find a security issue in the toolkit itself, open a minimal issue that describes the class of problem without exposing environment data. If sensitive details are required, share them privately with the repository owner.

## Data Handling

The scripts can generate reports containing sensitive operational information. Treat all generated output as private until reviewed.

Before sharing reports, remove or anonymise:

- subscription and tenant identifiers
- resource names and host names
- internal network names, URLs, and IP addresses
- application names that reveal business systems
- group names and user identities

Generated report files are ignored by git, but local ignores are not a substitute for review.
