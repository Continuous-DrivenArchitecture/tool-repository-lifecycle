# Architecture

```
Standards (docs/standards/*.md, canonical location: see standards/README.md)
        |
        v
Profiles (profiles/*.json — desired GitHub-side state)
        |
        v
Lifecycle tooling (this repository)
    +-- Provisioner (src/provisioner/) -- NEW repositories
    +-- Adopter     (src/adopter/)     -- EXISTING repositories
        |
        v
    GitHub
```

Both lifecycle paths read the *same* profile (`profiles/npm-library.json`)
as their single source of desired state. Neither ever defines its own
copy of that target — see [profiles.md](profiles.md).

## Boundary with templates

A **template repository** (e.g. a future `template-npm-library`)
implements a profile's *repository files*: `package.json`, workflow
YAML, `CONTRIBUTING.md`, and so on. This repository never generates,
edits, or validates those files — its scope stops at GitHub-side
*configuration*: repository settings, Actions permissions, security
settings, branch-protection rulesets, secrets/environments/Pages
existence. A repository created from a template still needs this
tooling's provisioner run against it before its GitHub configuration
matches the profile the template implements.

## Boundary with a future generator/CLI

Section 21 of this repository's own founding task is explicit: **no CLI
is built yet.** The PowerShell scripts under `commands/` are this
version's complete, valid interface. A future `cda repo ...`-style CLI
(or an installable module, or a GUI) is expected to be built *on top of*
the contracts this repository already stabilizes — the artifact schemas
(`schemas/*.json`), the plan-hash contract, the operation-id namespace,
the classification taxonomy — not to redefine them. Nothing in this
repository assumes that CLI exists yet, and nothing here should be read as
a promise of when it will.

## Common core (`src/common/`)

Before this formalization, the provisioner and adopter tools each
independently implemented near-identical logic for: talking to the GitHub
API, validating a repository name/eligibility, loading a profile, and
reading a handful of repository-state snapshots (languages, Actions
permissions, rulesets, security-and-analysis settings, vulnerability
alerts, CodeQL state). That duplication was real, and is now shared:

| Module | Responsibility |
|---|---|
| `src/common/github/ReadOnlyGitHub.psm1` | The *only* GET-capable GitHub API client in this repository. |
| `src/common/github/MutationGitHub.psm1` | The *only* mutation-capable (POST/PUT/PATCH/DELETE) GitHub API client. |
| `src/common/github/RepositoryDiscovery.psm1` | Read-only state **snapshots** (repository overview, languages, Actions permissions, rulesets, vulnerability alerts, CodeQL) — no classification, no comparison, no mutation. |
| `src/common/repository/Validation.psm1` | Repository name-format validation and org/archived/fork eligibility (see below for the one place provisioning and adoption legitimately differ). |
| `src/common/profile/ProfileLoader.psm1` | Loads and parses a profile JSON file with one consistent error shape, and composes a profile with what it `extends` (`Get-EffectiveCdaProfile`) -- see [profiles.md](profiles.md), "Composition". |

**What was deliberately NOT unified**, and why:

- **Fork handling.** The provisioner refuses a fork outright unless
  `-AllowFork`; the adopter always allows a fork through (assessing it is
  harmless) but reports `IsFork` prominently. `Test-RepositoryEligibility`
  takes an explicit `-RejectForks` switch so each lifecycle path keeps its
  own real, already-validated behavior rather than being forced into one.
- **The comparison/classification models.** The adopter's 8-value
  classification taxonomy (`COMPLIANT`/`SAFE_CHANGE`/`REVIEW_REQUIRED`/...)
  plus its human-approval lifecycle, and the provisioner's `PlanItem`
  model (`NONE`/`UPDATE`/`SKIP`/`CREATE`/`FAIL_SAFE` + immediate
  `-DryRun`-gated apply) serve genuinely different lifecycles — an
  existing repository's drift needs a human decision *before* anything
  changes; a new repository's configuration can simply converge. Forcing
  these into one shape would have made both harder to reason about for no
  real reduction in duplication (see `docs/safety-model.md`, "Read-only/
  mutation isolation" for why the two paths' mutation code also stays
  separate).
- **`Test-RequiredCheckEvidence`.** Both `src/adopter/lib/Apply.psm1` and
  `src/provisioner/lib/Provisioner.psm1` define their own version. They
  read the same endpoint but answer different questions (the adopter
  wants a strict boolean "has this check succeeded at least once"; the
  provisioner wants the actual conclusion, including non-success, to
  build a specific fail-safe message for `-Mode Finalize`). Unifying them
  risked changing already-validated Bootstrap/Finalize fail-safe behavior
  for a cosmetic reduction in line count — not a safe extraction by this
  repository's own stated bar ("solo cuando sea seguro").
- **JSON canonicalization / plan hashing** (`Get-CanonicalJsonText`,
  `Get-Sha256Hex`, `Get-PlanHash` in `src/adopter/lib/Approval.psm1`).
  The provisioner has no equivalent concept at all (it never produces an
  approved-plan artifact), so there was no real duplication to remove.

## Per-lifecycle-path structure

```
src/provisioner/lib/
  Provisioner.psm1     read-only discovery + pure comparison (New-PlanItem,
                        Compare-*, New-DesiredRulesetBody) -- no mutation
  Orchestration.psm1    the ONLY module that mutates; Bootstrap/Finalize/
                        Verify mode flow, gated by -DryRun

src/adopter/lib/
  Discovery.psm1         read-only state gathering (repository-specific:
                          branches, workflows, secrets/variables metadata,
                          environments, Pages, releases, ...)
  Classification.psm1    pure decision logic -- the 8-value taxonomy
  Comparison.psm1        combines Discovery + Classification into rows
  AdoptionPlan.psm1      phases classified rows into a plan; renders
                          Markdown/JSON reports; computes FullCdaCompliance
  MergeReproducibility.psm1  native-git evidence for branch retirement
  Approval.psm1           assessment -> approved-plan (no GitHub call)
  Apply.psm1               the ONLY module that mutates; executes an
                            approved plan exactly, nothing more
  Verification.psm1        read-back + independent full re-assessment
```
