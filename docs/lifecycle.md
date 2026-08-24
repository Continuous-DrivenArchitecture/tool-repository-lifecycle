# Lifecycle

Two paths, chosen by whether the target repository already exists.
**Provisioning != Adoption** — see [architecture.md](architecture.md) for
why these stay separate models rather than one unified "converge this
repository" operation.

All examples below use a synthetic repository name
(`Continuous-DrivenArchitecture/example-npm-library`). Substitute a real
repository you have `gh` access to; nothing here requires access to any
private or production evidence.

## NEW repository: template → provision → verify

```
1. Create a repository from a template implementing the target profile
   ("Use this template" on GitHub, or an equivalent generator).
2. Customize repository-specific placeholders (package name, description,
   URLs) -- this is template-repository work, out of scope here.
3. Bootstrap, read-only first:
   .\commands\provision-npm-library.ps1 `
     -Repository Continuous-DrivenArchitecture/example-npm-library `
     -Mode Bootstrap -DryRun
4. Bootstrap for real:
   .\commands\provision-npm-library.ps1 `
     -Repository Continuous-DrivenArchitecture/example-npm-library `
     -Mode Bootstrap
5. Open and merge the repository's first real pull request -- this is
   what gives the profile's required status check (e.g. "ci-required")
   its first execution evidence. Bootstrap deliberately does NOT wire a
   required check into branch protection until it has run at least once;
   requiring a check nobody has ever seen run would lock the repository.
6. Finalize, read-only first:
   .\commands\provision-npm-library.ps1 `
     -Repository Continuous-DrivenArchitecture/example-npm-library `
     -Mode Finalize -DryRun
7. Finalize for real (wires the required check into branch protection):
   .\commands\provision-npm-library.ps1 `
     -Repository Continuous-DrivenArchitecture/example-npm-library `
     -Mode Finalize
8. Confirm, read-only, never mutates:
   .\commands\provision-npm-library.ps1 `
     -Repository Continuous-DrivenArchitecture/example-npm-library `
     -Mode Verify
9. Configure anything explicitly out of scope for this tooling (e.g. an
   npm Trusted Publisher binding) -- reported as "EXTERNAL SETUP REQUIRED",
   never silently skipped.
```

`-Mode Verify` and `-DryRun` never call a mutating endpoint under any
mode — safe to run against any repository at any time.

## EXISTING repository: assess → plan → approve → apply → verify

```
1. Fresh, read-only assessment (never reuses a prior run's evidence):
   .\commands\assess-npm-library.ps1 `
     -Repository Continuous-DrivenArchitecture/example-npm-library `
     -OutputPath .\reports\assessment.md `
     -JsonOutputPath .\reports\assessment.json

2. Read the report. Every capability is classified COMPLIANT /
   SAFE_CHANGE / REVIEW_REQUIRED / BLOCKED / KEEP_STRONGER /
   REMOVE_CANDIDATE / NOT_AVAILABLE / UNKNOWN -- see docs/safety-model.md,
   "Classification model".

3. Approve exactly what you intend to change -- nothing is approved by
   default:
   .\commands\approve-plan.ps1 `
     -Plan .\reports\assessment.json `
     -ApproveSafeChanges `
     -ApproveOperation ruleset.bypassActors `
     -OutputPath .\reports\approved-plan.json

   -ApproveSafeChanges bulk-approves non-destructive SAFE_CHANGE items
   only. Every REVIEW_REQUIRED, REMOVE_CANDIDATE, or DESTRUCTIVE operation
   (regardless of classification) requires its own explicit
   -ApproveOperation <id> -- see docs/safety-model.md, "Destructive
   operations registry".

4. Dry-run the approved plan (zero mutations, full pre-flight):
   .\commands\apply-plan.ps1 `
     -Plan .\reports\approved-plan.json `
     -Repository Continuous-DrivenArchitecture/example-npm-library `
     -DryRun

5. Apply for real:
   .\commands\apply-plan.ps1 `
     -Plan .\reports\approved-plan.json `
     -Repository Continuous-DrivenArchitecture/example-npm-library

6. The apply report distinguishes two separate claims, never conflated:
   "PLAN APPLIED SUCCESSFULLY" (did every approved operation apply and
   read back as matching) and "FULL CDA COMPLIANCE" (a fresh, independent
   full re-assessment shows zero remaining gaps). A plan can satisfy the
   first and not the second -- there may be REVIEW_REQUIRED or manual-
   change items this particular plan never approved.

7. Repeat from step 1 for the next batch of changes. Each assessment is
   independent and fresh; nothing is cached or reused across runs.
```

### Pre-flight and stale-plan protection

Every `apply-plan.ps1` run (including `-DryRun`) re-reads live state and
compares it against the exact snapshot the plan was approved against
(`stateFingerprint`). If anything relevant has moved — the default branch
SHA, a ruleset's `updated_at`, a workflow file's SHA, or (for destructive
branch-retirement operations) the underlying tree-level evidence itself —
pre-flight fails closed and the mutation phase never runs. See
[safety-model.md](safety-model.md), "Stale-plan rejection", and
[artifact-model.md](artifact-model.md), "Plan hash contract".

### No automatic rollback (v1)

If an approved plan's execution fails partway through, `apply-plan.ps1`
stops immediately — remaining operations are reported `NOT_EXECUTED`,
never attempted. This repository does not attempt to undo what already
succeeded. Re-run assessment, review what actually changed, and build a
new plan for what's left.

### Manual repository-file changes

Some capabilities represent a repository *file* change (a workflow edit,
a `.releaserc.json` edit, a `dependabot.yml` edit) rather than a GitHub
setting. These are always marked `requiresManualChange: true` and
`apply-plan.ps1` reports them as `MANUAL_CHANGE_REQUIRED`, never attempts
them — make the change via a normal pull request, merge it, then re-run
assessment to confirm convergence.
