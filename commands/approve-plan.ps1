#Requires -Version 5.1
<#
.SYNOPSIS
    Turns a read-only adoption assessment (assess-npm-library.ps1's JSON
    output) into an immutable, explicitly approved plan. Makes NO GitHub
    API call of any kind -- see README.md, "Lifecycle".

.DESCRIPTION
    This is the HUMAN APPROVAL step, strictly separate from both
    assessment (assess-npm-library.ps1) and execution (apply-plan.ps1).
    It never re-classifies a capability, never discovers a new
    recommendation, and never approves anything the caller did not name
    or the assessment did not already propose.

    Approval granularity (brief section 19):
      -ApproveSafeChanges   bulk-approves SAFE_CHANGE operations only.
      -ApproveOperation     repeatable; the ONLY way to approve a
                            REVIEW_REQUIRED or REMOVE_CANDIDATE operation.
      BLOCKED and UNKNOWN operations can never be approved by any flag --
      there is no -force / -ignoreBlocker escape hatch in v1.

    Writes approved-plan.json: repository, profile, assessmentGeneratedAt,
    assessmentCommitOrHead, stateFingerprint, planHash, approvedAt,
    approvedBy, operations[]. apply-plan.ps1 refuses to run against a plan
    whose recomputed hash does not match the stored planHash.

.PARAMETER Plan
    Path to an assessment JSON file produced by assess-npm-library.ps1
    -JsonOutputPath.

.PARAMETER OutputPath
    Where to write approved-plan.json. Defaults to a file named after the
    repository next to -Plan (e.g. ./<repo>-approved-plan.json).

.PARAMETER ApproveSafeChanges
    Bulk-approve every SAFE_CHANGE operation in the plan.

.PARAMETER ApproveOperation
    Repeatable. Approve this specific operation id (see the assessment's
    "id" field per capability/plan item). Required for REVIEW_REQUIRED and
    REMOVE_CANDIDATE operations -- they are never swept in by
    -ApproveSafeChanges.

.PARAMETER ApprovedBy
    Identity recorded in the approval artifact. Defaults to the currently
    authenticated `gh` user login.

.EXAMPLE
    .\approve-plan.ps1 -Plan .\reports\adapter-xma-adoption.json -ApproveSafeChanges -ApproveOperation repo.defaultBranch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Plan,

    [string]$OutputPath,

    [switch]$ApproveSafeChanges,

    [string[]]$ApproveOperation,

    [string]$ApprovedBy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Deliberately imports only Approval.psm1 and (for -ApprovedBy discovery
# only) ReadOnlyGitHub.psm1's Test-GhAuthenticated/gh-user lookup, which is
# a GET. This script never imports MutationGitHub.psm1 -- approval makes no
# mutating call, and there is nothing here that could accidentally do so.
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\adopter\lib\Approval.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\ReadOnlyGitHub.psm1') -Force

if (-not (Test-Path -LiteralPath $Plan)) {
    Write-Error "Assessment file not found: $Plan"
    exit 2
}

$assessment = $null
try {
    $assessment = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Assessment file is not valid JSON: $Plan`n$_"
    exit 2
}

foreach ($required in @('repository', 'profile', 'assessedAt', 'stateFingerprint', 'plan')) {
    if (-not ($assessment.PSObject.Properties.Name -contains $required)) {
        Write-Error "Assessment file is missing required field '$required' -- is this an assess-npm-library.ps1 JSON output? $Plan"
        exit 2
    }
}

if ([string]::IsNullOrEmpty($ApprovedBy)) {
    if (Test-GhAuthenticated) {
        $userResult = Invoke-ReadOnlyGitHub -Path 'user'
        if ($userResult.Success -and $userResult.Data -and $userResult.Data.login) {
            $ApprovedBy = "$($userResult.Data.login)"
        }
    }
    if ([string]::IsNullOrEmpty($ApprovedBy)) {
        Write-Error 'Could not determine -ApprovedBy automatically (gh not authenticated or "gh api user" failed). Pass -ApprovedBy explicitly.'
        exit 2
    }
}

$operations = ConvertTo-PlanOperations -Assessment $assessment
if ($operations.Count -eq 0) {
    Write-Host "No actionable operations in this assessment (repository is already fully COMPLIANT, or only NOT_AVAILABLE/KEEP_STRONGER differences exist). Nothing to approve."
    exit 0
}

if (-not $ApproveSafeChanges -and (@($ApproveOperation | Where-Object { $_ })).Count -eq 0) {
    Write-Error 'Nothing to approve: pass -ApproveSafeChanges and/or one or more -ApproveOperation <id>. Run without -WhatIf-like flags first to review the assessment''s operation ids.'
    Write-Host ''
    Write-Host 'Actionable operations in this assessment:'
    $operations | ForEach-Object { Write-Host ("  {0,-45} {1,-16} {2}" -f $_.id, $_.classification, $_.capability) }
    exit 2
}

$approval = Approve-PlanOperations -Operations $operations -ApproveSafeChanges:$ApproveSafeChanges -ApproveOperationIds $ApproveOperation

if ($approval.UnmatchedExplicitIds.Count -gt 0) {
    Write-Error "The following -ApproveOperation id(s) do not exist in this assessment's plan: $($approval.UnmatchedExplicitIds -join ', ')"
    exit 2
}

if ($approval.Rejected.Count -gt 0) {
    Write-Host 'REJECTED approval attempt(s) -- approved-plan.json was NOT written:' -ForegroundColor Red
    foreach ($r in $approval.Rejected) {
        Write-Host ("  [{0}] {1} ({2}, requested via {3})" -f $r.Id, $r.Capability, $r.Classification, $r.RequestedVia) -ForegroundColor Red
        Write-Host "    Reason: $($r.Reason)" -ForegroundColor Red
    }
    exit 1
}

if ($approval.ApprovedIds.Count -eq 0) {
    Write-Host 'No operation matched -ApproveSafeChanges / -ApproveOperation -- nothing approved, approved-plan.json was NOT written.'
    exit 2
}

$approvedPlan = New-ApprovedPlan -Assessment $assessment -Operations $approval.Operations -ApprovedBy $ApprovedBy

if ([string]::IsNullOrEmpty($OutputPath)) {
    $repoSlug = ($approvedPlan.repository -replace '[\\/]', '-')
    $OutputPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Plan)) "$repoSlug-approved-plan.json"
}

($approvedPlan | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host "Approved plan written: $OutputPath"
Write-Host "Repository: $($approvedPlan.repository)"
Write-Host "Approved by: $($approvedPlan.approvedBy)"
Write-Host "Plan hash: $($approvedPlan.planHash)"
Write-Host "Approved operations ($($approval.ApprovedIds.Count)):"
foreach ($id in $approval.ApprovedIds) {
    $op = @($operations | Where-Object { "$($_.id)" -eq $id })[0]
    $marker = if ($op.destructive) { ' [DESTRUCTIVE]' } elseif ($op.requiresManualChange) { ' [MANUAL CHANGE -- Apply cannot execute]' } else { '' }
    Write-Host ("  [{0}] {1} ({2}){3}" -f $op.id, $op.capability, $op.classification, $marker)
}
$notApproved = @($operations | Where-Object { -not $_.approved })
if ($notApproved.Count -gt 0) {
    Write-Host ""
    Write-Host "Not approved in this pass ($($notApproved.Count)) -- still pending a future assessment/approval/apply cycle:"
    foreach ($op in $notApproved) {
        Write-Host ("  [{0}] {1} ({2})" -f $op.id, $op.capability, $op.classification)
    }
}
exit 0
