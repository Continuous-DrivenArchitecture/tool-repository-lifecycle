# Safety Model

This is the key document for understanding why this tooling is safe to
point at a real repository. Every property below is enforced in code and
checked by `tests/run-tests.ps1`, not just described here.

## Fail closed

Nothing in this repository infers compliance, safety, or absence from
missing or unreadable data. If a live read fails or a signal cannot be
determined, the result is `UNKNOWN` (adopter classification taxonomy) or
`Unknown`/`$null` (provisioner state / evidence results) — never silently
treated as compliant, absent, or safe. Concretely:

- A capability whose current state could not be read is `UNKNOWN`, never
  assumed to match the target.
- Baseline-hygiene orphan classification (`hygiene.pages`,
  `hygiene.environment.*`) requires *complete* evidence before it can ever
  report `REMOVE_CANDIDATE` — any single unreadable signal forces
  `UNKNOWN` instead, regardless of what the other signals show.
- Merge-reproducibility evidence (`src/adopter/lib/MergeReproducibility.psm1`)
  distinguishes `Reproducible = $true` / `$false` / `$null` (unknown) as
  three genuinely different states — `$null` is never coerced to either
  extreme.
- `Invoke-FullCdaVerification` reports `Available = $false,
  FullyCompliant = $null` (never `$true`) when the underlying
  re-assessment itself could not run.

## Read-only/mutation isolation

Every GitHub API call in this repository is either a GET (via
`src/common/github/ReadOnlyGitHub.psm1`) or a mutation (via
`src/common/github/MutationGitHub.psm1`). Nothing else can talk to
GitHub. `MutationGitHub.psm1` is imported by exactly two modules —
`src/adopter/lib/Apply.psm1` and `src/provisioner/lib/Orchestration.psm1`
— and by the two commands that explicitly perform a mutation
(`commands/apply-plan.ps1`, `commands/provision-npm-library.ps1`).
Every other file — both lifecycle paths' discovery/classification/
comparison code, and both `assess`/`approve` commands — can only read.

`tests/run-tests.ps1` enforces this structurally: it scans every
assess/discovery-only file's own source text for an `Import-Module ...
MutationGitHub.psm1` statement or a direct `Invoke-MutationGitHub` call,
and fails if it finds one. It also asserts `Invoke-ReadOnlyGitHub` has no
`-Method` or body-carrying parameter at all, and that `MutationGitHub.psm1`'s
`Invoke-MutationGitHub` has a *mandatory* `-Method` with no `GET` in its
allowed set — the isolation is a property of the function signatures
themselves, not just of who happens to call them today.

## Exact approved-plan execution

`apply-plan.ps1` never re-classifies, discovers, or infers a change beyond
exactly what the approved plan's `operations[]` array already contains
with `approved: true`. It cannot expand its own scope mid-run.

## Deterministic plan hash + tamper detection

See [artifact-model.md](artifact-model.md), "Plan hash contract" for the
exact field set. `apply-plan.ps1` recomputes the hash from the approved
plan's own `operations[]` and refuses to run if it does not match the
stored `planHash` — a hand-edited approved-plan file is rejected, not
silently trusted.

## Stale-plan rejection

An approved plan is a snapshot of live state at assessment time
(`stateFingerprint`). Before any mutation, `apply-plan.ps1`'s pre-flight
re-reads live state and compares it against that exact snapshot: default
branch name and HEAD SHA, every tracked ruleset's id + `updated_at`, every
tracked workflow/release-config/`package.json` SHA (resolved against the
*same* content branch the assessment used — never a possibly-stale
default branch), and, for `branch.delete.develop`, a full fresh
recomputation of branch-retirement evidence. If live state has moved in
any tracked dimension, pre-flight fails and the mutation phase never
runs — even under `-DryRun`, so the operator sees the staleness before
ever attempting a real run.

This re-check happens twice: once informationally before the mutation
phase even begins (`Invoke-Preflight`), and again, per-operation,
immediately before that specific operation executes
(`Test-OperationPreconditions`) — because state can drift *during* a
multi-operation apply run, not only between approval and apply.

## Destructive operations registry

`destructive: true` is an **independent safety property** — orthogonal to
classification. A `branch.delete.develop` operation can legitimately reach
`SAFE_CHANGE` classification (every precondition clean) and still be
`destructive: true`; a Pages/environment removal can be `REMOVE_CANDIDATE`
and destructive at the same time. `Approve-PlanOperations` checks the
`destructive` flag *in addition to* classification: `-ApproveSafeChanges`
never sweeps in a destructive operation, full stop, regardless of what its
classification says. Only an explicit, individually-named
`-ApproveOperation <id>` can approve one. This was a real regression found
during this tooling's own live validation (a destructive develop-deletion
that had legitimately reached `SAFE_CHANGE` was almost swept in by a bulk
approval) and is now a permanent, tested guard — see
`tests/run-tests.ps1`, sections 13/14/24/29.

Known destructive operation ids (see
[artifact-model.md](artifact-model.md), "Operation model" for the full
registry): `branch.delete.develop`, `secret.<NAME>`, `ruleset.<name>`
(bypass-actor clearing and non-Protect-main ruleset deletion),
`hygiene.pages`, `hygiene.environment.<name>`.

## Secret safety

No function in this repository ever reads a secret or variable *value* —
only names, and (for environment secrets/variables) update timestamps.
`Get-SecretClassification`'s own parameter set has no field that could
carry a value. A secret deletion operation's `Description`/`Detail` text
explicitly states the value was never read. This is checked by dedicated
tests (`tests/run-tests.ps1` sections 8 and 14: every operation's action
text and current/desired fields are scanned for a `value=`/`secret=`
pattern and must never match).

## Branch retirement evidence

Deleting a permanent branch (`develop`) is never approved on graph
divergence alone. `src/adopter/lib/Discovery.psm1`'s
`Get-BranchRetirementEvidence` + `Test-BranchRetirementSemantics`
distinguish:

- **Graph divergence** — the branch has commits main cannot reach, by
  commit-graph topology alone. Not sufficient evidence either way.
- **Unique content divergence** — whether any of those commits actually
  introduces a tree state not already represented in the target branch's
  history, established from real tree SHAs and live ancestry checks —
  never from commit subjects or naming conventions.
- **Merge reproducibility** (`MergeReproducibility.psm1`) — for a
  graph-exclusive merge commit whose own tree is genuinely new (as every
  three-way merge's tree structurally is), whether that tree is exactly
  reproducible via native Git plumbing (`git merge-tree --write-tree`)
  from parents already reachable from the target. A reproducible merge
  commit contributes **zero unique authored content**, even though its
  tree SHA never existed as a commit tree on the target branch.

Even when every exclusive commit is proven to introduce no unique
content (`SemanticEquivalenceProven = $true`), the deletion **never**
reaches unconditional `SAFE_CHANGE` — it is always at minimum
`REVIEW_REQUIRED`, destructive, and requires explicit individual
approval. Semantic equivalence removes the reason to say "no" outright;
it never removes the requirement to say "yes" explicitly.

## Read-back verification

After a real (non-`-DryRun`) apply, every operation that reached
`APPLIED` is read back live and compared against its desired value
(`Verification.psm1`'s `Test-OperationApplied` /
`Test-RulesetOperationApplied`). The result is `Matches: $true` /
`$false` / `$null` — `$null` means "no read-back mapping exists for this
operation id, or the live re-read itself failed," and is reported as
`UNVERIFIABLE`, never silently counted as success. `apply-plan.ps1`'s own
"PLAN APPLIED SUCCESSFULLY" claim requires every read-back to be
`$true` — a single `UNVERIFIABLE` or `MISMATCH` is enough to make that
claim `false`.

This is deliberately a **separate claim** from "FULL CDA COMPLIANCE"
(`Invoke-FullCdaVerification`, a fresh full re-assessment): a plan can
apply everything it approved and still leave real gaps that were never
part of that plan (a `BLOCKED` item, a manual-change item, anything
outside this batch's scope).

## Stop-on-first-failure, no automatic rollback

`Invoke-ApprovedPlan` executes approved operations in plan order and
stops at the first `FAILED` result — every remaining operation is
reported `NOT_EXECUTED`, never attempted. GitHub has no cross-resource
transaction to roll back into, so this repository does not attempt to
undo a partially-applied plan; see [lifecycle.md](lifecycle.md), "No
automatic rollback".

## Audit artifacts

Every command that produces a machine-readable result includes
`schemaVersion` (see [artifact-model.md](artifact-model.md)) and, where
relevant, a full `preflightChecks`/`operations`/`verification` trail.
None of this tooling's own production evidence is committed to this
repository — see [artifact-model.md](artifact-model.md), "Report output
location".
