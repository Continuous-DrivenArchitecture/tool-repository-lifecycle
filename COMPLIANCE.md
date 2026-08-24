# Compliance — CDA Repository Standard v1

This repository is **PowerShell/GitHub tooling**, not an npm library — it
has no `package.json`, publishes nothing to any registry, and implements
no runtime other than PowerShell itself. **The CDA npm Library Profile v1
does not apply here** and is not evaluated below; only the CDA repository
*baseline* — the layer every CDA repository must satisfy regardless of
kind — was assessed, read directly from the standard document (see
[standards/README.md](standards/README.md) for its canonical location),
never inferred or copied.

This repository now exists at
[Continuous-DrivenArchitecture/tool-repository-lifecycle](https://github.com/Continuous-DrivenArchitecture/tool-repository-lifecycle)
and has been provisioned for real, against its own baseline profile, using
its own tooling (`commands/provision-repository.ps1 -Profile
repository-baseline`) — a self-hosting test. Every row below marked
**VERIFIED LIVE** was independently re-read from the GitHub API after
provisioning, not inferred from the provisioner's own report.

The one unavoidable exception is documented, not hidden: the repository's
first commit was pushed directly to `main`, before any ruleset could exist
to route it through a pull request — a **BOOTSTRAP EXCEPTION**, consistent
with every prior repository bootstrap case in this engagement (see
`reports/bootstrap-exception-01.json`, kept local and gitignored, not
committed). Every change since has gone through a pull request gated by
`ci-required` and Protect main.

Legend: **FILE-LEVEL READY** — the repository's own files already satisfy
this. **VERIFIED LIVE** — independently re-read from the live GitHub
repository after real provisioning. **NOT APPLICABLE** — the baseline rule
does not apply to a repository of this kind.

## Branching

| Rule | Status | Note |
|---|---|---|
| A single permanent branch (`main`), no legacy `develop` pattern | FILE-LEVEL READY | This repository was built directly on a single branch; nothing here establishes or depends on a second permanent branch. |

## Pull requests / merge strategy / branch protection

| Rule | Status | Note |
|---|---|---|
| PR required, squash-only merges, conversation resolution, force-push/deletion blocked, `ci-required` as the sole required check, zero bypass actors | VERIFIED LIVE | The "Protect main" ruleset is active on the real repository: `required_status_checks` names only `ci-required` (strict mode), `allowed_merge_methods: ["squash"]`, `non_fast_forward` and `deletion` rules present, `bypass_actors: []`, `current_user_can_bypass: "never"`. A direct push to `main` was attempted and rejected (`GH013`, both rule violations named explicitly); PR #1 was then merged through the normal flow (squash, `ci-required` green, branch auto-deleted on merge). |

## Actions permissions / supply-chain posture

| Rule | Status | Note |
|---|---|---|
| Third-party Actions pinned to a full commit SHA | FILE-LEVEL READY | `.github/workflows/ci.yml` pins `actions/checkout` to a verified commit SHA (`3d3c42e5aac5ba805825da76410c181273ba90b1`, `v7.0.1`), not a floating tag. |
| `allowed_actions=selected`, SHA-pinning *required* (repo setting), default workflow token permissions = read | VERIFIED LIVE | `allowed_actions: "selected"`, `sha_pinning_required: true`, `default_workflow_permissions: "read"`, `can_approve_pull_request_reviews: false` — all read back directly from `GET /repos/.../actions/permissions` and `.../actions/permissions/workflow`. |

## Secrets / variables handling

| Rule | Status | Note |
|---|---|---|
| No secret exists without a workflow that references it; narrowest scope; OIDC preferred over static tokens | FILE-LEVEL READY (trivially) | This repository defines zero secrets and needs none — it is not published to any registry and requires no deployment credential. |

## Dependency automation

| Rule | Status | Note |
|---|---|---|
| Dependabot version updates enabled for every applicable ecosystem, targeting `main` | FILE-LEVEL READY | `.github/dependabot.yml` configures the `github-actions` ecosystem (the only one applicable — there is no package ecosystem here) targeting `main`. |
| Dependabot security alerts enabled | VERIFIED LIVE | `dependabot_security_updates: "enabled"` and `dependabot_vulnerability_alerts: true`, read back directly from the live repository. |

## Baseline security controls

| Rule | Status | Note |
|---|---|---|
| Secret scanning + push protection enabled | VERIFIED LIVE | `secret_scanning: "enabled"`, `secret_scanning_push_protection: "enabled"`, read back directly from the live repository. |
| CodeQL default setup (where a supported language is present) | NOT APPLICABLE | MAY-level per the standard, language-dependent. `profiles/repository-baseline.json` (the profile this repository is actually provisioned against -- see "What this reveals") correctly leaves `security.codeQLDefaultSetup.applicableLanguages` empty; PowerShell is not a CodeQL-supported language. |

## Repository hygiene

| Rule | Status | Note |
|---|---|---|
| Delete branch on merge enabled | VERIFIED LIVE | `delete_branch_on_merge: true`, read back directly; also demonstrated in practice — PR #1's `fix/npm-section-guard` branch was auto-deleted on merge. |
| No workflow file exists that is not in active use | FILE-LEVEL READY | Exactly one workflow file (`ci.yml`), actively referenced by this document's own `ci-required` job description; nothing orphaned. |
| No GitHub Environment exists that is not referenced by a current workflow | VERIFIED LIVE (trivially) | No environment was created by provisioning; none is used or referenced anywhere in this repository. |
| No GitHub Pages configuration exists that is not actively populated by a current workflow | VERIFIED LIVE (trivially) | No Pages configuration exists on the live repository; no Pages-deploying workflow. |
| Documentation describes what is *actually* live in GitHub configuration | VERIFIED LIVE | Every "VERIFIED LIVE" row above was independently re-read from the GitHub API after real provisioning, not inferred from the provisioner's own report — resolving the caveat this row previously carried. |

## Documentation

| Rule | Status | Note |
|---|---|---|
| `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` all present | FILE-LEVEL READY | All four exist. |
| `CONTRIBUTING.md` covers branching model, commit convention, PR process, release model, Action-pinning rule, contribution flow | FILE-LEVEL READY, with one N/A | This repository has no release model (it is not published/versioned as a package) — `CONTRIBUTING.md` does not claim one. Every other required element is present. |

## What this reveals

Every row above that once read "EXTERNAL GITHUB SETUP REQUIRED" is now
**VERIFIED LIVE**, closed by
**`commands/provision-repository.ps1 -Profile repository-baseline`** —
this repository was provisioned for real against
`profiles/repository-baseline.json` (CDA Repository Baseline v1, alone, as
an executable projection of the standard — see
[docs/profiles.md](docs/profiles.md), "Three concepts, not one"), **not** a
kind-specific profile. `commands/provision-npm-library.ps1` does not apply
here and was not used for this repository.

This self-hosting run also surfaced and fixed one real bug that no prior
test had exercised: `Invoke-Provisioning` read a profile's `npm` section
unconditionally, which crashed against a baseline-only profile (one with no
`npm` section, by design). Caught live by this repository's own `-DryRun`
before any mutation happened, fixed, covered by a new regression test, and
landed through the normal PR flow (PR #1) — the exact "reproduce → test →
fix → suite green" discipline this tooling requires of everyone else,
applied to itself.

A future **CDA Tooling/CLI Profile** remains a concrete, but still
undefined, candidate: this baseline-only run may eventually surface real,
repeated needs specific to PowerShell/tooling repositories (beyond what
the baseline alone covers) that would justify one. Per this repository's
own founding constraint, **evidence first, profile second**: it is not
invented or built here, only recorded as a possibility, and will only be
defined after this repository has real, live operating history under the
baseline alone.

## Status

| Category | Result |
|---|---|
| FILE-LEVEL READY | PASS |
| BASELINE PROVISIONING SUPPORT | PASS -- `profiles/repository-baseline.json` + `commands/provision-repository.ps1` implement CDA Repository Baseline v1 alone, composition-verified against `profiles/npm-library.json`'s unchanged effective state (489/489 local tests) |
| EXTERNAL GITHUB SETUP | PASS -- verified live against `Continuous-DrivenArchitecture/tool-repository-lifecycle` by independently re-reading every setting from the GitHub API after real provisioning |
| CDA Repository Standard v1 | PASS -- every MUST-level baseline requirement is VERIFIED LIVE; the sole open item, `-Mode Verify` MAY-level rows (CodeQL default setup, dependency-review enforcement workflow), are correctly reported as SKIP/NOT AVAILABLE, never silently required |
| CDA npm Library Profile v1 | NOT APPLICABLE -- this repository is not an npm library |
| CDA Tooling/CLI Profile | NOT DEFINED -- evidence first, per "What this reveals" above; this repository's own real operating history under the baseline alone (recorded here) is exactly the evidence that future decision would draw on |

This document was updated from live, independently-verified GitHub state
via a short-lived branch (`docs/record-live-compliance`), merged through
the same PR + `ci-required` + Protect main flow it documents — not written
speculatively and not pushed directly to `main`.
