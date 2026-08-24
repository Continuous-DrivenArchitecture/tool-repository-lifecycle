#Requires -Version 5.1
<#
    Orchestration.psm1

    Mode-specific flow (Bootstrap / Finalize / Verify) built on top of the
    pure/discovery primitives in Provisioner.psm1 and the common HTTP
    wrappers in src/common/github/. This is the ONLY module in the
    provisioner lifecycle path that imports MutationGitHub.psm1 and the
    ONLY place that decides WHEN to call a mutating endpoint --
    Provisioner.psm1's comparison functions never do (mirrors the
    adopter lifecycle path's own Apply.psm1 being the sole mutation-
    capable module there; see docs/safety-model.md).
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\..\common\github\ReadOnlyGitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\common\github\MutationGitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Provisioner.psm1') -Force

function Invoke-CapabilityMutation {
    <#
        Single choke point for every mutating call. In -DryRun (or Mode
        Verify), never calls gh  -  the plan item's Result is set to
        'DRY-RUN' (or left as computed) and Action is left as planned.
        Otherwise performs the call and folds the real outcome back into
        the PlanItem so the printed table reflects what actually happened,
        not just what was intended.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$PlanItem,
        [Parameter(Mandatory)] [bool]$DryRun,
        [Parameter(Mandatory)] [scriptblock]$MutationAction
    )

    if ($PlanItem.Action -eq 'NONE' -or $PlanItem.Action -eq 'SKIP') {
        return $PlanItem
    }
    if ($DryRun) {
        $PlanItem.Result = 'DRY-RUN'
        return $PlanItem
    }

    $apiResult = & $MutationAction
    if ($apiResult.Success) {
        $PlanItem.Result = 'PASS'
    }
    else {
        $PlanItem.Result = 'FAIL'
        $kind = if ($apiResult.ErrorKind) { $apiResult.ErrorKind } else { 'Error' }
        $PlanItem.Notes = (@($PlanItem.Notes, "Mutation failed: HTTP $($apiResult.StatusCode) ($kind). $($apiResult.RawBody)") -join ' ').Trim()
    }
    return $PlanItem
}

function Get-RepositorySettingsPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $RepoData, [Parameter(Mandatory)] $Desired, [Parameter(Mandatory)] [string]$Mode, [Parameter(Mandatory)] [bool]$DryRun, [Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $fieldMap = [ordered]@{
        'Default branch'          = @{ Api = 'default_branch'; Current = $RepoData.default_branch; Desired = $Desired.defaultBranch }
        'Delete branch on merge'  = @{ Api = 'delete_branch_on_merge'; Current = [bool]$RepoData.delete_branch_on_merge; Desired = [bool]$Desired.deleteBranchOnMerge }
        'Allow squash merge'      = @{ Api = 'allow_squash_merge'; Current = [bool]$RepoData.allow_squash_merge; Desired = [bool]$Desired.allowSquashMerge }
        'Allow merge commit'      = @{ Api = 'allow_merge_commit'; Current = [bool]$RepoData.allow_merge_commit; Desired = [bool]$Desired.allowMergeCommit }
        'Allow rebase merge'      = @{ Api = 'allow_rebase_merge'; Current = [bool]$RepoData.allow_rebase_merge; Desired = [bool]$Desired.allowRebaseMerge }
        'Allow auto-merge'        = @{ Api = 'allow_auto_merge'; Current = [bool]$RepoData.allow_auto_merge; Desired = [bool]$Desired.allowAutoMerge }
    }

    $items = @()
    $patchBody = @{}
    foreach ($name in $fieldMap.Keys) {
        $f = $fieldMap[$name]
        $item = New-PlanItem -Capability $name -Current $f.Current -Desired $f.Desired
        $items += $item
        if ($item.Action -eq 'UPDATE') { $patchBody[$f.Api] = $f.Desired }
    }

    if ($patchBody.Count -gt 0 -and $Mode -ne 'Verify') {
        $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo" -Method PATCH -BodyObject $patchBody }
        foreach ($item in ($items | Where-Object { $_.Action -eq 'UPDATE' })) {
            Invoke-CapabilityMutation -PlanItem $item -DryRun $DryRun -MutationAction $mutation | Out-Null
        }
        # All UPDATE items share one API call; if it succeeded, PASS was
        # already stamped per-item by Invoke-CapabilityMutation because the
        # scriptblock re-runs per item  -  cheap and keeps each item accurate
        # even though it duplicates one PATCH call per differing field. For
        # a handful of settings this is a deliberate simplicity-over-
        # micro-optimization tradeoff.
    }
    return $items
}

function Get-ActionsPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Desired, [Parameter(Mandatory)] [string]$Mode, [Parameter(Mandatory)] [bool]$DryRun, [Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $items = @()

    $permResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions"
    $permCurrent = if ($permResult.Success) { $permResult.Data } else { $null }

    $enabledItem = New-PlanItem -Capability 'Actions enabled' -Current ([bool]$permCurrent.enabled) -Desired ([bool]$Desired.enabled) -Applicable ($null -ne $permCurrent)
    $shaItem = $null

    if ($null -ne $permCurrent) {
        $shaCurrent = if ($null -ne $permCurrent.PSObject.Properties['sha_pinning_required']) { [bool]$permCurrent.sha_pinning_required } else { $null }
        if ($null -eq $shaCurrent) {
            $shaItem = New-PlanItem -Capability 'SHA pinning required' -Current $null -Desired ([bool]$Desired.shaPinningRequired) -Applicable $false -Notes 'Field absent from API response for this repo/plan.'
        }
        else {
            $shaItem = New-PlanItem -Capability 'SHA pinning required' -Current $shaCurrent -Desired ([bool]$Desired.shaPinningRequired)
        }
    }
    else {
        $shaItem = New-PlanItem -Capability 'SHA pinning required' -Current $null -Desired ([bool]$Desired.shaPinningRequired) -Applicable $false
    }

    $allowedItem = New-PlanItem -Capability 'Allowed actions policy' -Current ($(if ($permCurrent) { $permCurrent.allowed_actions } else { $null })) -Desired $Desired.allowedActionsPolicy -Applicable ($null -ne $permCurrent)

    $items += $enabledItem, $shaItem, $allowedItem

    if ($null -ne $permCurrent -and $Mode -ne 'Verify' -and (@($enabledItem, $shaItem, $allowedItem) | Where-Object { $_.Action -eq 'UPDATE' })) {
        $body = @{
            enabled            = [bool]$Desired.enabled
            allowed_actions    = $Desired.allowedActionsPolicy
            sha_pinning_required = [bool]$Desired.shaPinningRequired
        }
        $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo/actions/permissions" -Method PUT -BodyObject $body }
        foreach ($item in @($enabledItem, $shaItem, $allowedItem) | Where-Object { $_.Action -eq 'UPDATE' }) {
            Invoke-CapabilityMutation -PlanItem $item -DryRun $DryRun -MutationAction $mutation | Out-Null
        }
    }

    # Workflow-level default permissions
    $wfResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions/workflow"
    $wfCurrent = if ($wfResult.Success) { $wfResult.Data } else { $null }
    $defaultPermItem = New-PlanItem -Capability 'Default workflow permissions' -Current ($(if ($wfCurrent) { $wfCurrent.default_workflow_permissions } else { $null })) -Desired $Desired.defaultWorkflowPermissions -Applicable ($null -ne $wfCurrent)
    $prApprovalItem = New-PlanItem -Capability 'Workflows can approve PRs' -Current ($(if ($wfCurrent) { [bool]$wfCurrent.can_approve_pull_request_reviews } else { $null })) -Desired ([bool]$Desired.canApprovePullRequestReviews) -Applicable ($null -ne $wfCurrent)
    $items += $defaultPermItem, $prApprovalItem

    if ($null -ne $wfCurrent -and $Mode -ne 'Verify' -and (@($defaultPermItem, $prApprovalItem) | Where-Object { $_.Action -eq 'UPDATE' })) {
        $body = @{ default_workflow_permissions = $Desired.defaultWorkflowPermissions; can_approve_pull_request_reviews = [bool]$Desired.canApprovePullRequestReviews }
        $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo/actions/permissions/workflow" -Method PUT -BodyObject $body }
        foreach ($item in @($defaultPermItem, $prApprovalItem) | Where-Object { $_.Action -eq 'UPDATE' }) {
            Invoke-CapabilityMutation -PlanItem $item -DryRun $DryRun -MutationAction $mutation | Out-Null
        }
    }

    # Selected-actions allow-list -- only meaningful once allowed_actions is
    # (or is about to become) 'selected'. Conflict-checked against the
    # repository's OWN workflow files before ever restricting anything.
    $willBeSelected = ($Desired.allowedActionsPolicy -eq 'selected')
    if ($willBeSelected) {
        $externalOwners = Get-WorkflowExternalActionOwners -Owner $Owner -Repo $Repo
        $knownOwners = @($Desired.knownGitHubOwnedActionOwners)
        $desiredPatterns = @($Desired.selectedActions.patternsAllowed)
        $unknownOwners = @($externalOwners | Where-Object { ($_ -notin $knownOwners) -and ($desiredPatterns -notcontains "$_/*") })

        if ($unknownOwners.Count -gt 0) {
            $items += [PSCustomObject]@{
                Capability = 'Selected-actions allow-list'
                Current    = '<not applied>'
                Desired    = "github_owned=$($Desired.selectedActions.githubOwnedAllowed), verified=$($Desired.selectedActions.verifiedAllowed)"
                Action     = 'POLICY_CONFLICT'
                Result     = 'PENDING'
                Notes      = "Workflows reference action(s) from owner(s) not covered by the proposed policy: $($unknownOwners -join ', '). Not applying a restrictive allowed-actions list until reviewed."
            }
        }
        else {
            $selResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions/selected-actions"
            $selCurrent = if ($selResult.Success) { $selResult.Data } else { $null }
            $desiredGitHubOwned = [bool]$Desired.selectedActions.githubOwnedAllowed
            $desiredVerified = [bool]$Desired.selectedActions.verifiedAllowed

            $selMatches = $false
            if ($null -ne $selCurrent) {
                $selMatches = ([bool]$selCurrent.github_owned_allowed -eq $desiredGitHubOwned) -and
                           ([bool]$selCurrent.verified_allowed -eq $desiredVerified) -and
                           (Compare-StringArray -A @($selCurrent.patterns_allowed) -B $desiredPatterns)
            }

            $selItem = [PSCustomObject]@{
                Capability = 'Selected-actions allow-list'
                Current    = $(if ($null -eq $selCurrent) { '<unknown>' } else { "github_owned=$([bool]$selCurrent.github_owned_allowed), verified=$([bool]$selCurrent.verified_allowed), patterns=[$($selCurrent.patterns_allowed -join ',')]" })
                Desired    = "github_owned=$desiredGitHubOwned, verified=$desiredVerified, patterns=[$($desiredPatterns -join ',')]"
                Action     = if ($null -eq $selCurrent) { 'SKIP' } elseif ($selMatches) { 'NONE' } else { 'UPDATE' }
                Result     = if ($null -eq $selCurrent) { 'UNKNOWN' } elseif ($selMatches) { 'PASS' } else { 'DRIFT' }
                Notes      = ''
            }
            $items += $selItem

            if ($null -ne $selCurrent -and -not $selMatches -and $Mode -ne 'Verify') {
                $body = @{ github_owned_allowed = $desiredGitHubOwned; verified_allowed = $desiredVerified; patterns_allowed = $desiredPatterns }
                $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo/actions/permissions/selected-actions" -Method PUT -BodyObject $body }
                Invoke-CapabilityMutation -PlanItem $selItem -DryRun $DryRun -MutationAction $mutation | Out-Null
            }
        }
    }

    return $items
}

function Get-SecurityPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $RepoData, [Parameter(Mandatory)] $Desired, [Parameter(Mandatory)] [string[]]$Languages, [Parameter(Mandatory)] [string]$Mode, [Parameter(Mandatory)] [bool]$DryRun, [Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $items = @()
    $sa = $RepoData.security_and_analysis
    $fieldMap = [ordered]@{
        'Secret scanning'                = @{ Api = 'secret_scanning'; Current = $sa.secret_scanning.status; Desired = $Desired.secretScanning }
        'Secret scanning push protection' = @{ Api = 'secret_scanning_push_protection'; Current = $sa.secret_scanning_push_protection.status; Desired = $Desired.secretScanningPushProtection }
        'Dependabot security updates'    = @{ Api = 'dependabot_security_updates'; Current = $sa.dependabot_security_updates.status; Desired = $Desired.dependabotSecurityUpdates }
    }
    $patchSA = @{}
    foreach ($name in $fieldMap.Keys) {
        $f = $fieldMap[$name]
        $item = New-PlanItem -Capability $name -Current $f.Current -Desired $f.Desired -Applicable ($null -ne $f.Current)
        $items += $item
        if ($item.Action -eq 'UPDATE') { $patchSA[$f.Api] = @{ status = $f.Desired } }
    }
    if ($patchSA.Count -gt 0 -and $Mode -ne 'Verify') {
        $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo" -Method PATCH -BodyObject @{ security_and_analysis = $patchSA } }
        foreach ($item in ($items | Where-Object { $_.Action -eq 'UPDATE' })) {
            Invoke-CapabilityMutation -PlanItem $item -DryRun $DryRun -MutationAction $mutation | Out-Null
        }
    }

    # Dependabot / vulnerability alerts: distinct endpoint, 204 = enabled, 404 = disabled.
    $vaResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/vulnerability-alerts"
    $vaEnabled = $vaResult.Success  # 204 -> Success=true; 404 -> Success=false
    $vaApplicable = ($vaResult.Success -or $vaResult.ErrorKind -eq 'NotFound')
    $vaItem = New-PlanItem -Capability 'Dependabot vulnerability alerts' -Current $vaEnabled -Desired ([bool]$Desired.vulnerabilityAlerts) -Applicable $vaApplicable
    $items += $vaItem
    if ($vaApplicable -and $vaItem.Action -eq 'UPDATE' -and $Mode -ne 'Verify') {
        $method = if ([bool]$Desired.vulnerabilityAlerts) { 'PUT' } else { 'DELETE' }
        $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo/vulnerability-alerts" -Method $method }
        Invoke-CapabilityMutation -PlanItem $vaItem -DryRun $DryRun -MutationAction $mutation | Out-Null
    }

    # CodeQL default setup -- only applicable if the repo actually contains
    # a supported language, per CDA npm Library Profile v1's SHOULD scope.
    $applicableLangs = @($Desired.codeQLDefaultSetup.applicableLanguages)
    $codeQLApplicable = [bool](@($Languages) | Where-Object { $_ -in $applicableLangs })
    $cqResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/code-scanning/default-setup"
    $cqCurrentState = if ($cqResult.Success) { $cqResult.Data.state } else { $null }
    $cqItem = New-PlanItem -Capability 'CodeQL default setup' -Current $cqCurrentState -Desired 'configured' -Applicable ($codeQLApplicable -and $cqResult.Success) -Notes $(if (-not $codeQLApplicable) { 'Repository contains no JavaScript/TypeScript.' } elseif (-not $cqResult.Success) { 'code-scanning/default-setup endpoint unavailable for this repository/plan.' } else { '' })
    $items += $cqItem
    if ($codeQLApplicable -and $cqResult.Success -and $cqItem.Action -eq 'UPDATE' -and $Mode -ne 'Verify') {
        $body = @{ state = 'configured'; query_suite = $Desired.codeQLDefaultSetup.querySuite; languages = @($Desired.codeQLDefaultSetup.setupLanguages) }
        $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo/code-scanning/default-setup" -Method PATCH -BodyObject $body }
        Invoke-CapabilityMutation -PlanItem $cqItem -DryRun $DryRun -MutationAction $mutation | Out-Null
    }

    # Dependency review: informational only, by explicit design (section 11/23).
    $items += [PSCustomObject]@{
        Capability = 'Dependency review (PR diff feature)'
        Current    = 'automatic on public repos'
        Desired    = 'automatic on public repos'
        Action     = 'SKIP'
        Result     = 'NOT AVAILABLE'
        Notes       = 'No bare API toggle exists for this; not evaluated further by this provisioner version.'
    }
    $items += [PSCustomObject]@{
        Capability = 'Dependency review (enforcement workflow)'
        Current    = 'not managed'
        Desired    = 'not managed by this provisioner version'
        Action     = 'SKIP'
        Result     = 'NOT AVAILABLE'
        Notes      = 'dependency-review-action is never auto-added; add it explicitly in a future, reviewed change if desired.'
    }

    return $items
}

function Get-RulesetPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $CdaProfile, [Parameter(Mandatory)] [string]$DefaultBranch, [Parameter(Mandatory)] [string]$Mode, [Parameter(Mandatory)] [bool]$DryRun, [Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $items = @()
    $evidence = Test-RequiredCheckEvidence -Owner $Owner -Repo $Repo -DefaultBranch $DefaultBranch
    $rulesetState = Get-CurrentRulesetState -Owner $Owner -Repo $Repo

    # --- Required-check evidence: always reported, never mutates anything ---
    $checkNote = if ($evidence.Found) {
        "ci-required has executed on '$DefaultBranch' (last conclusion: $($evidence.Conclusion))."
    }
    else {
        "ci-required has not executed yet; open/merge a bootstrap PR first."
    }
    $items += [PSCustomObject]@{
        Capability = 'Required check execution evidence'
        Current    = $(if ($evidence.Found) { 'found' } else { 'absent' })
        Desired    = 'found'
        Action     = 'SKIP'
        Result     = if ($evidence.Found) { 'PASS' } else { 'NOT AVAILABLE' }
        Notes      = $checkNote
    }

    if ($Mode -eq 'Finalize' -and -not $evidence.Found) {
        $items += [PSCustomObject]@{
            Capability = 'Protect main (ruleset)'
            Current    = $rulesetState.State
            Desired    = 'active, with ci-required required'
            Action     = 'FAIL_SAFE'
            Result     = 'PENDING'
            Notes      = $checkNote
        }
        return $items # deliberately do not touch the ruleset at all
    }

    if ($rulesetState.State -eq 'Multiple') {
        $items += [PSCustomObject]@{
            Capability = 'Protect main (ruleset)'
            Current    = "multiple rulesets named 'Protect main' (ids: $($rulesetState.Ids -join ', '))"
            Desired    = 'exactly one ruleset named "Protect main"'
            Action     = 'FAIL_SAFE'
            Result     = 'DRIFT'
            Notes      = 'Ambiguous  -  will not create or modify any ruleset until this is resolved manually.'
        }
        return $items
    }
    if ($rulesetState.State -eq 'Unknown') {
        $items += [PSCustomObject]@{
            Capability = 'Protect main (ruleset)'
            Current    = '<unknown>'
            Desired    = 'active'
            Action     = 'SKIP'
            Result     = 'UNKNOWN'
            Notes      = 'Could not read ruleset state from the API.'
        }
        return $items
    }

    # Include the required-status-checks rule only when we have real
    # evidence it exists  -  in Bootstrap this simply means "not yet", in
    # Finalize we already returned above if evidence was missing.
    $includeRsc = $evidence.Found
    $desiredBody = New-DesiredRulesetBody -CdaProfile $CdaProfile -IncludeRequiredStatusChecks $includeRsc

    if ($rulesetState.State -eq 'Absent') {
        $item = [PSCustomObject]@{
            Capability = 'Protect main (ruleset)'
            Current    = 'absent'
            Desired    = $(if ($includeRsc) { 'active, with ci-required required' } else { 'active, ci-required deferred' })
            Action     = 'CREATE'
            Result     = 'DRIFT'
            Notes      = $(if (-not $includeRsc) { "ci-required omitted for now ($checkNote)" } else { '' })
        }
        $items += $item
        if ($Mode -ne 'Verify') {
            $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo/rulesets" -Method POST -BodyObject $desiredBody }
            Invoke-CapabilityMutation -PlanItem $item -DryRun $DryRun -MutationAction $mutation | Out-Null
        }
        return $items
    }

    # State -eq 'Single'
    $rulesetMatches = Compare-RulesetToDesired -CurrentDetail $rulesetState.Detail -DesiredBody $desiredBody
    $item = [PSCustomObject]@{
        Capability = 'Protect main (ruleset)'
        Current    = $(if ($rulesetMatches) { 'matches desired state' } else { 'exists, differs from desired state' })
        Desired    = $(if ($includeRsc) { 'active, with ci-required required' } else { 'active, ci-required deferred' })
        Action     = if ($rulesetMatches) { 'NONE' } else { 'UPDATE' }
        Result     = if ($rulesetMatches) { 'PASS' } else { 'DRIFT' }
        Notes      = $(if (-not $includeRsc) { "ci-required omitted for now ($checkNote)" } else { '' })
    }
    $items += $item
    if (-not $rulesetMatches -and $Mode -ne 'Verify') {
        $rulesetId = $rulesetState.Ids[0]
        $mutation = { Invoke-MutationGitHub -Path "repos/$Owner/$Repo/rulesets/$rulesetId" -Method PUT -BodyObject $desiredBody }
        Invoke-CapabilityMutation -PlanItem $item -DryRun $DryRun -MutationAction $mutation | Out-Null
    }
    return $items
}

function Invoke-Provisioning {
    <#
        Top-level entry point called by provision-npm-library.ps1. Returns
        @{ Plan = <array of PlanItem>; ExitCode = <int>; Blocked = <bool>; BlockedReason = <string|$null> }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [ValidateSet('Bootstrap', 'Finalize', 'Verify')] [string]$Mode,
        [Parameter(Mandatory)] [bool]$DryRun,
        [Parameter(Mandatory)] $CdaProfile,
        [switch]$AllowFork
    )

    $nameCheck = Test-RepositoryNameFormat -Repository $Repository
    if (-not $nameCheck.Valid) {
        return [PSCustomObject]@{ Plan = @(); ExitCode = 2; Blocked = $true; BlockedReason = $nameCheck.Reason }
    }

    if (-not (Test-GhAuthenticated)) {
        return [PSCustomObject]@{ Plan = @(); ExitCode = 2; Blocked = $true; BlockedReason = "'gh auth status' failed. Authenticate gh before running the provisioner." }
    }

    # -RejectForks: the provisioner lifecycle path's one deliberate
    # difference from the adopter path's default (see
    # src/common/repository/Validation.psm1's own header comment) --
    # provisioning a fork is refused unless the caller explicitly opts in.
    $eligibility = Test-RepositoryEligibility -Owner $nameCheck.Owner -Repo $nameCheck.Repo -RejectForks -AllowFork:$AllowFork
    if (-not $eligibility.Eligible) {
        return [PSCustomObject]@{ Plan = @(); ExitCode = 2; Blocked = $true; BlockedReason = $eligibility.Reason }
    }

    $owner = $nameCheck.Owner
    $repo = $nameCheck.Repo
    $repoData = $eligibility.RepoData
    $languages = Get-RepositoryLanguages -Owner $owner -Repo $repo

    $plan = @()
    $plan += Get-RepositorySettingsPlan -RepoData $repoData -Desired $CdaProfile.repositorySettings -Mode $Mode -DryRun $DryRun -Owner $owner -Repo $repo
    $plan += Get-ActionsPlan -Desired $CdaProfile.actions -Mode $Mode -DryRun $DryRun -Owner $owner -Repo $repo
    $plan += Get-SecurityPlan -RepoData $repoData -Desired $CdaProfile.security -Languages $languages -Mode $Mode -DryRun $DryRun -Owner $owner -Repo $repo
    $plan += Get-RulesetPlan -CdaProfile $CdaProfile -DefaultBranch $repoData.default_branch -Mode $Mode -DryRun $DryRun -Owner $owner -Repo $repo
    $plan += [PSCustomObject]@{
        Capability = 'npm Trusted Publisher'
        Current    = '<not managed>'
        Desired    = $CdaProfile.npm.trustedPublisher
        Action     = 'SKIP'
        Result     = 'NOT AVAILABLE'
        Notes      = 'Out of scope for this provisioner version  -  see runbooks/setup-repository.md, Section B5.'
    }

    $exitCode = Get-ProvisioningExitCode -Plan $plan -Mode $Mode -DryRun $DryRun
    return [PSCustomObject]@{ Plan = $plan; ExitCode = $exitCode; Blocked = $false; BlockedReason = $null }
}

function Get-ProvisioningExitCode {
    <#
        0 = compliant / operation successful
        1 = drift found (Verify, or -DryRun with pending changes) / a real mutation failed
        2 = a prerequisite was not met (FAIL_SAFE: missing ci-required evidence, ruleset name conflict, ...)
        3 = state could not be determined (permission denied / API limitation / transport error)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array]$Plan, [Parameter(Mandatory)] [string]$Mode, [Parameter(Mandatory)] [bool]$DryRun)

    if ($Plan | Where-Object { $_.Result -eq 'FAIL' }) { return 1 }
    if ($Plan | Where-Object { $_.Action -eq 'FAIL_SAFE' }) { return 2 }
    if ($Plan | Where-Object { $_.Result -eq 'UNKNOWN' }) { return 3 }

    if ($Mode -eq 'Verify' -or $DryRun) {
        if ($Plan | Where-Object { $_.Result -in @('DRIFT', 'DRY-RUN') }) { return 1 }
        return 0
    }

    return 0
}

function Format-PlanTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array]$Plan)

    $rows = $Plan | ForEach-Object {
        [PSCustomObject]@{
            Capability = $_.Capability
            Current    = "$($_.Current)"
            Desired    = "$($_.Desired)"
            Action     = $_.Action
            Result     = $_.Result
        }
    }
    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
}

Export-ModuleMember -Function Invoke-Provisioning, Format-PlanTable, Get-ProvisioningExitCode, Invoke-CapabilityMutation, Get-RepositorySettingsPlan, Get-ActionsPlan, Get-SecurityPlan, Get-RulesetPlan
