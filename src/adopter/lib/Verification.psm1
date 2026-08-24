#Requires -Version 5.1
<#
    Verification.psm1

    Two distinct kinds of verification, deliberately not conflated (brief
    section 22):

    1. Test-OperationApplied -- did THIS specific approved-and-applied
       operation's live value converge to its desired value? Read-only.

    2. Invoke-FullCdaVerification -- re-runs the full, independent,
       read-only assessment (assess-npm-library.ps1) and reports every
       capability that still does not read COMPLIANT / KEEP_STRONGER /
       NOT_AVAILABLE as a remaining gap. A plan can apply every operation
       it approved and still leave real gaps (BLOCKED items, manual-change
       items, anything simply not part of this plan) -- "PLAN APPLIED
       SUCCESSFULLY" and "FULL CDA COMPLIANCE" are never the same claim,
       and this module never lets a caller collapse them into one.

    Imports only ReadOnlyGitHub.psm1 -- never MutationGitHub.psm1. Nothing
    in this file can mutate anything.
#>

Set-StrictMode -Version Latest

function Test-OperationApplied {
    <#
        Live read-back for one operation whose mutation Apply reported as
        APPLIED. Returns Observed (string) and Matches ($true/$false/$null
        -- $null when this id has no known read-back mapping, which is
        reported as "could not verify", never silently treated as success).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Op,
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo
    )

    $id = "$($Op.id)"
    $desired = "$($Op.desired)"

    $repoFieldMap = @{
        'repo.defaultBranch'      = 'default_branch'
        'repo.deleteBranchOnMerge' = 'delete_branch_on_merge'
        'repo.allowSquashMerge'   = 'allow_squash_merge'
        'repo.allowMergeCommit'   = 'allow_merge_commit'
        'repo.allowRebaseMerge'   = 'allow_rebase_merge'
        'repo.allowAutoMerge'     = 'allow_auto_merge'
    }
    if ($repoFieldMap.ContainsKey($id)) {
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo"
        if (-not $r.Success) { return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = 'could not re-read repository state' } }
        $observed = "$($r.Data.($repoFieldMap[$id]))"
        return [PSCustomObject]@{ Observed = $observed; Matches = ($observed -eq $desired); Detail = '' }
    }

    if ($id -eq 'branch.delete.develop') {
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/branches/develop"
        $observed = if ($r.Success) { 'exists' } else { 'absent' }
        return [PSCustomObject]@{ Observed = $observed; Matches = (-not $r.Success); Detail = '' }
    }

    if ($id -eq 'hygiene.pages') {
        # GitHub's own semantics: a 404 on GET /pages is exactly what
        # "no Pages configuration" looks like (Discovery.psm1's
        # Get-PagesConfig treats it identically as Configured=$false).
        # Any OTHER failure (403/5xx/transport) is NOT proof of absence --
        # UNVERIFIABLE, never silently counted as success.
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/pages"
        if ($r.Success) { return [PSCustomObject]@{ Observed = 'configured'; Matches = $false; Detail = '' } }
        if ($r.ErrorKind -eq 'NotFound') { return [PSCustomObject]@{ Observed = 'absent'; Matches = $true; Detail = '' } }
        return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = "could not re-read Pages configuration (ErrorKind: $($r.ErrorKind))" }
    }

    if ($id -match '^hygiene\.environment\.') {
        $targetEnvName = ("$($Op.capability)" -replace '^Hygiene:\s*', '') -replace '\s+environment$', ''
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/environments/$targetEnvName"
        if ($r.Success) { return [PSCustomObject]@{ Observed = 'exists'; Matches = $false; Detail = '' } }
        if ($r.ErrorKind -eq 'NotFound') { return [PSCustomObject]@{ Observed = 'absent'; Matches = $true; Detail = '' } }
        return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = "could not re-read environment '$targetEnvName' (ErrorKind: $($r.ErrorKind))" }
    }

    if ($id -match '^secret\.') {
        $name = $id.Substring(7)
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/secrets/$name"
        $observed = if ($r.Success) { 'exists' } else { 'absent' }
        return [PSCustomObject]@{ Observed = $observed; Matches = (-not $r.Success); Detail = '' }
    }

    if ($id -eq 'actions.enabled' -or $id -eq 'actions.allowedActionsPolicy' -or $id -eq 'actions.shaPinningRequired') {
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions"
        if (-not $r.Success) { return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = 'could not re-read actions/permissions' } }
        $observed = switch ($id) {
            'actions.enabled' { "$($r.Data.enabled)" }
            'actions.allowedActionsPolicy' { "$($r.Data.allowed_actions)" }
            'actions.shaPinningRequired' {
                if ($null -eq $r.Data.PSObject.Properties['sha_pinning_required']) { $null } else { "$($r.Data.sha_pinning_required)" }
            }
        }
        if ($id -eq 'actions.shaPinningRequired' -and $null -eq $observed) { return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = 'sha_pinning_required field absent from live actions/permissions response' } }
        return [PSCustomObject]@{ Observed = $observed; Matches = ($observed -eq $desired); Detail = '' }
    }

    if ($id -eq 'actions.defaultWorkflowPermissions') {
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions/workflow"
        if (-not $r.Success) { return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = 'could not re-read actions/permissions/workflow' } }
        $observed = "$($r.Data.default_workflow_permissions)"
        return [PSCustomObject]@{ Observed = $observed; Matches = ($observed -eq $desired); Detail = '' }
    }

    $secFieldMap = @{
        'security.secretScanning'             = 'secret_scanning'
        'security.secretScanningPushProtection' = 'secret_scanning_push_protection'
        'security.dependabotSecurityUpdates'  = 'dependabot_security_updates'
    }
    if ($secFieldMap.ContainsKey($id)) {
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo"
        if (-not $r.Success -or $null -eq $r.Data.security_and_analysis) { return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = 'could not re-read security_and_analysis' } }
        $status = "$($r.Data.security_and_analysis.($secFieldMap[$id]).status)"
        $observedBool = ($status -eq 'enabled')
        return [PSCustomObject]@{ Observed = $status; Matches = ("$observedBool" -eq $desired); Detail = '' }
    }

    if ($id -eq 'security.vulnerabilityAlerts') {
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/vulnerability-alerts"
        $observedBool = $r.Success
        return [PSCustomObject]@{ Observed = "$observedBool"; Matches = ("$observedBool" -eq $desired); Detail = '' }
    }

    if ($id -eq 'security.codeQL') {
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/code-scanning/default-setup"
        $observed = if ($r.Success) { "$($r.Data.state)" } else { $null }
        return [PSCustomObject]@{ Observed = $observed; Matches = ($observed -eq 'configured'); Detail = '' }
    }

    if ($id -eq 'ruleset.bypassActors' -or $id -eq 'ruleset.allowedMergeMethods' -or $id -eq 'ruleset.strictStatusChecks') {
        # Read-back for a specific ruleset id is done by the caller (which
        # already knows the id from the state fingerprint) via
        # Test-RulesetOperationApplied below -- a plain id lookup here
        # would require re-deriving the ruleset id from scratch.
        return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = 'use Test-RulesetOperationApplied for ruleset.* operations' }
    }

    if ($id -eq 'ruleset.protectMain') {
        # This op has no pre-existing id (it CREATES the ruleset), so
        # unlike the sub-field ops above it can be verified by name alone
        # right here rather than needing a caller-supplied id.
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/rulesets"
        # @(...) wraps the WHOLE if/else, not just its branches: PowerShell
        # re-enumerates a branch's output when capturing an if/else
        # expression via assignment, which collapses an EMPTY-output
        # branch to $null (see Apply.psm1's matching comment) AND, found
        # here, also unwraps a exactly-ONE-element array down to a bare
        # scalar -- confirmed empirically (`$null -eq $match` was $false,
        # yet `$match.Count` still threw, meaning $match held the single
        # PSCustomObject itself, not a 1-element array containing it).
        $match = @(if ($r.Success) { @($r.Data | Where-Object { "$($_.name)" -eq 'Protect main' }) } else { @() })
        $observed = if ($match.Count -eq 1) { "exists (enforcement=$($match[0].enforcement))" } else { 'absent' }
        return [PSCustomObject]@{ Observed = $observed; Matches = ($match.Count -eq 1 -and "$($match[0].enforcement)" -eq 'active'); Detail = '' }
    }

    if ($id -match '^ruleset\.' -and $id -ne 'ruleset.bypassActors' -and $id -ne 'ruleset.allowedMergeMethods' -and $id -ne 'ruleset.strictStatusChecks' -and $id -ne 'ruleset.requiredStatusChecks') {
        # By construction, any other ruleset.* id reaching this point (see
        # the matching comment in Apply.psm1's Get-RulesetOperationMutationSpec)
        # is a delete-by-name operation -- verify the named ruleset is now
        # gone, resolved by capability text the same way the mutation
        # itself was built, never by re-guessing an id.
        $targetName = ("$($Op.capability)" -replace '^Ruleset:\s*', '')
        $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/rulesets"
        $match = @(if ($r.Success) { @($r.Data | Where-Object { "$($_.name)" -eq $targetName }) } else { @() })
        $observed = if ($match.Count -eq 0) { 'absent' } else { 'still present' }
        return [PSCustomObject]@{ Observed = $observed; Matches = ($match.Count -eq 0); Detail = '' }
    }

    return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = 'no read-back mapping defined for this operation id in Verification v1' }
}

function Test-RulesetOperationApplied {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Op,
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$RulesetId
    )

    $id = "$($Op.id)"
    $r = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/rulesets/$RulesetId"
    if (-not $r.Success) { return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = "could not re-read ruleset $RulesetId" } }

    switch ($id) {
        'ruleset.bypassActors' {
            $count = @($r.Data.bypass_actors).Count
            return [PSCustomObject]@{ Observed = "$count bypass actor(s)"; Matches = ($count -eq 0); Detail = '' }
        }
        'ruleset.allowedMergeMethods' {
            $prRule = @($r.Data.rules | Where-Object { $_.type -eq 'pull_request' })
            $methods = if ($prRule.Count -gt 0) { @($prRule[0].parameters.allowed_merge_methods) -join ',' } else { $null }
            return [PSCustomObject]@{ Observed = $methods; Matches = ($methods -eq 'squash'); Detail = '' }
        }
        'ruleset.strictStatusChecks' {
            $rscRule = @($r.Data.rules | Where-Object { $_.type -eq 'required_status_checks' })
            $strict = if ($rscRule.Count -gt 0) { [bool]$rscRule[0].parameters.strict_required_status_checks_policy } else { $null }
            return [PSCustomObject]@{ Observed = "$strict"; Matches = ($strict -eq $true); Detail = '' }
        }
        'ruleset.requiredStatusChecks' {
            $rscRule = @($r.Data.rules | Where-Object { $_.type -eq 'required_status_checks' })
            $contexts = if ($rscRule.Count -gt 0) { @($rscRule[0].parameters.required_status_checks | ForEach-Object { $_.context }) -join ',' } else { $null }
            return [PSCustomObject]@{ Observed = $contexts; Matches = ($contexts -eq 'ci-required'); Detail = '' }
        }
        default { return [PSCustomObject]@{ Observed = $null; Matches = $null; Detail = 'not a ruleset operation' } }
    }
}

function Invoke-FullCdaVerification {
    <#
        Shells out to assess-npm-library.ps1 (the same proven, read-only
        assessment used to build the original plan) and reports every
        capability that is not COMPLIANT / KEEP_STRONGER / NOT_AVAILABLE
        as a remaining gap. This is a fresh, independent read of live
        state -- never a re-use of the approved plan's own (now possibly
        stale) snapshot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [string]$AssessScriptPath,
        [string]$ProfilePath
    )

    $tempJson = [System.IO.Path]::GetTempFileName()
    try {
        $scriptArgs = @{ Repository = $Repository; JsonOutputPath = $tempJson }
        if ($ProfilePath) { $scriptArgs['ProfilePath'] = $ProfilePath }
        & $AssessScriptPath @scriptArgs *> $null

        if (-not (Test-Path -LiteralPath $tempJson) -or (Get-Item -LiteralPath $tempJson).Length -eq 0) {
            return [PSCustomObject]@{ Available = $false; FullyCompliant = $null; Gaps = @(); Error = 'Re-assessment did not produce a JSON report.' }
        }
        $fresh = Get-Content -LiteralPath $tempJson -Raw | ConvertFrom-Json -ErrorAction Stop
        $gaps = @($fresh.capabilities | Where-Object { "$($_.classification)" -notin @('COMPLIANT', 'KEEP_STRONGER', 'NOT_AVAILABLE') })
        return [PSCustomObject]@{
            Available      = $true
            FullyCompliant = ($gaps.Count -eq 0)
            Gaps           = @($gaps | ForEach-Object { [PSCustomObject]@{ Id = $_.id; Capability = $_.name; Classification = $_.classification } })
            ReassessedAt   = "$($fresh.assessedAt)"
            Error          = $null
        }
    }
    catch {
        return [PSCustomObject]@{ Available = $false; FullyCompliant = $null; Gaps = @(); Error = "$_" }
    }
    finally {
        if (Test-Path -LiteralPath $tempJson) { Remove-Item -LiteralPath $tempJson -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Test-OperationApplied, Test-RulesetOperationApplied, Invoke-FullCdaVerification
