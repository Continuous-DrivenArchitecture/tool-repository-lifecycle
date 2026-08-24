# Artifact Model

## Versioned artifacts

Six artifact concepts exist across the two lifecycle paths. Every
machine-readable one carries a top-level `"schemaVersion": "1.0"` field.
None of these schemas describe a field this tooling doesn't actually
produce today — see each schema file's own description for exactly which
implementation it documents.

| Artifact | Produced by | Schema | Persisted JSON? |
|---|---|---|---|
| RepositoryProfile | (hand-authored) | [`schemas/repository-profile.schema.json`](../schemas/repository-profile.schema.json) | `profiles/*.json` |
| Assessment | `commands/assess-npm-library.ps1` | [`schemas/assessment.schema.json`](../schemas/assessment.schema.json) | via `-JsonOutputPath` |
| AdoptionPlan | embedded in an Assessment's `plan` field | [`schemas/adoption-plan.schema.json`](../schemas/adoption-plan.schema.json) | embedded, or standalone |
| ApprovedPlan | `commands/approve-plan.ps1` | [`schemas/approved-plan.schema.json`](../schemas/approved-plan.schema.json) | via `-OutputPath` |
| ApplyReport | `commands/apply-plan.ps1` | [`schemas/apply-report.schema.json`](../schemas/apply-report.schema.json) | via `-OutputPath`/`-JsonOutputPath` |
| ComplianceReport | — | (none yet; see below) | — |

**Provisioning has no persisted JSON artifact today.** `provision-npm-library.ps1`
prints a formatted plan table to the console and exits with a status
code; it does not currently accept a `-JsonOutputPath`. This is stated
here rather than left implicit, per this repository's own rule against
inventing artifact fields (or artifacts) that don't exist in the real
implementation. Adding one is a legitimate future extension, not assumed
here.

**ComplianceReport** exists conceptually (a repository's final,
point-in-time compliance record) but has no dedicated schema in this
repository yet, and no command produces one automatically — it was, in
the source engagement this tooling formalizes, a hand-assembled summary
of a final Assessment plus release-identity/audit-trail facts. A future,
explicit piece of work could formalize `commands/report-compliance.ps1`
and a matching schema; this repository does not build it speculatively.

## Backward compatibility

`schemaVersion: "1.0"` is the first version; nothing has changed shape
since. If a future change needs to break an existing field's meaning,
the convention going forward is: bump to the next minor/major version,
document the change in this file, and keep the previous version's schema
file for anything that still needs to validate old artifacts — never
silently repurpose a field.

## Plan hash contract

`Get-PlanHash` (`src/adopter/lib/Approval.psm1`) computes a deterministic
SHA-256 hex digest over a canonical JSON projection of exactly:

```
{ repository, profile, operations: [ { id, capability, classification, current, desired, dependencies (sorted) }, ... ] }
```

**Included:** operation id, capability name, classification, current
value, desired value, and the sorted dependency-description list.
**Excluded, deliberately:** `rationale` text, the `approved` flag, any
timestamp, `phase`/`phaseName`, `requiresManualChange`, `destructive`,
and `action` text. None of the excluded fields represent a real change to
*what would be mutated* — including them would make the hash brittle to
re-wording or re-phasing rather than meaningful to content.

Canonicalization (`Get-CanonicalJsonText`) is hand-rolled rather than
relying on `ConvertTo-Json`'s property ordering (not guaranteed stable
across PowerShell versions): object keys are sorted ordinally at every
level; array element order is preserved (operation order reflects phase
sequencing and is semantically meaningful — never reordered).

Guaranteed properties, all covered by `tests/run-tests.ps1` section 12:

- **Same semantic plan → same hash**, independent of how many times the
  operations array is independently re-derived from the same assessment.
- **A changed operation (`desired`, `classification`, ...) → different
  hash.**
- **A changed dependency list → different hash** (dependencies are part
  of the hashed projection).
- **Formatting-only differences (property order, whitespace) → same
  hash**, by construction of the canonicalizer — proven by round-tripping
  an approved plan through JSON serialization and re-validating its hash.
- **Tamper detection:** `Test-ApprovedPlanHash` recomputes the hash from
  an approved plan's own `operations[]` and compares it to the stored
  `planHash`; a hand-edited field (even one not in the hashed projection,
  like `classification`, since that IS included) invalidates the plan.

## Operation model

Every actionable capability has a stable, deterministic operation id
(`Get-StableOperationId`, `src/adopter/lib/Classification.psm1`), derived
from its capability text so the same capability always yields the same
id — this is what lets an approved plan reference an operation
unambiguously and lets `Apply.psm1` match an approved operation back to
its mutation mapping.

| Id prefix | Scope | Read method | Mutation method | Classification(s) seen | Destructive | Explicit approval required | Read-back |
|---|---|---|---|---|---|---|---|
| `repo.*` (`defaultBranch`, `deleteBranchOnMerge`, `allowSquashMerge`, `allowMergeCommit`, `allowRebaseMerge`, `allowAutoMerge`) | Repository settings | `GET repos/{o}/{r}` | `PATCH repos/{o}/{r}` | COMPLIANT / SAFE_CHANGE / REVIEW_REQUIRED | No | Only if REVIEW_REQUIRED | Yes (field compare) |
| `actions.enabled`, `actions.allowedActionsPolicy`, `actions.shaPinningRequired` | Actions permissions | `GET .../actions/permissions` | `PUT .../actions/permissions` | COMPLIANT / SAFE_CHANGE / REVIEW_REQUIRED / NOT_AVAILABLE | No | If REVIEW_REQUIRED | Yes |
| `actions.defaultWorkflowPermissions` | Workflow default token permissions | `GET .../actions/permissions/workflow` | `PUT .../actions/permissions/workflow` | Usually REVIEW_REQUIRED (tightening can break an undeclared-permission step) | No | Yes | Yes |
| `actions.selectedActionsAllowList` | Selected-actions allow-list | `GET .../actions/permissions/selected-actions` + workflow scan | `PUT .../actions/permissions/selected-actions` | REVIEW_REQUIRED / UNKNOWN | No | Yes | — |
| `security.secretScanning`, `security.secretScanningPushProtection`, `security.dependabotSecurityUpdates`, `security.vulnerabilityAlerts` | Security & analysis | `GET repos/{o}/{r}` / `GET .../vulnerability-alerts` | `PATCH repos/{o}/{r}` / `PUT`\|`DELETE .../vulnerability-alerts` | COMPLIANT / SAFE_CHANGE | No | No (safe-sweepable) | Yes |
| `security.codeQL` | CodeQL default setup | `GET .../code-scanning/default-setup` | `PATCH .../code-scanning/default-setup` | COMPLIANT / SAFE_CHANGE / NOT_AVAILABLE | No | No | Yes |
| `ci.requiredCheckEvidence` | Named check-run execution evidence | `GET .../commits/{ref}/check-runs` | *(none — informational only)* | COMPLIANT / NOT_AVAILABLE | No | N/A | N/A |
| `ruleset.protectMain` | Create the "Protect main" ruleset | `GET .../rulesets`, detail | `POST .../rulesets` | REVIEW_REQUIRED | No (creation, not removal) | Yes | Yes (name+enforcement) |
| `ruleset.bypassActors`, `ruleset.allowedMergeMethods`, `ruleset.strictStatusChecks`, `ruleset.requiredStatusChecks` | "Protect main" sub-fields | `GET .../rulesets/{id}` | `PUT .../rulesets/{id}` | COMPLIANT / REVIEW_REQUIRED / KEEP_STRONGER | `bypassActors` clearing: yes | Yes | Yes |
| `ruleset.<slug>` (any other ruleset name) | A ruleset not matching the profile's target name | `GET .../rulesets/{id}` | `DELETE .../rulesets/{id}` | REVIEW_REQUIRED / BLOCKED (if 2+ match "Protect main") | Yes | Yes | Yes (absence) |
| `branch.delete.develop` | Permanent-branch retirement | Branch/compare/commit/tree reads + merge-reproducibility evidence | `DELETE .../git/refs/heads/develop` | BLOCKED / REVIEW_REQUIRED / (never unconditional) SAFE_CHANGE | **Always yes** | **Always yes, never `-ApproveSafeChanges`** | Yes (absence) |
| `secret.<NAME>` | Repository secret | `GET .../actions/secrets` (names only) | `DELETE .../actions/secrets/{name}` | REVIEW_REQUIRED / REMOVE_CANDIDATE | Yes | Yes | Yes (absence) |
| `dependabot.<slug>` | `dependabot.yml` semantics | Workflow/config text scan | *(none — file edit)* | REVIEW_REQUIRED, `requiresManualChange` | No | Yes | N/A |
| `release.<slug>` | Release-architecture migration checklist | Workflow/config text scan | *(none — file edit)* | REVIEW_REQUIRED, `requiresManualChange` | No | Yes | N/A |
| `hygiene.pages` | GitHub Pages configuration | `GET .../pages`, `.../pages/builds`, live URL probe, workflow scan | `DELETE .../pages` | COMPLIANT / REVIEW_REQUIRED / REMOVE_CANDIDATE / UNKNOWN | Yes | Yes | Yes (absence) |
| `hygiene.environment.<name>` | A GitHub Environment (only ever `github-pages` in the current mutation mapping — see below) | `GET .../environments/{name}`, deployments, secrets/variables metadata (names only) | `DELETE .../environments/{name}` | COMPLIANT / REVIEW_REQUIRED / REMOVE_CANDIDATE / UNKNOWN | Yes | Yes | Yes (absence) |

No operation id in this table is speculative — every one is generated by
a real classification function and has a real (or explicitly-`Defined =
$false`, never-guessed) mutation mapping in `Apply.psm1` /
`Orchestration.psm1`.

### `hygiene.environment.*` is intentionally narrow

Per this repository's own safety constraint ("never generalize arbitrary
environment deletion recklessly"), `Apply.psm1`'s mutation mapping for
`hygiene.environment.*` re-derives the target environment name from the
operation's own capability text and **refuses** to define a mutation for
any name other than `github-pages` — even though the *classification*
function (`Get-EnvironmentHygieneClassification`) is written generically
and could, in principle, classify any environment. This is a deliberate,
tested asymmetry: the read/classify layer stays general; the mutate layer
stays hard-restricted.

## Capability model

Every classified row carries a `Category`: `Profile` (the npm-library
profile's own target-state capabilities) or `BaselineHygiene` (orphan
Pages/environment cleanup — a CDA repository *baseline* rule, independent
of any profile; see [profiles.md](profiles.md)). `Get-FullCdaComplianceResult`
(`src/adopter/lib/AdoptionPlan.psm1`) computes the corrected compliance
formula:

```
FullCdaCompliance =
      ProfileCompliance
  AND BaselineHygieneCompliance
  AND no BLOCKED capability
  AND no UNKNOWN mandatory capability
  AND no unresolved mandatory REVIEW_REQUIRED capability
  AND no unresolved mandatory REMOVE_CANDIDATE capability
```

This is never inferred from the profile-row count alone — a repository
whose 24 profile capabilities all read `COMPLIANT` but which still has an
orphaned Pages configuration reports `PARTIAL`, not `PASS`. `tests/run-tests.ps1`
section 24 includes a dedicated regression guard for exactly this case.

## Classification model

The fixed taxonomy (`Get-AdopterClassificationTaxonomy`):

```
COMPLIANT | SAFE_CHANGE | REVIEW_REQUIRED | BLOCKED |
KEEP_STRONGER | REMOVE_CANDIDATE | NOT_AVAILABLE | UNKNOWN
```

**Precedence when multiple conditions could apply** (see
`Get-DevelopDeletionClassification` and `Get-PagesHygieneClassification`/
`Get-EnvironmentHygieneClassification` for the canonical examples):

1. `BLOCKED` wins over everything — an unproven, potentially-destructive
   state is never downgraded to a lesser concern.
2. `UNKNOWN` (incomplete evidence) is checked before any positive
   classification is attempted — never overridden by a partial signal.
3. `REVIEW_REQUIRED` wins over `SAFE_CHANGE` — if *any* reviewable
   condition holds (an open PR, a workflow reference, ambiguous evidence,
   operational configuration on an otherwise-orphaned resource), the
   overall row is `REVIEW_REQUIRED`, even if every other condition looks
   clean.
4. `SAFE_CHANGE` (or `COMPLIANT`/`REMOVE_CANDIDATE` for hygiene rows) is
   only reached when every single condition is independently, positively
   satisfied.

**Fail-safe principle:** `UNKNOWN` never implicitly becomes `absent` or
`compliant`. A capability whose current state could not be read stays
`UNKNOWN` through the entire pipeline — it cannot be approved
(`Test-OperationApprovable` explicitly rejects it), and
`FullCdaComplianceResult` treats any `UNKNOWN` row as blocking (`Result =
'BLOCKED'`, never `'PASS'`).

## Report output location

Nothing in `commands/` defaults to writing inside a source-controlled
folder of this repository. `-OutputPath`/`-JsonOutputPath` are always
explicit parameters; the conventional default when running these
commands locally is `./reports/`, which is gitignored (see
[`.gitignore`](../.gitignore)) — a real assessment against a real
repository is operational evidence, not source code, and is never
committed here. `tests/fixtures/` holds the sanitized, entirely synthetic
examples the test suite itself constructs and validates against the
schemas in this document.
