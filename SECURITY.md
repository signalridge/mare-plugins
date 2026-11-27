# Security Policy

## Reporting a Vulnerability

Please report suspected security vulnerabilities privately through **GitHub Security Advisories** on this repository rather than opening a public issue. Include the affected plugin or script path, reproduction steps, and impact details.

## Security Boundaries Covered

- **Plugin & Lifecycle Isolation**: Plugins operate strictly through Mare's public service contracts and session-scoped lifecycle boundaries; child or ephemeral sessions must not gain host-level mutations.
- **Plan-Mode & Tool Sandboxing**: `plugins/plan-mode` gates mutating tools and respects host OS sandbox policies without weakening network or filesystem restrictions.
- **Hooks Trust & Verification**: `plugins/hooks` gates workspace/package hooks behind explicit user trust and re-verifies SHA-256 package fingerprints prior to execution, including queued async hooks.
- **Secrets Storage & Projection**: `plugins/secrets` delegates credential storage to the host store, masks secret values via core projection before UI/tool serialization, and requires explicit human approval for protected arguments.
