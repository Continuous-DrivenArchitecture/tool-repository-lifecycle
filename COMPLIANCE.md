# Compliance — CDA Repository Standard v1

This repository is **PowerShell/GitHub tooling**, not an npm library — it
has no `package.json`, publishes nothing to any registry, and implements
no runtime other than PowerShell itself. **The CDA npm Library Profile v1
does not apply here** and is not evaluated below; only the CDA repository
*baseline* — the layer every CDA repository must satisfy regardless of
kind — was assessed, read directly from the standard document (see
[standards/README.md](standards/README.md) for its canonical location),
never inferred or copied.

This assessment predates this repository's existence on GitHub — see
[Status](#status) at the end. It records what is already true at the
file level, and what remains true only once the repository is created and
configured remotely (the explicit next task, per this formalization's own
governing instruction: no remote repository creation or GitHub mutation
happens as part of building this repository locally).

Legend: **FILE-LEVEL READY** — the repository's own files already satisfy
this. **EXTERNAL GITHUB SETUP REQUIRED** — satisfying this needs a live
GitHub repository to configure (branch protection, Actions permissions,
security toggles, Dependabot enablement); nothing more can be done at the
file level. **NOT APPLICABLE** — the baseline rule does not apply to a
repository of this kind.

## Branching

| Rule | Status | Note |
|---|---|---|
| A single permanent branch (`main`), no legacy `develop` pattern | FILE-LEVEL READY | This repository was built directly on a single branch; nothing here establishes or depends on a second permanent branch. |

## Pull requests / merge strategy / branch protection

| Rule | Status | Note |
|---|---|---|
| PR required, squash-only merges, conversation resolution, force-push/deletion blocked, `ci-required` as the sole required check, zero bypass actors | EXTERNAL GITHUB SETUP REQUIRED | A ruleset can only be created against a repository that exists remotely. `.github/workflows/ci.yml`'s `ci-required` job already exists at the file level and is designed to be exactly what a future ruleset would require (see docs/safety-model.md's own description of this pattern, proven in the source engagement this tooling formalizes). |

## Actions permissions / supply-chain posture

| Rule | Status | Note |
|---|---|---|
| Third-party Actions pinned to a full commit SHA | FILE-LEVEL READY | `.github/workflows/ci.yml` pins `actions/checkout` to a verified commit SHA (`3d3c42e5aac5ba805825da76410c181273ba90b1`, `v7.0.1`), not a floating tag. |
| `allowed_actions=selected`, SHA-pinning *required* (repo setting), default workflow token permissions = read | EXTERNAL GITHUB SETUP REQUIRED | These are repository settings, not files; nothing to configure until the repository exists. |

## Secrets / variables handling

| Rule | Status | Note |
|---|---|---|
| No secret exists without a workflow that references it; narrowest scope; OIDC preferred over static tokens | FILE-LEVEL READY (trivially) | This repository defines zero secrets and needs none — it is not published to any registry and requires no deployment credential. |

## Dependency automation

| Rule | Status | Note |
|---|---|---|
| Dependabot version updates enabled for every applicable ecosystem, targeting `main` | FILE-LEVEL READY (file) / EXTERNAL GITHUB SETUP REQUIRED (enablement) | `.github/dependabot.yml` configures the `github-actions` ecosystem (the only one applicable — there is no package ecosystem here) targeting `main`. Dependabot itself must still be enabled on the live repository. |
| Dependabot security alerts enabled | EXTERNAL GITHUB SETUP REQUIRED | Repository setting. |

## Baseline security controls

| Rule | Status | Note |
|---|---|---|
| Secret scanning + push protection enabled | EXTERNAL GITHUB SETUP REQUIRED | Repository settings. |
| CodeQL default setup (where a supported language is present) | NOT APPLICABLE | MAY-level per the standard, language-dependent. `profiles/repository-baseline.json` (the profile this repository is actually provisioned against -- see "What this reveals") correctly leaves `security.codeQLDefaultSetup.applicableLanguages` empty; PowerShell is not a CodeQL-supported language. |

## Repository hygiene

| Rule | Status | Note |
|---|---|---|
| Delete branch on merge enabled | EXTERNAL GITHUB SETUP REQUIRED | Repository setting. |
| No workflow file exists that is not in active use | FILE-LEVEL READY | Exactly one workflow file (`ci.yml`), actively referenced by this document's own `ci-required` job description; nothing orphaned. |
| No GitHub Environment exists that is not referenced by a current workflow | FILE-LEVEL READY (trivially) | No environment is used or referenced anywhere in this repository. |
| No GitHub Pages configuration exists that is not actively populated by a current workflow | FILE-LEVEL READY (trivially) | No Pages configuration, no Pages-deploying workflow. |
| Documentation describes what is *actually* live in GitHub configuration | FILE-LEVEL READY, with an explicit caveat | Every doc in this repository describes the *intended* configuration (this repository does not exist on GitHub yet). Once created and configured, this file and `docs/*.md` must be re-checked against the real, live settings — a discrepancy discovered then is a defect to resolve, not left standing (see the baseline's own rule on this point). |

## Documentation

| Rule | Status | Note |
|---|---|---|
| `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` all present | FILE-LEVEL READY | All four exist. |
| `CONTRIBUTING.md` covers branching model, commit convention, PR process, release model, Action-pinning rule, contribution flow | FILE-LEVEL READY, with one N/A | This repository has no release model (it is not published/versioned as a package) — `CONTRIBUTING.md` does not claim one. Every other required element is present. |

## What this reveals

Every "EXTERNAL GITHUB SETUP REQUIRED" row above is now closable by
**`commands/provision-repository.ps1 -Profile repository-baseline`** —
this repository is provisioned against `profiles/repository-baseline.json`
(CDA Repository Baseline v1, alone, as an executable projection of the
standard — see [docs/profiles.md](docs/profiles.md), "Three concepts, not
one"), **not** a kind-specific profile. `commands/provision-npm-library.ps1`
does not apply here and is not used for this repository.

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
| BASELINE PROVISIONING SUPPORT | PASS -- `profiles/repository-baseline.json` + `commands/provision-repository.ps1` implement CDA Repository Baseline v1 alone, composition-verified against `profiles/npm-library.json`'s unchanged effective state (487/487 local tests) |
| EXTERNAL GITHUB SETUP | PENDING -- this repository has not yet been created as `Continuous-DrivenArchitecture/tool-repository-lifecycle` on GitHub |
| CDA npm Library Profile v1 | NOT APPLICABLE -- this repository is not an npm library |
| CDA Tooling/CLI Profile | NOT DEFINED -- evidence first, per "What this reveals" above |

**Full CDA Repository Standard compliance is not claimed here.** This
document records file-level readiness and the tooling's own capability to
provision the baseline; it explicitly does NOT claim external GitHub-side
compliance, which requires the repository to actually exist and be
provisioned for real. This document is updated again, from live,
independently-verified evidence, once that happens — see the task that
publishes and self-hosts this repository.
