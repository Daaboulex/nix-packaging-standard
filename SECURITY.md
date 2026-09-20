# Security Policy

## Supported Versions

This repository is the standard the `*-nix` packaging repos consume. The newest tag is the only supported version.

## Reporting a Vulnerability

Please report security vulnerabilities privately via GitHub Security Advisories:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Provide:
   - A description of the issue
   - Steps to reproduce
   - Potential impact
   - Any suggested mitigations

You will receive an initial response within 7 days. If the report is confirmed, a fix will be prepared privately and released with an advisory.

Please do **not** open public issues for security problems.

## Scope

This repository ships the CI, update and maintenance workflows and the updater every consumer runs. Its security scope covers:

- The shipped workflows (`ci.yml`, `update.yml`, `maintenance.yml`) and `update.sh`: injection through upstream-controlled values, unpinned actions, token scope
- The flake module and library every consumer evaluates
- The fleet scripts run with the owner's GitHub credentials
