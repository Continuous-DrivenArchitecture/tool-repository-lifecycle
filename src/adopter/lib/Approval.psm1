#Requires -Version 5.1
<#
    Approval.psm1

    Turns a read-only assessment's JSON plan into an explicit, individually
    approvable set of operations, and produces the immutable
    approved-plan.json artifact. Performs zero GitHub API calls -- this
    module never imports ReadOnlyGitHub.psm1 or MutationGitHub.psm1. It only
    reads an already-generated assessment JSON object and writes plain
    PowerShell objects.

    Core rule enforced here (see README.md, "Lifecycle"): ASSESS -> PLAN
    already happened (assess-npm-library.ps1). This module is the HUMAN
    APPROVAL step. It never re-classifies, never discovers a new
    recommendation, and never invents an operation that was not already
    present in the source assessment's plan.
#>

Set-StrictMode -Version Latest

function ConvertTo-CanonicalJsonString {
    <#
        JSON-escapes one string for use inside Get-CanonicalJsonText's
        output. Kept separate from ConvertTo-Json on purpose: ConvertTo-Json
        does not guarantee sorted object keys or stable whitespace across
        PowerShell versions, and the plan hash must be reproducible byte-
        for-byte regardless of that.
    #>
    [CmdletBinding()]
    param([string]$Text)

    if ($null -eq $Text) { $Text = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        switch ("$ch") {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                if ([int][char]$ch -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int][char]$ch)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-CanonicalJsonText {
    <#
        Recursively renders $Value as compact JSON text with object keys
        sorted (ordinal) at every level and array element order preserved
        (array order is semantically meaningful -- operation order reflects
        phase sequencing -- so it is never reordered). No dependency on
        ConvertTo-Json's property ordering, which is not guaranteed stable.
    #>
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [byte] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [float]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) { return ConvertTo-CanonicalJsonString -Text $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys) | Sort-Object
        $parts = @($keys | ForEach-Object { (ConvertTo-CanonicalJsonString -Text "$_") + ':' + (Get-CanonicalJsonText -Value $Value[$_]) })
        return '{' + ($parts -join ',') + '}'
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        $parts = @($items | ForEach-Object { Get-CanonicalJsonText -Value $_ })
        return '[' + ($parts -join ',') + ']'
    }

    if ($Value -is [PSCustomObject]) {
        $props = @($Value.PSObject.Properties | Sort-Object Name)
        $parts = @($props | ForEach-Object { (ConvertTo-CanonicalJsonString -Text $_.Name) + ':' + (Get-CanonicalJsonText -Value $_.Value) })
        return '{' + ($parts -join ',') + '}'
    }

    return ConvertTo-CanonicalJsonString -Text "$Value"
}

function Get-Sha256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha.ComputeHash($bytes)
        return -join (@($hashBytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Get-OperationDependencies {
    <#
        Human-readable dependency descriptions for one operation id.
        Descriptive only -- the executable re-check of each of these lives
        in Apply.psm1 (Invoke-Preflight / per-operation precondition
        checks), keyed by the same id namespace. Kept as data here (not a
        DSL) on purpose: v1 has a small, known set of dependency-bearing
        operation shapes (brief section 21), not an open-ended rule engine.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Id)

    if ($Id -eq 'branch.delete.develop') {
        return @(
            'default branch is main, not develop'
            'develop has no commits unreachable from main (fully merged)'
            'no open pull request targets develop'
            'no workflow file references develop'
            'Dependabot does not target develop'
        )
    }
    if ($Id -match '^secret\.') {
        $name = $Id.Substring(7)
        if ($name -match '(?i)RELEASE_APP|SENTINEL') {
            return @(
                'no workflow currently references this secret'
                'the Protect main ruleset no longer lists a bypass actor that depends on this credential'
            )
        }
        return @('no workflow currently references this secret')
    }
    if ($Id -eq 'repo.defaultBranch') {
        return @(
            'the target branch exists'
            'the old default branch is not deleted by this same operation (deletion is separate and separately approved)'
        )
    }
    if ($Id -match '^ruleset\.') {
        return @(
            'the ruleset id matches the id captured at assessment time'
            'the ruleset updated_at matches the value captured at assessment time (no concurrent edit)'
        )
    }
    if ($Id -eq 'hygiene.pages') {
        return @(
            'no workflow currently deploys to or references GitHub Pages'
            'no custom domain is bound'
        )
    }
    if ($Id -match '^hygiene\.environment\.') {
        return @(
            'the environment name is exactly github-pages -- no other environment is ever targeted'
            'GitHub Pages configuration is already absent (dependency order)'
            'no workflow currently references this environment'
        )
    }
    return @()
}

function Get-OperationActionDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [string]$Classification,
        [bool]$RequiresManualChange,
        [bool]$Destructive,
        [string]$Repository
    )

    if ($RequiresManualChange) {
        return 'MANUAL_REPOSITORY_CHANGE_REQUIRED: this is a repository file edit, not a GitHub setting. Apply cannot execute it -- make the change via a normal pull request, merge it, then run a new assessment to confirm convergence.'
    }
    $prefix = if ($Destructive) { 'DESTRUCTIVE OPERATION: ' } else { '' }
    switch -Regex ($Id) {
        '^branch\.delete\.develop$' { return "${prefix}DELETE the develop branch ref (repos/$Repository/git/refs/heads/develop) after re-verifying every deletion precondition against live state." }
        '^secret\.' { $n = $Id.Substring(7); return "${prefix}DELETE secret $n (repos/$Repository/actions/secrets/$n) after re-verifying no workflow references it. The secret's value is never read." }
        '^repo\.defaultBranch$' { return "${prefix}PATCH repos/$Repository to change the default branch, then verify the change took effect. Never deletes the old default branch as part of this operation." }
        '^hygiene\.pages$' { return "${prefix}DELETE the GitHub Pages configuration (repos/$Repository/pages) after re-verifying no workflow deploys to it and no custom domain is bound." }
        '^hygiene\.environment\.' { return "${prefix}DELETE the GitHub Environment named github-pages (repos/$Repository/environments/github-pages) only -- never any other environment -- after re-verifying Pages is already absent and no workflow references it." }
        '^ruleset\.' { return "PATCH/PUT the ruleset identified by the id captured at assessment time (repos/$Repository/rulesets/{id}) after re-verifying that id and its updated_at are unchanged." }
        default { return "${Classification}: update this repository setting via the GitHub API to match the CDA target value." }
    }
}

function ConvertTo-PlanOperations {
    <#
        Flattens the assessment JSON's phased `.plan` array (already
        excludes COMPLIANT / NOT_AVAILABLE / KEEP_STRONGER -- see
        AdoptionPlan.psm1's New-AdoptionPlan `$actionable` filter) into a
        single ordered operations array, phase order preserved. This is the
        ONLY place operations are created from an assessment -- approval
        never adds, removes, or re-derives an operation beyond what the
        assessment already planned.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Assessment)

    $ops = @()
    foreach ($phaseObj in @($Assessment.plan)) {
        foreach ($item in @($phaseObj.items)) {
            $requiresManual = [bool]$item.requiresManualChange
            $destructive = [bool]$item.destructive
            $ops += [PSCustomObject]@{
                id                   = "$($item.id)"
                phase                = [int]$phaseObj.phase
                phaseName            = "$($phaseObj.name)"
                capability           = "$($item.capability)"
                classification       = "$($item.classification)"
                current              = "$($item.current)"
                desired              = "$($item.target)"
                rationale            = "$($item.rationale)"
                requiresManualChange = $requiresManual
                destructive          = $destructive
                dependencies         = @(Get-OperationDependencies -Id "$($item.id)")
                action               = Get-OperationActionDescription -Id "$($item.id)" -Classification "$($item.classification)" -RequiresManualChange $requiresManual -Destructive $destructive -Repository "$($Assessment.repository)"
                approved             = $false
            }
        }
    }
    return $ops
}

function Test-OperationApprovable {
    <#
        Whether this operation's CLASSIFICATION can ever be approved at
        all, independent of which flag/id was used to request it. The
        finer-grained rule ("SAFE_CHANGE may be swept, REVIEW_REQUIRED /
        REMOVE_CANDIDATE must be named explicitly") is enforced by
        Approve-PlanOperations, not here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Operation)

    switch ("$($Operation.classification)") {
        'BLOCKED' { return [PSCustomObject]@{ Approvable = $false; Reason = 'BLOCKED operations can never be approved in v1 -- there is no -force / -ignoreBlocker escape hatch. Resolve the underlying blocker and re-run assessment.' } }
        'UNKNOWN' { return [PSCustomObject]@{ Approvable = $false; Reason = 'UNKNOWN cannot be approved -- current state could not be read at assessment time. Resolve access/credentials and re-run assessment first.' } }
        'COMPLIANT' { return [PSCustomObject]@{ Approvable = $false; Reason = 'COMPLIANT capabilities are not operations -- there is nothing to approve.' } }
        'KEEP_STRONGER' { return [PSCustomObject]@{ Approvable = $false; Reason = 'KEEP_STRONGER never generates a downgrade operation.' } }
        'NOT_AVAILABLE' { return [PSCustomObject]@{ Approvable = $false; Reason = 'NOT_AVAILABLE never generates a mutating operation.' } }
        default { return [PSCustomObject]@{ Approvable = $true; Reason = $null } }
    }
}

function Approve-PlanOperations {
    <#
        Applies -ApproveSafeChanges (non-destructive SAFE_CHANGE only,
        swept in bulk) and -ApproveOperationIds (any specific id,
        repeatable -- the only way to approve REVIEW_REQUIRED,
        REMOVE_CANDIDATE, or ANY destructive operation, including a
        destructive SAFE_CHANGE) to $Operations in place, and reports
        every rejected or unmatched approval attempt so the CLI can fail
        closed instead of silently approving less than the caller asked
        for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array]$Operations,
        [switch]$ApproveSafeChanges,
        [string[]]$ApproveOperationIds
    )

    $explicitIds = @($ApproveOperationIds | Where-Object { $_ })
    $rejected = @()
    $approvedIds = @()
    $allIds = @(@($Operations) | ForEach-Object { "$($_.id)" })

    foreach ($op in $Operations) {
        # SECURITY: -ApproveSafeChanges must NEVER sweep in a destructive
        # operation, regardless of its classification. Found during live
        # sandbox integration testing (2026-08-23): develop-deletion can
        # legitimately be classified SAFE_CHANGE once every precondition
        # is clean, but "safe to delete" is still a destructive,
        # irreversible action that must always require the caller to name
        # its id explicitly via -ApproveOperation. This check is on the
        # operation's own `destructive` flag, independent of and in
        # addition to the classification-based rule below -- a
        # destructive REMOVE_CANDIDATE or REVIEW_REQUIRED already needed
        # -ApproveOperation for its classification alone, but a
        # destructive SAFE_CHANGE previously slipped through the sweep.
        $requestedViaSafeSweep = ($ApproveSafeChanges -and "$($op.classification)" -eq 'SAFE_CHANGE' -and -not [bool]$op.destructive)
        $requestedExplicitly = ($explicitIds -contains "$($op.id)")
        if (-not ($requestedViaSafeSweep -or $requestedExplicitly)) { continue }

        $check = Test-OperationApprovable -Operation $op
        if (-not $check.Approvable) {
            $rejected += [PSCustomObject]@{
                Id             = "$($op.id)"
                Capability     = "$($op.capability)"
                Classification = "$($op.classification)"
                Reason         = $check.Reason
                RequestedVia   = $(if ($requestedExplicitly) { '-ApproveOperation' } else { '-ApproveSafeChanges' })
            }
            continue
        }
        $op.approved = $true
        $approvedIds += "$($op.id)"
    }

    $unmatchedExplicitIds = @($explicitIds | Where-Object { $_ -notin $allIds })

    return [PSCustomObject]@{
        Operations            = $Operations
        Rejected              = $rejected
        ApprovedIds           = $approvedIds
        UnmatchedExplicitIds  = $unmatchedExplicitIds
    }
}

function Get-HashableOperation {
    [CmdletBinding()]
    param($Op)

    return [ordered]@{
        id             = "$($Op.id)"
        capability     = "$($Op.capability)"
        classification = "$($Op.classification)"
        current        = "$($Op.current)"
        desired        = "$($Op.desired)"
        dependencies   = @(@($Op.dependencies) | Sort-Object)
    }
}

function Get-PlanHash {
    <#
        Deterministic SHA-256 over {repository, profile, operations[]}
        where each operation is projected to exactly: id, capability,
        classification, current, desired, dependencies (brief section 14).
        Deliberately excludes rationale text, the `approved` flag, and any
        timestamp -- none of those represent a real change to WHAT would be
        mutated, and including them would make the hash brittle to
        reformatting or re-wording rather than meaningful to content.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [string]$Profile,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array]$Operations
    )

    $hashable = [ordered]@{
        repository = $Repository
        profile    = $Profile
        operations = @(@($Operations) | ForEach-Object { Get-HashableOperation -Op $_ })
    }
    $canonical = Get-CanonicalJsonText -Value $hashable
    return Get-Sha256Hex -Text $canonical
}

function New-ApprovedPlan {
    <#
        Builds the immutable approved-plan.json object. Performs no
        GitHub API call. `stateFingerprint` is carried through verbatim
        from the source assessment -- Apply's preflight re-reads live
        state and compares against exactly this snapshot before mutating
        anything (see Apply.psm1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Assessment,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array]$Operations,
        [Parameter(Mandatory)] [string]$ApprovedBy
    )

    $repository = "$($Assessment.repository)"
    $profileName = "$($Assessment.profile)"
    $hash = Get-PlanHash -Repository $repository -Profile $profileName -Operations $Operations

    return [PSCustomObject]@{
        schemaVersion          = '1.0'
        repository             = $repository
        profile                = $profileName
        assessmentGeneratedAt  = "$($Assessment.assessedAt)"
        assessmentCommitOrHead = "$($Assessment.stateFingerprint.DefaultBranchSha)"
        stateFingerprint       = $Assessment.stateFingerprint
        planHash               = $hash
        approvedAt             = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        approvedBy             = $ApprovedBy
        operations             = $Operations
    }
}

function Test-ApprovedPlanHash {
    <#
        Recomputes the plan hash from an approved plan's OWN operations
        array and compares it to the stored planHash. A mismatch means the
        file was hand-edited (or otherwise altered) after approval --
        Apply must treat that as fatal, never as "close enough".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ApprovedPlan)

    $recomputed = Get-PlanHash -Repository "$($ApprovedPlan.repository)" -Profile "$($ApprovedPlan.profile)" -Operations @($ApprovedPlan.operations)
    return [PSCustomObject]@{
        Valid      = ($recomputed -eq "$($ApprovedPlan.planHash)")
        Stored     = "$($ApprovedPlan.planHash)"
        Recomputed = $recomputed
    }
}

Export-ModuleMember -Function Get-CanonicalJsonText, Get-Sha256Hex, Get-OperationDependencies, Get-OperationActionDescription, ConvertTo-PlanOperations, Test-OperationApprovable, Approve-PlanOperations, Get-PlanHash, New-ApprovedPlan, Test-ApprovedPlanHash
