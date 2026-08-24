#Requires -Version 5.1
<#
.SYNOPSIS
    Generic, profile-driven CDA repository provisioner -- applies and
    verifies the GitHub-side configuration derived from whichever CDA
    profile is named, against an already-created repository.

.DESCRIPTION
    This is the baseline-safe, profile-agnostic entry point the
    provisioner lifecycle path was missing: commands/provision-npm-library.ps1
    is hardcoded to profiles/npm-library.json (CDA Repository Baseline v1 +
    CDA npm Library Profile v1), which is wrong for a repository that is
    not an npm library -- see profiles/repository-baseline.json and
    docs/profiles.md, "Baseline vs profile" for why a repository like this
    tooling's own repository needs the baseline ALONE, with no profile on
    top of it.

    Resolves -Profile <name> to profiles/<name>.json and loads it through
    Get-EffectiveCdaProfile (src/common/profile/ProfileLoader.psm1), which
    composes a profile with whatever it `extends` -- so `-Profile
    npm-library` here produces the exact same effective desired state as
    commands/provision-npm-library.ps1 always has, and `-Profile
    repository-baseline` produces the baseline ALONE, with no npm-specific
    field anywhere in the result.

    This tool configures GitHub, not files. It never clones, checks out,
    commits, pushes, creates a branch, or merges a PR.

    NEW-repository lifecycle path: template -> provision -> verify. See
    docs/lifecycle.md.

.PARAMETER Repository
    "Continuous-DrivenArchitecture/<repo-name>". Any other owner is refused.

.PARAMETER Profile
    Profile name, resolved to profiles/<name>.json (e.g. "repository-baseline"
    or "npm-library"). Mandatory -- there is no default, so a caller can
    never accidentally provision the wrong profile by omission.

.PARAMETER Mode
    Bootstrap  - apply everything possible except the ci-required status
                 check if it has no execution evidence yet.
    Finalize   - verify ci-required has real execution evidence, then wire
                 it into the "Protect main" ruleset as a required check.
                 Fail-safe (no ruleset change at all) if there's no evidence.
    Verify     - read-only. Compares desired vs. actual state and reports
                 PASS / DRIFT / NOT AVAILABLE / UNKNOWN per capability.
                 Never mutates anything.

.PARAMETER DryRun
    Show CURRENT / DESIRED / ACTION for every capability without calling
    any mutating GitHub API. Always safe to run.

.PARAMETER AllowFork
    Explicit override to allow provisioning a fork. Refused by default.

.EXAMPLE
    .\commands\provision-repository.ps1 -Repository Continuous-DrivenArchitecture/tool-repository-lifecycle -Profile repository-baseline -Mode Bootstrap -DryRun

.OUTPUTS
    Exit codes:
      0 = compliant / operation successful
      1 = drift found (Verify, or -DryRun with pending changes), or a real mutation failed
      2 = a prerequisite was not met (invalid repository, not authenticated,
          repository ineligible, profile not found, or a Finalize/ruleset
          fail-safe condition)
      3 = state could not be determined (permission denied / API limitation /
          transport error) for at least one capability
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Repository,

    [Parameter(Mandatory)]
    [string]$Profile,

    [Parameter(Mandatory)]
    [ValidateSet('Bootstrap', 'Finalize', 'Verify')]
    [string]$Mode,

    [switch]$DryRun,

    [switch]$AllowFork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$ProfilePath = Join-Path $repoRoot "profiles\$Profile.json"

# Import order matters (same lesson as commands/assess-npm-library.ps1's
# own comment, one level deeper): Orchestration.psm1 nest-imports
# Provisioner.psm1, which itself nest-imports RepositoryDiscovery.psm1
# and Validation.psm1 (which in turn nest-imports ReadOnlyGitHub.psm1
# again) -- so by the time Orchestration.psm1 finishes importing,
# Test-RepositoryNameFormat/Test-GhAuthenticated/Test-RepositoryEligibility/
# Get-RepositoryLanguages (all called directly by Invoke-Provisioning) are
# NOT resolvable at this script's top level -- confirmed empirically: a
# fresh run crashed on Invoke-Provisioning's very first line
# (Test-RepositoryNameFormat) with CommandNotFoundException. Re-importing
# the common leaf modules ONE more time, last, restores them (this does
# NOT need to also re-import Provisioner.psm1 itself: Orchestration.psm1's
# own internal calls to Provisioner.psm1's pure functions, e.g.
# New-PlanItem, resolve through Orchestration.psm1's OWN private nested
# binding to Provisioner.psm1, unaffected by what happens to the global
# table afterward -- only the further-nested grandchild modules' exports
# needed restoring here).
Import-Module (Join-Path $repoRoot 'src\common\profile\ProfileLoader.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\provisioner\lib\Provisioner.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\provisioner\lib\Orchestration.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\RepositoryDiscovery.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\repository\Validation.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\ReadOnlyGitHub.psm1') -Force

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    Write-Error "Profile '$Profile' not found (looked for $ProfilePath). Available profiles: $((Get-ChildItem -Path (Join-Path $repoRoot 'profiles') -Filter '*.json' | ForEach-Object { $_.BaseName }) -join ', ')"
    exit 2
}

$profileResult = Get-EffectiveCdaProfile -Path $ProfilePath
if (-not $profileResult.Success) {
    Write-Error $profileResult.Error
    exit 2
}
$profileJson = $profileResult.Profile

Write-Host ""
Write-Host "CDA repository provisioner -- generic entry point" -ForegroundColor Cyan
Write-Host "Repository : $Repository"
Write-Host "Profile    : $Profile ($($profileJson.profileName))$(if ($profileResult.Extended) { " extends $($profileResult.BaseProfileName)" })"
Write-Host "Mode       : $Mode"
Write-Host "DryRun     : $([bool]$DryRun)"
Write-Host ""

if ($Mode -in @('Bootstrap', 'Finalize') -and -not $DryRun) {
    Write-Host "This run WILL modify GitHub configuration for $Repository." -ForegroundColor Yellow
    Write-Host "(Repository contents are never touched -- this tool only configures GitHub settings.)" -ForegroundColor Yellow
    Write-Host ""
}

$outcome = Invoke-Provisioning -Repository $Repository -Mode $Mode -DryRun ([bool]$DryRun) -CdaProfile $profileJson -AllowFork:$AllowFork

if ($outcome.Blocked) {
    Write-Host "BLOCKED: $($outcome.BlockedReason)" -ForegroundColor Red
    exit $outcome.ExitCode
}

Format-PlanTable -Plan $outcome.Plan | Write-Host

$failSafe = $outcome.Plan | Where-Object { $_.Action -eq 'FAIL_SAFE' }
if ($failSafe) {
    Write-Host ""
    foreach ($item in $failSafe) {
        Write-Host "FAIL SAFE -- $($item.Capability): $($item.Notes)" -ForegroundColor Yellow
    }
}

$conflicts = $outcome.Plan | Where-Object { $_.Action -eq 'POLICY_CONFLICT' }
if ($conflicts) {
    Write-Host ""
    foreach ($item in $conflicts) {
        Write-Host "POLICY CONFLICT -- $($item.Capability): $($item.Notes)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Exit code: $($outcome.ExitCode)"
exit $outcome.ExitCode
