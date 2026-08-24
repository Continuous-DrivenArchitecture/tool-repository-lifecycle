#Requires -Version 5.1
<#
.SYNOPSIS
    CDA repository provisioner for the npm-library profile -- applies and
    verifies the GitHub-side configuration derived from CDA Repository
    Baseline v1 + CDA npm Library Profile v1 against an already-created
    repository (typically one created from a template implementing that
    profile).

.DESCRIPTION
    This tool configures GitHub, not files. It never clones, checks out,
    commits, pushes, creates a branch, or merges a PR -- repository
    *contents* are a template repository's job. This script's only job is
    repository settings, Actions permissions, security settings, and the
    "Protect main" ruleset.

    NEW-repository lifecycle path: template -> provision -> verify. See
    docs/lifecycle.md.

.PARAMETER Repository
    "Continuous-DrivenArchitecture/<repo-name>". Any other owner is refused.

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

.PARAMETER ProfilePath
    Defaults to profiles/npm-library.json at the repository root.

.EXAMPLE
    .\commands\provision-npm-library.ps1 -Repository Continuous-DrivenArchitecture/sandbox-npm-library -Mode Bootstrap -DryRun

.OUTPUTS
    Exit codes:
      0 = compliant / operation successful
      1 = drift found (Verify, or -DryRun with pending changes), or a real mutation failed
      2 = a prerequisite was not met (invalid repository, not authenticated,
          repository ineligible, or a Finalize/ruleset fail-safe condition)
      3 = state could not be determined (permission denied / API limitation /
          transport error) for at least one capability
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Repository,

    [Parameter(Mandatory)]
    [ValidateSet('Bootstrap', 'Finalize', 'Verify')]
    [string]$Mode,

    [switch]$DryRun,

    [switch]$AllowFork,

    [string]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably populated inside a default *parameter
# value* expression on Windows PowerShell 5.1 (only inside the script
# body), so the profile default is resolved here instead of in the param
# block above.
if ([string]::IsNullOrEmpty($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot '..\profiles\npm-library.json'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
# Import order matters -- see commands/provision-repository.ps1's own
# detailed comment on this exact sequence. The common leaf modules
# (RepositoryDiscovery/Validation/ReadOnlyGitHub) MUST be re-imported
# after Orchestration.psm1, or Invoke-Provisioning crashes immediately
# on its own first line (Test-RepositoryNameFormat) -- confirmed
# empirically, not assumed.
Import-Module (Join-Path $repoRoot 'src\common\profile\ProfileLoader.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\provisioner\lib\Provisioner.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\provisioner\lib\Orchestration.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\RepositoryDiscovery.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\repository\Validation.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\ReadOnlyGitHub.psm1') -Force

$profileResult = Get-EffectiveCdaProfile -Path $ProfilePath
if (-not $profileResult.Success) {
    Write-Error $profileResult.Error
    exit 2
}
$profileJson = $profileResult.Profile

Write-Host ""
Write-Host "CDA repository provisioner -- npm-library profile" -ForegroundColor Cyan
Write-Host "Repository : $Repository"
Write-Host "Mode       : $Mode"
Write-Host "DryRun     : $([bool]$DryRun)"
Write-Host "Profile    : $($profileJson.profileName) (extends $($profileJson.extends))"
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
