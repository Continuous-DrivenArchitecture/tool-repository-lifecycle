# CDA Repository Lifecycle Tooling

**Purpose:** make CDA repository governance executable, auditable, and safe.

This repository formalizes, as one independent and maintainable project,
the tooling that turns the CDA repository standards into concrete GitHub
configuration — for repositories that are being created, and for
repositories that already exist.

## Conceptual model

```
NEW repository:      template  ->  provision  ->  verify
EXISTING repository: assess    ->  plan  ->  approve  ->  apply  ->  verify
```

These are two different lifecycles on purpose — see
[docs/lifecycle.md](docs/lifecycle.md), "Provisioning != Adoption". A new
repository's GitHub-side state can simply be *applied*; an existing
repository's state must first be *understood*, then *planned*, then
*explicitly approved* by a human before anything changes, because an
existing repository already has real history, real branches, and real
consumers that a mechanical convergence could damage.

- **Standards** are policy: what a compliant CDA repository *is*, in
  prose. They are not implemented here — see [standards/README.md](standards/README.md)
  for where they actually live.
- **Profiles** are desired state: one profile turns a standard into
  concrete, machine-readable GitHub settings. [profiles/repository-baseline.json](profiles/repository-baseline.json)
  is CDA Repository Baseline v1 ALONE (an executable projection of the
  standard, not a new profile); [profiles/npm-library.json](profiles/npm-library.json)
  is a thin overlay extending it for npm libraries. See
  [docs/profiles.md](docs/profiles.md), "Three concepts, not one".
- **Templates** implement repository *files* (workflows, `package.json`,
  `CONTRIBUTING.md`, ...) for a given profile. Templates are not part of
  this repository.
- **The provisioner** (`src/provisioner/`, `commands/provision-repository.ps1`
  for any profile, `commands/provision-npm-library.ps1` as an npm-library-
  specific convenience wrapper) configures a *new* repository's GitHub-side
  settings against a profile.
- **The adopter** (`src/adopter/`, `commands/assess-npm-library.ps1` /
  `approve-plan.ps1` / `apply-plan.ps1`) migrates an *existing*
  repository's GitHub-side settings toward a profile, through an
  assess → plan → approve → apply → verify lifecycle that never mutates
  anything without an explicit, individually reviewable approval.
- **Approval artifacts** separate the decision (what should change, and
  who agreed to it) from the execution (what a script actually did) — see
  [docs/artifact-model.md](docs/artifact-model.md).

## Repository layout

```
profiles/            desired GitHub-side state (JSON)
schemas/              JSON Schema for every machine-readable artifact
src/common/           shared core: GitHub HTTP layer, repository
                      validation, profile loading, read-only discovery
src/provisioner/      NEW-repository lifecycle path
src/adopter/          EXISTING-repository lifecycle path
commands/             CLI entry points (PowerShell scripts)
tests/                offline logic tests + synthetic fixtures
standards/            pointer to the canonical CDA standards (not a copy)
docs/                 architecture, lifecycle, safety model, artifact model
```

See [docs/architecture.md](docs/architecture.md) for how these pieces fit
together, including exactly which parts are genuinely shared between the
two lifecycle paths and which are deliberately kept separate.

## Quick start

```powershell
# NEW repository, baseline only (no kind-specific profile):
.\commands\provision-repository.ps1 -Repository Continuous-DrivenArchitecture/<repo> -Profile repository-baseline -Mode Bootstrap -DryRun
.\commands\provision-repository.ps1 -Repository Continuous-DrivenArchitecture/<repo> -Profile repository-baseline -Mode Bootstrap

# NEW repository, npm library profile:
.\commands\provision-npm-library.ps1 -Repository Continuous-DrivenArchitecture/<repo> -Mode Bootstrap -DryRun
.\commands\provision-npm-library.ps1 -Repository Continuous-DrivenArchitecture/<repo> -Mode Bootstrap

# EXISTING repository:
.\commands\assess-npm-library.ps1 -Repository Continuous-DrivenArchitecture/<repo> -JsonOutputPath .\reports\assessment.json
.\commands\approve-plan.ps1 -Plan .\reports\assessment.json -ApproveSafeChanges -OutputPath .\reports\approved-plan.json
.\commands\apply-plan.ps1 -Plan .\reports\approved-plan.json -Repository Continuous-DrivenArchitecture/<repo> -DryRun
.\commands\apply-plan.ps1 -Plan .\reports\approved-plan.json -Repository Continuous-DrivenArchitecture/<repo>
```

`./reports/` is the default, gitignored location for anything a command
writes — see [docs/artifact-model.md](docs/artifact-model.md), "Report
output location". Nothing under it is ever committed to this repository;
`tests/fixtures/` holds the sanitized, synthetic examples used by the test
suite instead.

## Safety

Every mutating GitHub call in this repository goes through exactly one of
two modules — `src/common/github/MutationGitHub.psm1` — and only from the
two orchestration points that are allowed to import it
(`src/adopter/lib/Apply.psm1`, `src/provisioner/lib/Orchestration.psm1`).
Everything else — including every command that only *assesses* or
*plans* — can only read. This boundary is checked structurally by the
test suite, not just documented. See [docs/safety-model.md](docs/safety-model.md)
for the full safety model: fail-closed classification, exact approved-plan
execution, deterministic plan hashing, stale-plan rejection, the
independent "destructive" safety property, and read-back verification.

## Testing

```powershell
powershell.exe -NoProfile -File .\tests\run-tests.ps1
```

Offline, no `gh` call, no network access, no real GitHub repository —
plain assertions, no test-framework dependency. Covers both lifecycle
paths, the shared common core, JSON Schema validation of every artifact
shape, and the safety properties described above.

## Status

This formalization is derived from `tools/repository-provisioner/` and
`tools/repository-adopter/` in the `Continuous-DrivenArchitecture`
workspace, both of which were validated against real GitHub repositories
before this repository existed. See [COMPLIANCE.md](COMPLIANCE.md) for
this repository's own compliance status against the CDA repository
baseline, and [docs/artifact-model.md](docs/artifact-model.md) for the
capability model that determines when a repository this tooling manages
can be reported fully compliant.
