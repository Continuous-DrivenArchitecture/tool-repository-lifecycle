#Requires -Version 5.1
<#
.SYNOPSIS
    Executes an approved plan (approve-plan.ps1's output) against a live
    GitHub repository -- PRE-FLIGHT (zero mutations) -> mutation phase
    (skipped entirely under -DryRun) -> VERIFY. See README.md,
    "Lifecycle".

.DESCRIPTION
    This script NEVER re-classifies, discovers, or infers a change beyond
    exactly what approved-plan.json's operations[] array already contains
    with approved=true. If the plan's hash does not match its own content,
    if live state has drifted from the state fingerprint captured at
    assessment time, or if any BLOCKED/UNKNOWN operation was somehow
    marked approved, PRE-FLIGHT fails and the mutation phase never runs.

    -DryRun performs every PRE-FLIGHT check and every per-operation live
    precondition re-check (all read-only) and reports exactly which API
    call each approved operation WOULD trigger, with zero mutations.

    Without -DryRun, approved operations are executed in plan order,
    stopping at the first failure (no blind continuation -- GitHub has no
    cross-resource transaction). Every REQUIRES-MANUAL-CHANGE operation is
    reported as MANUAL_CHANGE_REQUIRED and skipped, never attempted.

    After execution, this script distinguishes two separate claims:
    "PLAN APPLIED SUCCESSFULLY" (every operation this plan approved was
    applied and read back as matching) and "FULL CDA COMPLIANCE" (a fresh,
    independent re-assessment shows zero remaining gaps against the full
    CDA target). A plan can satisfy the first and not the second.

.PARAMETER Plan
    Path to an approved-plan.json file produced by approve-plan.ps1.

.PARAMETER Repository
    "Continuous-DrivenArchitecture/<repo-name>". Must match the plan's own
    `repository` field -- a safety cross-check against applying a plan to
    the wrong target.

.PARAMETER DryRun
    Perform PRE-FLIGHT and precondition re-checks and report exactly what
    would be called, with zero mutations. Strongly recommended before
    ever running without this switch.

.PARAMETER ProfilePath
    Defaults to ../repository-provisioner/profiles/npm-library.json, same
    as assess-npm-library.ps1 -- needed for the CodeQL default-setup body
    and for the post-apply full re-assessment.

.PARAMETER OutputPath / JsonOutputPath
    Where to write apply-report.md / apply-report.json.

.EXAMPLE
    .\apply-plan.ps1 -Plan .\reports\adapter-xma-approved-plan.json -Repository Continuous-DrivenArchitecture/adapter-xma -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Plan,

    [Parameter(Mandatory)]
    [string]$Repository,

    [switch]$DryRun,

    [string]$ProfilePath,

    [string]$OutputPath,

    [string]$JsonOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot '..\profiles\npm-library.json'
}
$assessScriptPath = Join-Path $PSScriptRoot 'assess-npm-library.ps1'

# Import order matters here for the same reason documented in
# assess-npm-library.ps1: Discovery.psm1 nest-imports ReadOnlyGitHub.psm1
# as part of establishing its OWN exports, which unregisters
# ReadOnlyGitHub.psm1 as an independently visible top-level module. Approval
# .psm1 / Apply.psm1 / Verification.psm1 / MutationGitHub.psm1 do not nest-
# import anything, so their relative order does not matter -- but
# ReadOnlyGitHub.psm1 must be (re-)imported LAST so Invoke-ReadOnlyGitHub /
# Test-GhAuthenticated / Get-ReadOnlyGitHubPaged are visible at call time to
# Apply.psm1, Verification.psm1, and this script's own top-level code.
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\adopter\lib\Discovery.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\profile\ProfileLoader.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\adopter\lib\Approval.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\adopter\lib\Apply.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\adopter\lib\Verification.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\MutationGitHub.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\ReadOnlyGitHub.psm1') -Force

if (-not (Test-Path -LiteralPath $Plan)) {
    Write-Error "Approved plan file not found: $Plan"
    exit 2
}
$approvedPlan = $null
try {
    $approvedPlan = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Approved plan file is not valid JSON: $Plan`n$_"
    exit 2
}
foreach ($required in @('repository', 'profile', 'planHash', 'approvedAt', 'approvedBy', 'operations', 'stateFingerprint')) {
    if (-not ($approvedPlan.PSObject.Properties.Name -contains $required)) {
        Write-Error "Approved plan file is missing required field '$required' -- is this an approve-plan.ps1 output? $Plan"
        exit 2
    }
}

Write-Host "CDA repository adopter -- apply approved plan"
Write-Host "Plan file  : $Plan"
Write-Host "Repository : $Repository"
Write-Host "Mode       : $(if ($DryRun) { 'DRY RUN -- zero mutations will be performed' } else { 'APPLY -- approved operations will be executed' })"
Write-Host ""

Write-Host "Running PRE-FLIGHT (zero mutations)..."
$preflight = Invoke-Preflight -ApprovedPlan $approvedPlan -Repository $Repository

foreach ($c in $preflight.Checks) {
    $mark = if ($c.Passed) { 'PASS' } else { 'FAIL' }
    $line = "  [$mark] $($c.Name)"
    if (-not $c.Passed -and $c.Detail) { $line += " -- $($c.Detail)" }
    Write-Host $line
}
foreach ($oc in $preflight.OperationChecks) {
    $mark = if ($oc.Satisfied) { 'PASS' } else { 'FAIL' }
    Write-Host "  [$mark] precondition(s) for $($oc.Id)$(if (-not $oc.Satisfied) { ": $($oc.Reasons -join '; ')" })"
}
Write-Host ""

function New-ApplyReport {
    param($PreflightResult, $ExecResult, $Verification, [bool]$IsDryRun)

    $approvedOps = @($approvedPlan.operations | Where-Object { [bool]$_.approved })
    # @(...) wraps the WHOLE if/else: an empty array returned as a
    # branch's pipeline output (rather than assigned as a literal)
    # collapses on capture -- see Apply.psm1's matching comment for the
    # confirmed mechanism. Harmless here today only because this value
    # never crosses a typed function-parameter boundary before being
    # piped again; wrapped anyway so it stays safe if that ever changes.
    $execResults = @(if ($ExecResult) { @($ExecResult.Results) } else { @() })

    $summary = [ordered]@{
        applied         = @($execResults | Where-Object { $_.Status -eq 'APPLIED' }).Count
        wouldApply      = @($execResults | Where-Object { $_.Status -eq 'WOULD_APPLY' }).Count
        failed          = @($execResults | Where-Object { $_.Status -eq 'FAILED' }).Count
        notExecuted     = @($execResults | Where-Object { $_.Status -eq 'NOT_EXECUTED' }).Count
        manualChangeRequired = @($execResults | Where-Object { $_.Status -eq 'MANUAL_CHANGE_REQUIRED' }).Count
    }

    return [PSCustomObject]@{
        schemaVersion      = '1.0'
        repository        = "$($approvedPlan.repository)"
        approvedPlanHash   = "$($approvedPlan.planHash)"
        approvedBy         = "$($approvedPlan.approvedBy)"
        approvedAt         = "$($approvedPlan.approvedAt)"
        appliedAt          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        dryRun             = $IsDryRun
        preflightPassed    = $PreflightResult.Passed
        preflightChecks    = @($PreflightResult.Checks)
        operationsRequested = $approvedOps.Count
        operationsSummary  = $summary
        operations         = @($execResults | ForEach-Object {
                [PSCustomObject]@{
                    id         = $_.Id
                    capability = $_.Capability
                    status     = $_.Status
                    detail     = $_.Detail
                }
            })
        verification       = $Verification
        mutationsPerformed = @($execResults | Where-Object { $_.Status -eq 'APPLIED' } | ForEach-Object { "$($_.Id): $($_.Detail)" })
    }
}

if (-not $preflight.Passed) {
    Write-Host "PRE-FLIGHT FAILED -- the mutation phase will NOT run. No GitHub API call beyond the read-only checks above was made." -ForegroundColor Red
    $report = New-ApplyReport -PreflightResult $preflight -ExecResult $null -Verification $null -IsDryRun ([bool]$DryRun)

    if ([string]::IsNullOrEmpty($JsonOutputPath)) { $JsonOutputPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Plan)) 'apply-report.json' }
    ($report | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $JsonOutputPath -Encoding UTF8
    Write-Host "Report written: $JsonOutputPath"
    exit 1
}

Write-Host "PRE-FLIGHT PASSED." -ForegroundColor Green
Write-Host ""

$parts = $Repository -split '/', 2
$owner = $parts[0]
$repo = $parts[1]

$exec = Invoke-ApprovedPlan -ApprovedPlan $approvedPlan -Owner $owner -Repo $repo -ProfilePath $ProfilePath -DryRun:$DryRun

Write-Host ("{0,-45} {1,-16} {2,-22} {3}" -f 'Operation', 'Classification', 'Status', 'Detail')
foreach ($r in $exec.Results) {
    $op = @($approvedPlan.operations | Where-Object { "$($_.id)" -eq $r.Id })[0]
    Write-Host ("{0,-45} {1,-16} {2,-22} {3}" -f $r.Id, "$($op.classification)", $r.Status, $r.Detail)
}
Write-Host ""

$verification = $null
if (-not $DryRun) {
    Write-Host "Reading back applied operations..."
    $rulesetId = Get-ProtectMainRulesetId -StateFingerprint $approvedPlan.stateFingerprint
    # Only the fixed set of Protect-main SUB-FIELD ids (see
    # Get-RulesetOperationMutationSpec's own whitelist) are read back via
    # Test-RulesetOperationApplied -RulesetId $rulesetId -- that id is
    # specifically Protect main's. ruleset.protectMain (create) and any
    # other ruleset.* id (delete-by-name) go through Test-OperationApplied
    # instead, which resolves the correct ruleset itself. Routing every
    # ruleset.* id through Protect main's id here was a real bug found
    # during live sandbox integration testing (2026-08-23): it would have
    # silently checked the WRONG ruleset's read-back for e.g. deleting a
    # differently-named legacy ruleset.
    $protectMainSubFieldIds = @('ruleset.bypassActors', 'ruleset.allowedMergeMethods', 'ruleset.strictStatusChecks', 'ruleset.requiredStatusChecks')
    $readback = @()
    foreach ($r in @($exec.Results | Where-Object { $_.Status -eq 'APPLIED' })) {
        $op = @($approvedPlan.operations | Where-Object { "$($_.id)" -eq $r.Id })[0]
        $rb = if ("$($op.id)" -in $protectMainSubFieldIds -and $rulesetId) {
            Test-RulesetOperationApplied -Op $op -Owner $owner -Repo $repo -RulesetId $rulesetId
        }
        else {
            Test-OperationApplied -Op $op -Owner $owner -Repo $repo
        }
        $mark = if ($null -eq $rb.Matches) { 'UNVERIFIABLE' } elseif ($rb.Matches) { 'VERIFIED' } else { 'MISMATCH' }
        Write-Host ("  [$mark] $($op.id) -- observed: $($rb.Observed)")
        $readback += [PSCustomObject]@{ Id = "$($op.id)"; Observed = $rb.Observed; Matches = $rb.Matches }
    }

    $planApplied = (-not $exec.Stopped) -and (@($readback | Where-Object { $_.Matches -ne $true }).Count -eq 0) -and (@($exec.Results | Where-Object { $_.Status -eq 'FAILED' }).Count -eq 0)

    Write-Host ""
    Write-Host "Running full CDA re-assessment (independent, read-only)..."
    $fullCda = Invoke-FullCdaVerification -Repository $Repository -AssessScriptPath $assessScriptPath -ProfilePath $ProfilePath

    $verification = [PSCustomObject]@{ readBack = @($readback); planApplied = $planApplied; fullCdaCompliance = $fullCda }

    Write-Host ""
    Write-Host "PLAN APPLIED SUCCESSFULLY: $planApplied"
    if ($fullCda.Available) {
        Write-Host "FULL CDA COMPLIANCE: $($fullCda.FullyCompliant)"
        if (-not $fullCda.FullyCompliant) {
            Write-Host "Remaining gaps ($($fullCda.Gaps.Count)) -- NOT part of this plan, need their own future assessment/approval/apply cycle:"
            foreach ($g in $fullCda.Gaps) { Write-Host "  [$($g.Id)] $($g.Capability) ($($g.Classification))" }
        }
    }
    else {
        Write-Host "FULL CDA COMPLIANCE: could not be determined ($($fullCda.Error))"
    }
}
else {
    Write-Host "DRY RUN COMPLETE -- zero mutations were performed. Re-run without -DryRun only after reviewing the operations above." -ForegroundColor Yellow
}

$report = New-ApplyReport -PreflightResult $preflight -ExecResult $exec -Verification $verification -IsDryRun ([bool]$DryRun)

if ([string]::IsNullOrEmpty($OutputPath)) { $OutputPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Plan)) 'apply-report.md' }
if ([string]::IsNullOrEmpty($JsonOutputPath)) { $JsonOutputPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Plan)) 'apply-report.json' }

$sb = New-Object System.Text.StringBuilder
function Add([string]$line = '') { [void]$sb.AppendLine($line) }
Add "# CDA Repository Adopter -- Apply Report"
Add ""
Add "Repository: $($report.repository)"
Add "Approved plan hash: $($report.approvedPlanHash)"
Add "Approved by: $($report.approvedBy) at $($report.approvedAt)"
Add "Applied at: $($report.appliedAt)"
Add "Mode: $(if ($report.dryRun) { 'DRY RUN' } else { 'APPLY' })"
Add ""
Add "## Pre-flight"
Add ""
Add "Passed: $($report.preflightPassed)"
foreach ($c in $report.preflightChecks) { Add "- [$(if ($c.Passed) {'PASS'} else {'FAIL'})] $($c.Name)$(if (-not $c.Passed -and $c.Detail) { ": $($c.Detail)" })" }
Add ""
Add "## Operations"
Add ""
Add "| Id | Status | Detail |"
Add "|---|---|---|"
foreach ($op in $report.operations) { Add "| $($op.id) | $($op.status) | $($op.detail -replace '\|','/') |" }
Add ""
if ($report.verification) {
    Add "## Verification"
    Add ""
    Add "PLAN APPLIED SUCCESSFULLY: $($report.verification.planApplied)"
    if ($report.verification.fullCdaCompliance.Available) {
        Add "FULL CDA COMPLIANCE: $($report.verification.fullCdaCompliance.FullyCompliant)"
        if (-not $report.verification.fullCdaCompliance.FullyCompliant) {
            Add ""
            Add "Remaining gaps:"
            foreach ($g in $report.verification.fullCdaCompliance.Gaps) { Add "- [$($g.Id)] $($g.Capability) ($($g.Classification))" }
        }
    }
    else {
        Add "FULL CDA COMPLIANCE: could not be determined ($($report.verification.fullCdaCompliance.Error))"
    }
    Add ""
}
Add "## Mutations performed"
Add ""
if ($report.mutationsPerformed.Count -eq 0) { Add "NONE" } else { foreach ($m in $report.mutationsPerformed) { Add "- $m" } }
Add ""

($sb.ToString()) | Set-Content -LiteralPath $OutputPath -Encoding UTF8
($report | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $JsonOutputPath -Encoding UTF8

Write-Host ""
Write-Host "Reports written: $OutputPath / $JsonOutputPath"

if ($exec.Stopped) { exit 2 }
exit 0
