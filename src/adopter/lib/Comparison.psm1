#Requires -Version 5.1
<#
    Comparison.psm1

    Orchestrates Discovery.psm1 (network reads) + Classification.psm1
    (pure decisions) into one assessment object. This is the only module
    that combines both -- Discovery never classifies, Classification
    never fetches.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Classification.psm1') -Force

function Get-RulesetName {
    param($Ruleset)
    if ($Ruleset.PSObject.Properties['name']) { return $Ruleset.name }
    return '(unknown)'
}

function New-RulesetCapabilityRows {
    <#
        Handles the "no other ruleset assumed to be Protect main" and
        "multiple rulesets" cases explicitly, per brief sections 11/13.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $RulesetsState, [Parameter(Mandatory)] $TargetRuleset)

    $rows = @()

    if (-not $RulesetsState.Available) {
        $rows += New-CapabilityRow -Capability 'Rulesets' -Current 'unknown' -Target 'exactly one active ruleset named "Protect main"' -Classification UNKNOWN -Rationale "Could not list rulesets (ErrorKind: $($RulesetsState.ErrorKind))."
        return $rows
    }

    $named = @($RulesetsState.Rulesets | Where-Object { (Get-RulesetName $_) -eq $TargetRuleset.name })
    $others = @($RulesetsState.Rulesets | Where-Object { (Get-RulesetName $_) -ne $TargetRuleset.name })

    foreach ($o in $others) {
        # -Destructive: found during live sandbox integration testing
        # (2026-08-23) -- the only concrete Apply-v1 mutation available
        # for "this ruleset shouldn't exist per the target profile" is
        # deleting it, an irreversible removal of a protection mechanism.
        # Marking it destructive requires explicit -ApproveOperation
        # regardless of classification (see Approval.psm1's
        # -ApproveSafeChanges destructive-operation guard), matching the
        # same standard already applied to branch and secret deletion.
        $rows += New-CapabilityRow -Capability "Ruleset: $(Get-RulesetName $o)" -Current "target=$($o.target), enforcement=$($o.enforcement)" -Target 'n/a (not part of the npm-library profile)' -Classification REVIEW_REQUIRED -Rationale 'A ruleset not named "Protect main" exists. It may be repo-specific, organization-inherited, or legacy -- it is not automatically judged incorrect. Needs maintainer review to classify.' -Destructive
    }

    if ($named.Count -eq 0) {
        $rows += New-CapabilityRow -Capability 'Ruleset: Protect main' -Current 'absent' -Target 'active, PR required, ci-required, force-push/deletion blocked, no bypass actors' -Classification REVIEW_REQUIRED -Rationale 'No ruleset named "Protect main" exists. Creating one is a real behavioral change (blocks direct pushes) and must be reviewed, not silently applied.'
        return $rows
    }
    if ($named.Count -gt 1) {
        $ids = @($named | ForEach-Object { $_.id }) -join ', '
        $rows += New-CapabilityRow -Capability 'Ruleset: Protect main' -Current "multiple rulesets named 'Protect main' (ids: $ids)" -Target 'exactly one' -Classification BLOCKED -Rationale 'Ambiguous which ruleset is authoritative. Must be resolved manually before any comparison or migration involving this ruleset is meaningful.'
        return $rows
    }

    $rs = $named[0]
    if ($rs.PSObject.Properties['FetchFailed'] -and $rs.FetchFailed) {
        $rows += New-CapabilityRow -Capability 'Ruleset: Protect main' -Current 'exists, detail unreadable' -Target 'active, fully specified' -Classification UNKNOWN -Rationale "Ruleset summary found but its detail could not be fetched (ErrorKind: $($rs.ErrorKind))."
        return $rows
    }

    $rows += New-CapabilityRow -Capability 'Ruleset: Protect main enforcement' -Current $rs.enforcement -Target $TargetRuleset.enforcement -Classification $(if ($rs.enforcement -eq $TargetRuleset.enforcement) { 'COMPLIANT' } else { 'REVIEW_REQUIRED' }) -Rationale 'Ruleset enforcement mode.'

    $bypassCount = @($rs.bypass_actors).Count
    if ($bypassCount -eq 0) {
        $rows += New-CapabilityRow -Capability 'Ruleset: bypass actors' -Current 'none' -Target 'none' -Classification COMPLIANT -Rationale 'No bypass actors configured, matching the CDA target.'
    }
    else {
        $actorDesc = ($rs.bypass_actors | ForEach-Object { "$($_.actor_type)#$($_.actor_id)" }) -join ', '
        $rows += New-CapabilityRow -Capability 'Ruleset: bypass actors' -Current $actorDesc -Target 'none' -Classification REVIEW_REQUIRED -Rationale 'A bypass actor exists (commonly a legacy release-sentinel App under the old release model). CDA Model B needs no bypass actor. Removing one is a governance/release-architecture decision, not a mechanical change -- confirm nothing still depends on it before removal.'
    }

    $pr = $rs.rules | Where-Object { $_.type -eq 'pull_request' } | Select-Object -First 1
    if ($null -eq $pr) {
        $rows += New-CapabilityRow -Capability 'Ruleset: pull request required' -Current 'no pull_request rule' -Target 'required' -Classification REVIEW_REQUIRED -Rationale 'main can be pushed to directly today. Requiring a PR is a real behavioral change.'
    }
    else {
        $rows += Get-ApprovalCountClassification -CurrentCount ([int]$pr.parameters.required_approving_review_count) -TargetCount ([int]$TargetRuleset.pullRequest.requiredApprovingReviewCount)
        $rows += New-CapabilityRow -Capability 'Ruleset: conversation resolution' -Current ([bool]$pr.parameters.required_review_thread_resolution) -Target ([bool]$TargetRuleset.pullRequest.requiredReviewThreadResolution) -Classification $(if ([bool]$pr.parameters.required_review_thread_resolution -eq [bool]$TargetRuleset.pullRequest.requiredReviewThreadResolution) { 'COMPLIANT' } elseif ([bool]$pr.parameters.required_review_thread_resolution) { 'KEEP_STRONGER' } else { 'REVIEW_REQUIRED' }) -Rationale 'Whether unresolved review threads block merge.'
        $currentMethods = @($pr.parameters.allowed_merge_methods | Sort-Object)
        $targetMethods = @($TargetRuleset.pullRequest.allowedMergeMethods | Sort-Object)
        $methodsMatch = ($currentMethods.Count -eq $targetMethods.Count) -and (-not (Compare-Object $currentMethods $targetMethods))
        $rows += New-CapabilityRow -Capability 'Ruleset: allowed merge methods' -Current ($currentMethods -join ',') -Target ($targetMethods -join ',') -Classification $(if ($methodsMatch) { 'COMPLIANT' } else { 'REVIEW_REQUIRED' }) -Rationale 'Merge-method restriction affects contributor workflow and commit-history shape; a change here is not mechanical.'
    }

    $rsc = $rs.rules | Where-Object { $_.type -eq 'required_status_checks' } | Select-Object -First 1
    if ($null -eq $rsc) {
        $rows += New-CapabilityRow -Capability 'Ruleset: required status checks' -Current 'none' -Target "ci-required, strict" -Classification REVIEW_REQUIRED -Rationale 'No required status check is configured today. This tool does not require an existing repository to already have "ci-required" -- introducing one (and the matrix-independent summary job it depends on) is future migration work, not something to assume as missing/broken.' -RequiresManualChange
    }
    else {
        $contexts = @($rsc.parameters.required_status_checks | ForEach-Object { $_.context })
        $hasCiRequired = ($contexts -contains $TargetRuleset.requiredStatusChecks.context)
        $matrixLike = @($contexts | Where-Object { $_ -match '\(\s*\d+\s*\)$' })
        if ($hasCiRequired) {
            $rows += New-CapabilityRow -Capability 'Ruleset: required status checks' -Current ($contexts -join ',') -Target $TargetRuleset.requiredStatusChecks.context -Classification COMPLIANT -Rationale 'Already requires the CDA target check.'
        }
        elseif ($matrixLike.Count -gt 0) {
            # NOT -RequiresManualChange (fixed during a real PRODUCTION
            # migration, 2026-08-23): swapping an EXISTING
            # required_status_checks rule's context list is a pure
            # ruleset PUT (Apply.psm1's Get-RulesetOperationMutationSpec
            # 'ruleset.requiredStatusChecks' case), not a repository file
            # edit -- unlike CREATING the ci-required job itself (see
            # 'Release: create stable ci-required job', which genuinely
            # does require a workflow-file PR). Marking this row manual
            # was correct before that mutation existed; it silently
            # blocked Apply from ever reaching working code afterward.
            $rows += New-CapabilityRow -Capability 'Ruleset: required status checks' -Current ($contexts -join ',') -Target $TargetRuleset.requiredStatusChecks.context -Classification REVIEW_REQUIRED -Rationale "Required check(s) look matrix-leg-dependent ($($matrixLike -join ', ')), which breaks silently whenever the CI matrix changes. Migrating to a stable, matrix-independent summary check (ci-required) is recommended, but replacing a live required check is a real behavioral change needing review and a verified replacement before the old one is removed. Apply re-verifies ci-required has real execution evidence before ever making this change."
        }
        else {
            # Same reasoning as the matrix-leg branch above.
            $rows += New-CapabilityRow -Capability 'Ruleset: required status checks' -Current ($contexts -join ',') -Target $TargetRuleset.requiredStatusChecks.context -Classification REVIEW_REQUIRED -Rationale 'Existing required check(s) do not match the CDA target name. Do not replace a live required check without confirming the replacement actually runs and passes first. Apply re-verifies the target check has real execution evidence before ever making this change.'
        }
        $rows += New-CapabilityRow -Capability 'Ruleset: strict status checks' -Current ([bool]$rsc.parameters.strict_required_status_checks_policy) -Target ([bool]$TargetRuleset.requiredStatusChecks.strict) -Classification $(if ([bool]$rsc.parameters.strict_required_status_checks_policy -eq [bool]$TargetRuleset.requiredStatusChecks.strict) { 'COMPLIANT' } elseif ([bool]$rsc.parameters.strict_required_status_checks_policy) { 'KEEP_STRONGER' } else { 'REVIEW_REQUIRED' }) -Rationale 'Whether the PR branch must be up to date with the base before merge.'
    }

    $nff = [bool]($rs.rules | Where-Object { $_.type -eq 'non_fast_forward' })
    $rows += New-CapabilityRow -Capability 'Ruleset: force push blocked' -Current $nff -Target $true -Classification $(if ($nff) { 'COMPLIANT' } else { 'REVIEW_REQUIRED' }) -Rationale 'Force-push protection on the default branch.'

    $del = [bool]($rs.rules | Where-Object { $_.type -eq 'deletion' })
    $rows += New-CapabilityRow -Capability 'Ruleset: deletion blocked' -Current $del -Target $true -Classification $(if ($del) { 'COMPLIANT' } else { 'REVIEW_REQUIRED' }) -Rationale 'Branch-deletion protection on the default branch.'

    return $rows
}

function Get-ReleaseModelSummary {
    <#
        Describes the REAL release model discovered -- never assumes
        Model B, never treats "different" as "broken" (brief section 18).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Workflows, [Parameter(Mandatory)] [AllowNull()] $ReleaseConfig, [Parameter(Mandatory)] $SecretsMeta)

    # BUG FIX (found during a real PRODUCTION migration, 2026-08-23): this
    # used to require the release logic to live in a file/workflow whose
    # NAME contains "release" (e.g. release.yml). A real repository had
    # its release job embedded as a conditional job inside ci.yml (a
    # workflow literally named "CI", gated on `needs: [validate, audit]`
    # so it only runs after the rest of CI passes -- a legitimate,
    # arguably safer pattern than a separate file) and was reported as
    # NO_RELEASE_WORKFLOW_FOUND despite having a real, working
    # semantic-release + npm-Trusted-Publishing release job. Fall back to
    # CONTENT (does this workflow's text actually reference
    # semantic-release?) whenever no name match exists, rather than
    # relying on naming convention alone.
    $releaseWorkflow = $Workflows | Where-Object { $_.Name -match '(?i)release' -or $_.File -match '(?i)release' } | Select-Object -First 1
    if (-not $releaseWorkflow) {
        $releaseWorkflow = $Workflows | Where-Object { $_.ReferencesSemanticRelease } | Select-Object -First 1
    }

    $usesSentinel = [bool]($releaseWorkflow -and $releaseWorkflow.ReferencesSentinel)
    $usesSemanticRelease = [bool]($releaseWorkflow -and $releaseWorkflow.ReferencesSemanticRelease)
    $usesNpmToken = [bool]($releaseWorkflow -and $releaseWorkflow.ReferencesNpmToken)
    $usesIdToken = [bool]($releaseWorkflow -and $releaseWorkflow.ReferencesIdToken)

    $hasGitPlugin = $false
    $hasChangelogPlugin = $false
    if ($ReleaseConfig) {
        # BUG FIX (found during a real PRODUCTION migration, 2026-08-23):
        # '@semantic-release/git' -- with no boundary after it -- also
        # matches as a plain substring of '@semantic-release/github',
        # which is a DIFFERENT, correct, required plugin. A release
        # config with @semantic-release/github present but
        # @semantic-release/git genuinely removed was still reported as
        # needing the git plugin removed. (?!hub) excludes exactly that
        # one real collision without otherwise narrowing the match.
        $hasGitPlugin = [bool]($ReleaseConfig.Text -match '@semantic-release/git(?!hub)')
        $hasChangelogPlugin = [bool]($ReleaseConfig.Text -match '@semantic-release/changelog')
    }

    $model = if ($usesSemanticRelease -and $hasGitPlugin -and $usesSentinel) {
        'LEGACY_MODEL_A (semantic-release + @semantic-release/git release commit + sentinel bypass)'
    }
    elseif ($usesSemanticRelease -and -not $hasGitPlugin -and -not $usesSentinel -and $usesIdToken) {
        'CDA_MODEL_B (immutable main, semantic-release without @semantic-release/git, OIDC)'
    }
    elseif ($usesSemanticRelease) {
        'SEMANTIC_RELEASE_VARIANT (does not cleanly match legacy Model A or CDA Model B -- inspect manually)'
    }
    elseif ($releaseWorkflow) {
        'NON_SEMANTIC_RELEASE (a release-shaped workflow exists but does not appear to use semantic-release)'
    }
    else {
        'NO_RELEASE_WORKFLOW_FOUND'
    }

    return [PSCustomObject]@{
        Model                     = $model
        ReleaseWorkflowFile       = if ($releaseWorkflow) { $releaseWorkflow.File } else { $null }
        UsesSemanticRelease       = $usesSemanticRelease
        UsesSentinelPattern       = $usesSentinel
        UsesNpmTokenReference     = $usesNpmToken
        UsesIdTokenOidc           = $usesIdToken
        HasSemanticReleaseGitPlugin = $hasGitPlugin
        HasSemanticReleaseChangelogPlugin = $hasChangelogPlugin
    }
}

function New-ReleaseMigrationRows {
    <#
        Explicit, individually-approvable checklist items for moving from
        the discovered release model toward CDA Model B. Every one of
        these is a repository FILE change (a workflow, a semantic-release
        config, a Dependabot config) -- none of them can be executed via
        a GitHub settings API call, so every row here carries
        -RequiresManualChange. Apply must never attempt to mutate these;
        it can only report them as pending manual work (see brief section
        25). Only emitted when actually relevant -- a repository already
        on CDA Model B with no legacy plugins gets none of these rows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ReleaseModel, [Parameter(Mandatory)] [bool]$DependabotTargetsDevelop)

    $rows = @()

    if ($ReleaseModel.Model -notmatch '^CDA_MODEL_B') {
        $rows += New-CapabilityRow -Capability 'Release: create stable ci-required job' `
            -Current 'no matrix-independent required-check job confirmed' -Target 'a ci-required job exists and has real execution evidence' `
            -Classification REVIEW_REQUIRED -RequiresManualChange `
            -Rationale 'CDA npm Library Profile v1 requires a stable, matrix-independent "ci-required" job before the Protect main ruleset can require it. This is a workflow-file change (edit .github/workflows/ci.yml), not a GitHub setting -- Apply cannot make this change. Add the job, merge it via a normal PR, then re-run assessment.'
    }

    if ($ReleaseModel.HasSemanticReleaseGitPlugin) {
        $rows += New-CapabilityRow -Capability 'Release: remove @semantic-release/git plugin' `
            -Current 'present in the semantic-release config' -Target 'absent (no release commit pushed to main)' `
            -Classification REVIEW_REQUIRED -RequiresManualChange `
            -Rationale 'CDA Model B never writes a commit back to main after merge. Removing this plugin is a .releaserc*/release.config.* edit, not a GitHub setting -- Apply cannot make this change. Do this together with retiring the release-sentinel bypass actor (see the ruleset bypass-actors and sentinel-secret operations), not before verifying the sentinel is no longer needed for anything else.'
    }

    if ($ReleaseModel.HasSemanticReleaseChangelogPlugin) {
        $rows += New-CapabilityRow -Capability 'Release: remove @semantic-release/changelog plugin' `
            -Current 'present in the semantic-release config' -Target 'absent (GitHub Releases is the changelog of record)' `
            -Classification REVIEW_REQUIRED -RequiresManualChange `
            -Rationale 'Not required by CDA Model B (GitHub Releases already carries generated notes); keeping a committed CHANGELOG.md is a MAY, not a MUST. This is a config-file edit -- Apply cannot make this change.'
    }

    if ($DependabotTargetsDevelop) {
        $rows += New-CapabilityRow -Capability 'Dependabot: change target-branch develop -> main' `
            -Current 'target-branch: develop' -Target 'target-branch: main (or omitted, defaulting to the repository default branch)' `
            -Classification REVIEW_REQUIRED -RequiresManualChange `
            -Rationale 'Once develop is retired, Dependabot must target main instead or its PRs will target a branch that no longer exists. This is a .github/dependabot.yml edit -- Apply cannot make this change. Sequence this after (or together with) the develop-deletion decision, never before -- Dependabot must keep targeting a real branch at every point in the migration.'
    }

    return $rows
}

Export-ModuleMember -Function Get-RulesetName, New-RulesetCapabilityRows, Get-ReleaseModelSummary, New-ReleaseMigrationRows
