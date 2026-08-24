# Contributing

This repository is PowerShell/GitHub governance tooling, not an npm
library — there is no `package.json`, no `npm install`, no published
package. Contributions are plain PowerShell scripts/modules, JSON
schemas, and Markdown documentation.

## Branching and pull requests

- Short-lived branches off `main`, one topic per branch.
- Open a pull request against `main`; describe what changed and why.
- All tests (`tests/run-tests.ps1`) must pass before merge — see
  "Running the tests" below.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, ...) — this is informative
  today (no release automation reads it yet), but keeps history consistent
  with every other CDA repository.

## Running the tests

```powershell
powershell.exe -NoProfile -File .\tests\run-tests.ps1
```

Offline, no `gh` call, no network access. If you add a capability,
operation id, or classification path, add a corresponding assertion —
see [docs/artifact-model.md](docs/artifact-model.md) for the taxonomy and
operation-id conventions your addition should follow.

## Adding or changing a capability

1. Read [docs/safety-model.md](docs/safety-model.md) first — in
   particular, "Fail closed" and "Destructive operations registry."
   Nothing new should silently treat missing evidence as safe, and any
   new capability whose mutation is irreversible or hard-to-reverse must
   be marked `destructive: true` independent of its classification.
2. Discovery (read-only) and classification (pure decision logic) stay
   separate — see `src/adopter/lib/Discovery.psm1` vs
   `src/adopter/lib/Classification.psm1`, or the equivalent split in
   `src/provisioner/lib/Provisioner.psm1`. A classification function
   never makes a network call; a discovery function never decides
   COMPLIANT/REVIEW_REQUIRED/etc.
3. If the capability needs a mutation, add its mapping in
   `src/adopter/lib/Apply.psm1` (`Get-OperationMutationSpec` or
   `Get-RulesetOperationMutationSpec`) or
   `src/provisioner/lib/Orchestration.psm1` — never invent an untested
   API call shape; confirm the real endpoint/body first.
4. Add a read-back mapping in `src/adopter/lib/Verification.psm1`'s
   `Test-OperationApplied` if the mutation is verifiable live.
5. Update [schemas/](schemas/) if the artifact shape changed, and add or
   update the corresponding synthetic fixture in `tests/fixtures/` or
   inline in `tests/run-tests.ps1`.
6. Never test against a real, named production repository. Use synthetic
   fixture data or a hand-built mock (`$script:MockRoutes` pattern already
   used throughout `tests/run-tests.ps1`).

## Extracting to `src/common/`

Before moving logic from one lifecycle path into `src/common/`, confirm
it is *genuinely* duplicated (not just similar-looking) and that
extracting it doesn't blur the read-only/mutation boundary — see
[docs/architecture.md](docs/architecture.md), "Common core" for examples
of what was and wasn't extracted, and why.

## PowerShell compatibility

Every script/module targets Windows PowerShell 5.1 as the floor. Known,
non-obvious 5.1 behaviors worth remembering when editing this codebase:

- An **empty array returned as a function's output can collapse to
  `$null`** when captured by a plain `$x = Function-Call` assignment, and
  a **single-element array can collapse to a bare scalar**. Wrap a
  captured result in `@(...)` whenever you will call `.Count` on it or
  pipe it into something that dereferences an element.
- `foreach ($x in $null)` iterates zero times (safe); piping `$null`
  into `Where-Object`/`ForEach-Object` invokes the block **once** with
  `$_ = $null` (not safe under `Set-StrictMode` if the block dereferences
  a property on `$_`).
- A native command's (e.g. `gh`, `git`) routine stderr output becomes a
  terminating `NativeCommandError` under `$ErrorActionPreference = 'Stop'`
  when captured via `2>&1`, even for an expected, already-handled
  nonzero exit. Wrap the one call in a temporary
  `$ErrorActionPreference = 'Continue'` / restore-in-`finally` block —
  see `Invoke-ReadOnlyGitHub`/`Invoke-MutationGitHub` for the pattern.
- `$PSScriptRoot` is not populated inside a default *parameter value*
  expression in 5.1 — resolve path defaults in the script body instead.
- A variable reference immediately followed by a colon inside a
  double-quoted string (e.g. `"$Path: some text"`) is parsed as a
  drive-qualified variable reference and throws a parse error — use
  `"${Path}: some text"` instead.
- **A module that imports another module nested within its own top
  ("nest-imports") makes that dependency's functions visible to ITS OWN
  code, but re-registers that dependency's top-level/global visibility
  each time the nesting import runs.** When several modules in an import
  chain each nest-import the same shared module (as several of
  `src/common/`'s modules do), the LAST nested import to run determines
  what is globally visible afterward — see the exact, worked-out import
  order and reasoning documented at the top of `tests/run-tests.ps1` and
  in each command's own header comment; get this wrong and a
  previously-working `Get-Command` lookup silently returns nothing.
