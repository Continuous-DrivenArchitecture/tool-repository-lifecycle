# Security Policy

## Reporting a vulnerability

Please report security concerns privately rather than opening a public
issue — use GitHub's private vulnerability reporting for this repository
(**Security** tab → **Report a vulnerability**) once it is published
under the `Continuous-DrivenArchitecture` organization.

Include, where possible:

- what you found (e.g. a way this tooling could be induced to mutate
  something it wasn't approved to touch, leak a secret value, or bypass
  the destructive-operation approval requirement);
- reproduction steps against a sandbox/test repository, never against
  production infrastructure;
- the affected file(s)/function(s), if known.

## Scope

This repository is PowerShell tooling that reads and, when explicitly
approved, mutates GitHub repository configuration via the `gh` CLI. In
scope:

- Any path by which `src/common/github/ReadOnlyGitHub.psm1` (or any
  assess/discovery-only module) could be made to mutate something — see
  [docs/safety-model.md](docs/safety-model.md), "Read-only/mutation
  isolation".
- Any path by which a destructive operation (`branch.delete.develop`,
  `secret.*`, `hygiene.*`, ruleset deletion) could be applied without an
  explicit, individually-named approval.
- Any path by which a secret or variable *value* (not just its name)
  could be read, logged, or persisted by this tooling.
- Plan-hash tampering that goes undetected (see [docs/artifact-model.md](docs/artifact-model.md),
  "Plan hash contract").
- Stale-plan execution: a mutation proceeding despite live state having
  diverged from the state an approved plan was built against.

Out of scope: vulnerabilities in `gh` itself, in GitHub's own API/service,
or in PowerShell — report those to their respective maintainers.

## Supported versions

This repository has no released versions yet; the `main` branch is the
only supported target for reports.
