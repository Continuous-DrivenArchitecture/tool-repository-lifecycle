#Requires -Version 5.1
<#
    Provisioner.psm1

    Core logic for the CDA npm-library repository provisioner. Deliberately
    split into three concerns so the middle one is unit-testable without a
    network call:

      1. STATE DISCOVERY   (Get-Current*)  -- talks to GitHub via GhApi.psm1
      2. DESIRED-STATE / COMPARISON (New-PlanItem, Compare-*, Build-Desired*)
                                     -- pure functions, fixture-testable
      3. MUTATION          (Invoke-*Capabilities) -- talks to GitHub, gated
                                     by -DryRun

    This module implements the GitHub-side configuration ONLY. It never
    clones, checks out, commits, pushes, creates branches, or merges PRs  - 
    repository *contents* are template-npm-library's responsibility, not
    this provisioner's.
#>

Set-StrictMode -Version Latest

# Read-only-only, by construction (same structural property as the
# adopter lifecycle path's Discovery.psm1/Classification.psm1/
# Comparison.psm1 -- see docs/safety-model.md): this module may only ever
# import ReadOnlyGitHub.psm1 -- never MutationGitHub.psm1. Every mutating
# call in the whole provisioner lifecycle path lives in Orchestration.psm1
# instead. tests/run-tests.ps1's read-only boundary check scans this
# file's own source text to enforce that structurally, not just by
# convention. Test-RepositoryNameFormat/Test-RepositoryEligibility/
# Get-RepositoryLanguages/Get-AllRulesets used to be defined locally here;
# they are now shared with the adopter lifecycle path via src/common (see
# docs/architecture.md, "Common core").
Import-Module (Join-Path $PSScriptRoot '..\..\common\github\ReadOnlyGitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\common\github\RepositoryDiscovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\common\repository\Validation.psm1') -Force

$script:CdaOrg = 'Continuous-DrivenArchitecture'
$script:RulesetName = 'Protect main'
$script:RequiredCheckContext = 'ci-required'

# ---------------------------------------------------------------------------
# Current-state discovery (network)
# ---------------------------------------------------------------------------

function Get-WorkflowExternalActionOwners {
    <#
        Reads .github/workflows/*.yml via the Contents API (no git clone)
        and extracts the "owner" segment of every `uses:` reference, so the
        provisioner can tell whether a restrictive allowed-actions policy
        would actually break this repository's own workflows BEFORE
        applying it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $listing = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/contents/.github/workflows"
    if (-not $listing.Success -or $null -eq $listing.Data) { return @() }

    $owners = New-Object System.Collections.Generic.HashSet[string]
    foreach ($entry in @($listing.Data)) {
        if ($entry.type -ne 'file') { continue }
        if ($entry.name -notmatch '\.ya?ml$') { continue }

        $file = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/contents/.github/workflows/$($entry.name)"
        if (-not $file.Success -or -not $file.Data.content) { continue }

        $bytes = [Convert]::FromBase64String(($file.Data.content -replace "`n", ''))
        $yaml = [System.Text.Encoding]::UTF8.GetString($bytes)

        foreach ($m in [regex]::Matches($yaml, 'uses:\s*([^\s#]+)')) {
            $usesRef = $m.Groups[1].Value.Trim()
            if ($usesRef.StartsWith('./') -or $usesRef.StartsWith('.\')) { continue } # local reusable workflow, not an external action
            $ownerSegment = ($usesRef -split '/')[0]
            if ($ownerSegment) { [void]$owners.Add($ownerSegment) }
        }
    }
    return @($owners)
}

function Test-RequiredCheckEvidence {
    <#
        Read-only. Looks for a check run literally named ci-required on the
        tip commit of the default branch. This is a deliberately narrow,
        honest check: it proves the check has executed at least once on the
        current branch tip; it does not exhaustively search all history.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$DefaultBranch
    )

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/commits/$DefaultBranch/check-runs"
    if (-not $result.Success -or $null -eq $result.Data) {
        return [PSCustomObject]@{ Found = $false; Conclusion = $null; ErrorKind = $result.ErrorKind }
    }
    $checkRuns = @($result.Data.check_runs)
    $match = $checkRuns | Where-Object { $_.name -eq $script:RequiredCheckContext } | Select-Object -First 1
    if ($null -eq $match) {
        return [PSCustomObject]@{ Found = $false; Conclusion = $null; ErrorKind = $null }
    }
    return [PSCustomObject]@{ Found = $true; Conclusion = $match.conclusion; ErrorKind = $null }
}

function Get-CurrentRulesetState {
    <#
        Implements the "ruleset discovery" contract: 0 matches -> Absent,
        1 match -> Single (with full detail fetched), 2+ matches -> Multiple
        (fail-safe, never auto-resolved). Built on top of
        src/common/github/RepositoryDiscovery.psm1's Get-AllRulesets (list +
        per-id detail fetch) -- previously duplicated ad hoc in this
        function; the Absent/Single/Multiple/Unknown classification itself
        stays here, since it is narrower and provisioner-specific (the
        adopter lifecycle path needs to represent EVERY ruleset, not just
        classify the presence of exactly one named "Protect main").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $all = Get-AllRulesets -Owner $Owner -Repo $Repo
    if (-not $all.Available) {
        return [PSCustomObject]@{ State = 'Unknown'; Detail = $null; Ids = @(); ErrorKind = $all.ErrorKind }
    }
    # The outer @() must wrap the WHOLE pipeline, not just $all.Rulesets:
    # assigning a Where-Object result straight to a variable collapses to a
    # bare scalar (not an array) whenever exactly one item survives the
    # filter, regardless of whether the input was already wrapped.
    $named = @($all.Rulesets | Where-Object { $_.name -eq $script:RulesetName })
    if ($named.Count -eq 0) {
        return [PSCustomObject]@{ State = 'Absent'; Detail = $null; Ids = @(); ErrorKind = $null }
    }
    if ($named.Count -gt 1) {
        return [PSCustomObject]@{ State = 'Multiple'; Detail = $null; Ids = @($named.id); ErrorKind = $null }
    }
    # Exactly one ruleset named "Protect main" -- but Get-AllRulesets
    # reports a per-id detail-fetch failure as a stand-in object
    # (FetchFailed=$true) rather than omitting it, so a failed detail read
    # is correctly distinguished from "no such ruleset" here.
    if ($named[0].PSObject.Properties['FetchFailed'] -and $named[0].FetchFailed) {
        return [PSCustomObject]@{ State = 'Unknown'; Detail = $null; Ids = @($named[0].id); ErrorKind = $named[0].ErrorKind }
    }
    return [PSCustomObject]@{ State = 'Single'; Detail = $named[0]; Ids = @($named[0].id); ErrorKind = $null }
}

# ---------------------------------------------------------------------------
# Pure comparison helpers (no network  -  fixture-testable)
# ---------------------------------------------------------------------------

function New-PlanItem {
    <#
        Generic comparator for simple scalar capabilities. Complex
        capabilities (ruleset, required check, allowed-actions policy)
        build their PlanItem explicitly instead of calling this.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Capability,
        [Parameter(Mandatory)] [AllowNull()] $Current,
        [Parameter(Mandatory)] [AllowNull()] $Desired,
        [bool]$Applicable = $true,
        [string]$Notes = ''
    )

    if (-not $Applicable) {
        return [PSCustomObject]@{ Capability = $Capability; Current = $Current; Desired = $Desired; Action = 'SKIP'; Result = 'NOT AVAILABLE'; Notes = $Notes }
    }
    if ($null -eq $Current) {
        return [PSCustomObject]@{ Capability = $Capability; Current = '<unknown>'; Desired = $Desired; Action = 'SKIP'; Result = 'UNKNOWN'; Notes = $Notes }
    }
    if ("$Current" -ceq "$Desired") {
        return [PSCustomObject]@{ Capability = $Capability; Current = $Current; Desired = $Desired; Action = 'NONE'; Result = 'PASS'; Notes = $Notes }
    }
    return [PSCustomObject]@{ Capability = $Capability; Current = $Current; Desired = $Desired; Action = 'UPDATE'; Result = 'DRIFT'; Notes = $Notes }
}

function Compare-StringArray {
    <# Order-independent array equality for small config lists. #>
    param([string[]]$A, [string[]]$B)
    $a2 = @($A | Sort-Object)
    $b2 = @($B | Sort-Object)
    if ($a2.Count -ne $b2.Count) { return $false }
    for ($i = 0; $i -lt $a2.Count; $i++) { if ($a2[$i] -cne $b2[$i]) { return $false } }
    return $true
}

function New-DesiredRulesetBody {
    <#
        Pure function: turns the profile + a decision about whether the
        required-status-checks rule should be included into the exact
        request body GitHub's Rulesets API expects. Reused for both the
        POST (create) and PUT (update) mutation and for diffing against
        whatever the ruleset currently looks like.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $CdaProfile,
        [Parameter(Mandatory)] [bool]$IncludeRequiredStatusChecks
    )

    $rs = $CdaProfile.ruleset
    $dismissStale = [bool]($rs.pullRequest.requiredApprovingReviewCount -gt 0)

    $rules = @(
        @{
            type       = 'pull_request'
            # GitHub's ruleset PUT (update) validator is stricter than POST
            # (create): POST silently fills these in with defaults if
            # omitted, but PUT rejects the request with a generic "data
            # matches no possible input" (422) unless the full shape is
            # present -- confirmed empirically against a live ruleset, not
            # assumed. required_reviewers/dismissal_restriction/
            # require_last_push_approval/require_extra_approval_for_
            # unattributed_changes carry no CDA policy meaning of their
            # own (see Compare-RulesetToDesired, which deliberately does
            # not diff them) -- they're sent purely to satisfy the schema,
            # using the same values GitHub itself defaults to on create.
            parameters = @{
                required_approving_review_count = [int]$rs.pullRequest.requiredApprovingReviewCount
                dismiss_stale_reviews_on_push   = $dismissStale
                required_reviewers              = @()
                require_code_owner_review       = [bool]$rs.pullRequest.requireCodeOwnerReview
                dismissal_restriction           = @{ enabled = $false; allowed_actors = @() }
                require_last_push_approval      = $false
                required_review_thread_resolution = [bool]$rs.pullRequest.requiredReviewThreadResolution
                require_extra_approval_for_unattributed_changes = $true
                allowed_merge_methods           = @($rs.pullRequest.allowedMergeMethods)
            }
        }
    )
    if ($IncludeRequiredStatusChecks) {
        $rules += @{
            type       = 'required_status_checks'
            parameters = @{
                strict_required_status_checks_policy = [bool]$rs.requiredStatusChecks.strict
                required_status_checks = @(@{ context = $rs.requiredStatusChecks.context })
            }
        }
    }
    if ($rs.nonFastForward) { $rules += @{ type = 'non_fast_forward' } }
    if ($rs.deletion) { $rules += @{ type = 'deletion' } }

    return @{
        name        = $rs.name
        target      = $rs.target
        enforcement = $rs.enforcement
        conditions  = @{ ref_name = @{ include = @($rs.refInclude); exclude = @() } }
        rules       = $rules
        bypass_actors = @($rs.bypassActors)
    }
}

function Compare-RulesetToDesired {
    <#
        Pure function: does the CURRENT ruleset (as returned by GitHub's
        detail endpoint) already satisfy the DESIRED body? Compares only
        the fields this provisioner controls  -  GitHub echoes back several
        computed fields (dismissal_restriction, require_extra_approval_...)
        that we never set explicitly, and those are intentionally ignored
        so they never cause a false DRIFT.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $CurrentDetail, [Parameter(Mandatory)] [hashtable]$DesiredBody)

    if ($CurrentDetail.enforcement -ne $DesiredBody.enforcement) { return $false }

    $currentBypass = @($CurrentDetail.bypass_actors | ForEach-Object { $_.actor_id })
    if (-not (Compare-StringArray -A ($currentBypass | ForEach-Object { "$_" }) -B ($DesiredBody.bypass_actors | ForEach-Object { "$_" }))) { return $false }

    foreach ($desiredRule in $DesiredBody.rules) {
        $currentRule = $CurrentDetail.rules | Where-Object { $_.type -eq $desiredRule.type } | Select-Object -First 1
        if ($null -eq $currentRule) { return $false }

        switch ($desiredRule.type) {
            'pull_request' {
                $dp = $desiredRule.parameters
                $cp = $currentRule.parameters
                if ($cp.required_approving_review_count -ne $dp.required_approving_review_count) { return $false }
                if ([bool]$cp.dismiss_stale_reviews_on_push -ne [bool]$dp.dismiss_stale_reviews_on_push) { return $false }
                if ([bool]$cp.require_code_owner_review -ne [bool]$dp.require_code_owner_review) { return $false }
                if ([bool]$cp.required_review_thread_resolution -ne [bool]$dp.required_review_thread_resolution) { return $false }
                if (-not (Compare-StringArray -A $cp.allowed_merge_methods -B $dp.allowed_merge_methods)) { return $false }
            }
            'required_status_checks' {
                $dp = $desiredRule.parameters
                $cp = $currentRule.parameters
                if ([bool]$cp.strict_required_status_checks_policy -ne [bool]$dp.strict_required_status_checks_policy) { return $false }
                $currentContexts = @($cp.required_status_checks | ForEach-Object { $_.context })
                $desiredContexts = @($dp.required_status_checks | ForEach-Object { $_.context })
                if (-not (Compare-StringArray -A $currentContexts -B $desiredContexts)) { return $false }
            }
            default { } # non_fast_forward / deletion: presence alone is sufficient
        }
    }

    # Also fail the comparison if CURRENT has a required_status_checks rule
    # that DESIRED does not (e.g. Bootstrap re-run must not silently drop a
    # check Finalize already wired in).
    $desiredHasRsc = [bool]($DesiredBody.rules | Where-Object { $_.type -eq 'required_status_checks' })
    $currentHasRsc = [bool]($CurrentDetail.rules | Where-Object { $_.type -eq 'required_status_checks' })
    if ($currentHasRsc -and -not $desiredHasRsc) { return $false }

    return $true
}

Export-ModuleMember -Function `
    Get-WorkflowExternalActionOwners, `
    Test-RequiredCheckEvidence, Get-CurrentRulesetState, `
    New-PlanItem, Compare-StringArray, New-DesiredRulesetBody, Compare-RulesetToDesired
