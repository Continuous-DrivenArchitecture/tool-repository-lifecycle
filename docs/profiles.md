# Profiles

## Three concepts, not one

This tooling deliberately keeps three concepts distinct, because
conflating them is exactly how a profile silently drifts from the
standard it claims to implement:

```
STANDARD                    the normative prose. Policy. What a
                             compliant repository IS, independent of
                             any tooling. Lives in docs/standards/*.md
                             (see standards/README.md) -- never in
                             this repository.

PROFILE                      the machine-readable, desired-state
                             PROJECTION of one standard (or a standard
                             plus one repository-kind extension) --
                             a profiles/*.json file. Executable, but
                             still just data: nothing in a profile
                             file decides HOW to converge toward it.

LIFECYCLE TOOLING            the code that reads a profile and DOES
                             something with it: discovers live state,
                             compares it, classifies drift, and (only
                             when explicitly told to) mutates GitHub.
                             src/provisioner/ and src/adopter/.
```

Concretely, two chains exist today:

```
CDA Repository Baseline v1
        v
repository-baseline.json desired state   (profiles/repository-baseline.json)
        v
repository lifecycle tooling               (this repository)
```

```
CDA Repository Baseline v1 + CDA npm Library Profile v1
        v
npm-library.json effective desired state   (profiles/npm-library.json,
                                             an OVERLAY on
                                             repository-baseline.json)
        v
repository lifecycle tooling                (the SAME tooling, same code)
```

**`profiles/repository-baseline.json` is an executable representation of
the normative baseline standard. It is NOT a new CDA profile** — this
matters: it introduces no new policy of its own. Every field in it is a
direct, traceable projection of a MUST/SHOULD/MAY rule already approved in
`docs/standards/cda-repository-baseline-v1.md` (see its own
`normativeLevels` block, and [artifact-model.md](artifact-model.md) for
how MUST/SHOULD/MAY map to this tooling's classification model). A
repository that implements no kind-specific profile on top of the
baseline (this tooling's own repository is the first real example) is
provisioned/assessed against `repository-baseline.json` directly.

A profile is the machine-readable, desired-state projection of one
standards pair (e.g. "CDA Repository Baseline v1 + CDA npm Library
Profile v1", `profiles/npm-library.json`), OR of the baseline alone
(`profiles/repository-baseline.json`). It describes GitHub-side
configuration only — never repository file contents (those belong to a
template), never a language- or package-manager-specific concern beyond
what affects GitHub settings (e.g. which Actions to trust).

## Composition: `extends`

`npm-library.json`'s `extends` field names `repository-baseline` — a
sibling file in the same `profiles/` directory (resolved to
`profiles/repository-baseline.json`), not just a documentation string.
`src/common/profile/ProfileLoader.psm1`'s `Get-EffectiveCdaProfile`
resolves this: it loads the named base profile, then deep-merges the
overlay's own fields on top (object fields merge recursively field-by-
field — e.g. an overlay can override just `security.codeQLDefaultSetup`
without restating the rest of `security`; array fields and scalars are
replaced wholesale, never merged element-wise, so "the overlay clears a
list" and "the overlay didn't mention it" stay distinguishable).

This is what lets `npm-library.json` stay a **small overlay** — currently
just `security.codeQLDefaultSetup` (JavaScript/TypeScript-specific,
MAY-level per the standard, so the baseline itself leaves it empty) and
the `npm` section (release/publish mechanics, entirely out of the
baseline's scope) — instead of duplicating the whole baseline inline.
Every command (`commands/assess-npm-library.ps1`,
`commands/provision-npm-library.ps1`, `commands/provision-repository.ps1`,
and `src/adopter/lib/Apply.psm1`'s own `-ProfilePath`-driven mutation
specs) resolves profiles through `Get-EffectiveCdaProfile`, never a raw
parse — a raw parse of `npm-library.json` alone would silently see only
the overlay, missing every field it inherits.

A base profile like `repository-baseline.json` has no `extends` of its
own — this is correct, not an oversight: it implements the standard
directly rather than extending another profile. `Get-EffectiveCdaProfile`
returns it as-is (`Extended = $false`).

## Structure

See [../schemas/repository-profile.schema.json](../schemas/repository-profile.schema.json)
for the full, authoritative shape of a COMPLETE (post-composition)
profile. At a glance:

| Section | Covers |
|---|---|
| `normativeLevels` | (baseline profiles only) MUST/SHOULD/MAY annotation per field, traced directly to the standard -- see `repository-baseline.json`'s own block. Never elevates a SHOULD/MAY to MUST silently. |
| `repositorySettings` | Default branch, merge-method availability, delete-branch-on-merge, auto-merge. |
| `actions` | Actions enabled/disabled, default workflow permissions, allowed-actions policy, SHA-pinning requirement, the selected-actions allow-list. |
| `security` | Secret scanning, push protection, Dependabot security updates/vulnerability alerts, CodeQL default setup. |
| `ruleset` | The "Protect main" branch-protection ruleset: PR requirements, required status checks, force-push/deletion blocking, bypass actors. |
| `npm` | (npm-library.json only) Anything explicitly out of scope for the baseline and for this tooling version (currently: npm Trusted Publisher binding -- reported, never automated). Absent entirely from `repository-baseline.json` and from any non-npm profile. |

## Generic vs profile-specific commands

`commands/provision-repository.ps1` is the baseline-safe, generic entry
point: `-Profile <name>` resolves to `profiles/<name>.json` through
`Get-EffectiveCdaProfile`, so `-Profile repository-baseline` and
`-Profile npm-library` both work, correctly, through the exact same code
path. `commands/provision-npm-library.ps1` remains as a convenience
wrapper hardcoded to `profiles/npm-library.json`, for existing callers
that never needed to think about profile selection — it is not
deprecated, just no longer the only way in.

There is deliberately no equivalent generic `assess-repository.ps1` yet
— `commands/assess-npm-library.ps1` already resolves its profile through
`Get-EffectiveCdaProfile` and could point `-ProfilePath` at
`repository-baseline.json` directly today, but a baseline-only ASSESSMENT
command (as opposed to provisioning) was not part of this tooling's
governing task and is not built speculatively here.

## Adding a new profile

A new repository kind (e.g. a future CDA Web Application Profile) gets its
own `profiles/<kind>.json` file with `"extends": "repository-baseline"`,
its own JSON Schema entry only if its shape differs meaningfully from
`repository-profile.schema.json`, and — per this repository's own founding
constraint — is **not** implemented speculatively here. A future **CDA
Tooling/CLI Profile** is a concrete, evidenced candidate (see
[../COMPLIANCE.md](../COMPLIANCE.md)) but is explicitly deferred until
real evidence exists from this repository's own baseline-only operation.

## Baseline hygiene vs profile capabilities

Not everything a profile-driven assessment reports is a *profile*
capability. `src/adopter/lib/Classification.psm1`'s
`Get-PagesHygieneClassification` / `Get-EnvironmentHygieneClassification`
implement CDA repository **baseline** rules (no orphan Pages
configuration, no orphan GitHub Environment) that apply to every CDA
repository regardless of its profile — see
[artifact-model.md](artifact-model.md), "Capability model" for how the
two categories combine into one compliance verdict.
