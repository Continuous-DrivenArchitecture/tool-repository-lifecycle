#Requires -Version 5.1
<#
    Apply.psm1

    Executes an APPROVED plan and only an approved plan -- never
    re-classifies, never discovers a new recommendation, never executes a
    delta absent from the plan's own operations[] array (see README.md,
    "Lifecycle"). Every exported function here either performs zero
    mutations (Invoke-Preflight, Test-OperationPreconditions,
    Get-OperationMutationSpec build read-only GETs only) or executes
    EXACTLY the mutation described by Get-OperationMutationSpec for one
    already-approved operation (Invoke-ApprovedPlan, and only when not
    -DryRun).

    Imports ReadOnlyGitHub.psm1 (for every live re-check) and
    MutationGitHub.psm1 (for the actual PATCH/PUT/DELETE calls -- never
    called under -DryRun). Also imports Approval.psm1 for
    Test-ApprovedPlanHash and Discovery.psm1 for the handful of read-only
    helpers (Get-BranchComparison, Get-OpenPullRequestsByBase,
    Get-WorkflowsInventory, Get-DependabotConfigText) already proven
    correct by assess-npm-library.ps1, rather than re-implementing them.

    None of these imports are declared with an explicit Import-Module
    line in this file -- like every other module in this codebase that
    relies on caller-provided globals, this module assumes the calling
    command (commands/apply-plan.ps1) has already imported everything it
    needs at global scope before calling in here. This includes
    src/common/profile/ProfileLoader.psm1's Get-EffectiveCdaProfile,
    used by every -ProfilePath-driven mutation spec below -- a RAW parse
    of a profile file would silently miss any field that profile only
    inherits from what it `extends` (see docs/profiles.md).
#>

Set-StrictMode -Version Latest

function Get-ProtectMainRulesetId {
    [CmdletBinding()]
    param($StateFingerprint)

    $match = @($StateFingerprint.Rulesets | Where-Object { "$($_.Name)" -eq 'Protect main' })
    if ($match.Count -eq 1) { return "$($match[0].Id)" }
    return $null
}

function ConvertTo-BooleanValue {
    <#
        Operation .current/.desired are always stringified (see
        Approval.psm1's ConvertTo-PlanOperations). This turns "True"/
        "False" back into a real [bool] for building a PATCH/PUT body.
    #>
    [CmdletBinding()]
    param([string]$Text)

    return ("$Text").Trim() -eq 'True'
}

# ---------------------------------------------------------------------
# PRE-FLIGHT (brief section 16) -- zero mutations. Every check here is a
# read via ReadOnlyGitHub.psm1 / Approval.psm1 only.
# ---------------------------------------------------------------------

function Test-OperationPreconditions {
    <#
        Live re-check of one operation's dependencies (brief section 21).
        Called both by Invoke-Preflight (informational, before the
        mutation phase even begins) and again by Invoke-ApprovedPlan
        immediately before executing that specific operation (fail-safe:
        state could have changed between preflight and execution).

        -PriorPlanOps: the other approved operations that run BEFORE this
        one in plan order (brief section 24: "introduce -> validate ->
        switch enforcement -> ... never a credentials-first order"). A
        two-operation batch that changes the default branch to main and
        then deletes the old develop default in the SAME approved plan is
        the expected pattern (brief section 27) -- so "default branch is
        main" is treated as satisfied if it is true live OR an earlier
        approved repo.defaultBranch->main operation precedes this one.
        Never satisfied by a LATER operation, and never assumed true
        without an earlier operation actually present in the plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Op,
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] $StateFingerprint,
        [AllowNull()] [AllowEmptyCollection()] [array]$PriorPlanOps = @()
    )

    # Defense in depth: coerce a caller's $null (e.g. from the classic
    # PowerShell "empty array as branch output collapses to $null on
    # capture" gotcha) back to a real empty array. Piping bare $null into
    # a Where-Object that dereferences $_ invokes the block once with
    # $_ = $null and throws under strict mode -- @() piped the same way
    # correctly invokes it zero times.
    $PriorPlanOps = @($PriorPlanOps)

    $id = "$($Op.id)"
    $reasons = @()

    if ($id -eq 'branch.delete.develop') {
        $repoResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo"
        if (-not $repoResult.Success) { return [PSCustomObject]@{ Satisfied = $false; Reasons = @('could not re-read repository state') } }
        $defaultBranchWillBeMain = @($PriorPlanOps | Where-Object { "$($_.id)" -eq 'repo.defaultBranch' -and "$($_.desired)" -eq 'main' }).Count -gt 0
        if ("$($repoResult.Data.default_branch)" -ne 'main' -and -not $defaultBranchWillBeMain) { $reasons += 'default branch is not main' }

        $branchResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/branches/develop"
        if (-not $branchResult.Success) { $reasons += 'develop branch could not be read (it may already be gone, or access changed)' }

        # Semantic-aware re-check (brief section 2/3/22): a plan approved
        # on the strength of a proven-equivalent set of graph-exclusive
        # commits must not be blocked here by the SAME exclusive commits
        # it was already approved against -- but it MUST fail closed if
        # ANYTHING about that evidence has moved since assessment (new
        # commit, new merge-base, new tree -- cases E/F/G) or if fresh
        # re-computation no longer proves equivalence.
        $fpEvidence = if ($StateFingerprint.PSObject.Properties['DevelopRetirementEvidence']) { $StateFingerprint.DevelopRetirementEvidence } else { $null }
        if ($null -ne $fpEvidence) {
            $liveEvidence = Get-BranchRetirementEvidence -Owner $Owner -Repo $Repo -Branch 'develop' -TargetBranch 'main'
            if (-not $liveEvidence.Available) { $reasons += "could not recompute branch retirement evidence for develop ($($liveEvidence.Reason))" }
            elseif ("$($liveEvidence.BranchHeadSha)" -ne "$($fpEvidence.BranchHeadSha)") { $reasons += "develop HEAD changed since assessment (assessed=$($fpEvidence.BranchHeadSha), live=$($liveEvidence.BranchHeadSha)) -- STALE PLAN" }
            elseif ("$($liveEvidence.MergeBaseSha)" -ne "$($fpEvidence.MergeBaseSha)") { $reasons += "merge-base with main changed since assessment (assessed=$($fpEvidence.MergeBaseSha), live=$($liveEvidence.MergeBaseSha)) -- STALE PLAN" }
            elseif ("$($liveEvidence.BranchHeadTreeSha)" -ne "$($fpEvidence.BranchHeadTreeSha)") { $reasons += "develop HEAD tree changed since assessment (assessed=$($fpEvidence.BranchHeadTreeSha), live=$($liveEvidence.BranchHeadTreeSha)) -- STALE PLAN" }
            elseif ([bool]$liveEvidence.ContentUniqueToBranch) { $reasons += 'live re-verification now finds content unique to develop -- semantic equivalence no longer holds' }
            elseif (-not [bool]$liveEvidence.SemanticEquivalenceProven) { $reasons += 'live re-verification could not (re-)prove semantic equivalence' }
        }
        else {
            $cmp = Get-BranchComparison -Owner $Owner -Repo $Repo -Base 'main' -Head 'develop'
            if (-not $cmp.Available) { $reasons += 'could not verify develop is fully merged into main (compare API call failed)' }
            elseif ([int]$cmp.AheadBy -gt 0) { $reasons += "develop now has $($cmp.AheadBy) commit(s) not reachable from main" }
        }

        $prs = @(Get-OpenPullRequestsByBase -Owner $Owner -Repo $Repo | Where-Object { $_.Base -eq 'develop' })
        if ($prs.Count -gt 0) { $reasons += "an open pull request now targets develop (#$($prs[0].Number))" }

        $workflows = @(Get-WorkflowsInventory -Owner $Owner -Repo $Repo)
        $referencing = @($workflows | Where-Object { $_.PSObject.Properties['ReferencesDevelop'] -and $_.ReferencesDevelop })
        if ($referencing.Count -gt 0) { $reasons += "workflow(s) now reference develop: $(($referencing | ForEach-Object { $_.File }) -join ', ')" }

        $dependabotText = Get-DependabotConfigText -Owner $Owner -Repo $Repo
        if ($dependabotText -and $dependabotText -match 'target-branch:\s*develop') { $reasons += 'Dependabot now targets develop' }
    }
    elseif ($id -match '^secret\.') {
        $secretName = $id.Substring(7)
        $workflows = @(Get-WorkflowsInventory -Owner $Owner -Repo $Repo)
        $referencing = @()
        foreach ($wf in $workflows) {
            $text = Get-WorkflowFileText -Owner $Owner -Repo $Repo -Path ".github/workflows/$($wf.File)"
            if ($text -and $text -match [regex]::Escape($secretName)) { $referencing += $wf.File }
        }
        if ($referencing.Count -gt 0) { $reasons += "workflow(s) now reference $secretName`: $($referencing -join ', ')" }

        if ($secretName -match '(?i)RELEASE_APP|SENTINEL') {
            $rulesetId = Get-ProtectMainRulesetId -StateFingerprint $StateFingerprint
            if ($rulesetId) {
                $rsResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/rulesets/$rulesetId"
                if (-not $rsResult.Success) { $reasons += 'could not re-read the Protect main ruleset to verify the bypass actor is gone' }
                elseif (@($rsResult.Data.bypass_actors).Count -gt 0) { $reasons += 'the Protect main ruleset still lists a bypass actor' }
            }
        }
    }
    elseif ($id -eq 'hygiene.pages') {
        # Fail-closed staleness re-check (brief Phase 7, section 25: STOP
        # if Pages becomes active/custom-domain/still-deploying between
        # assessment and Apply). A 404 here means Pages is already
        # absent -- nothing to re-verify; the DELETE itself is the only
        # thing left to attempt (and will simply report a clean no-op
        # style failure if truly gone, never silently skipped).
        $pagesResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/pages"
        if ($pagesResult.Success) {
            $workflows = @(Get-WorkflowsInventory -Owner $Owner -Repo $Repo)
            $deploying = @($workflows | Where-Object { $_.PSObject.Properties['ReferencesPagesDeployment'] -and $_.ReferencesPagesDeployment })
            if ($deploying.Count -gt 0) { $reasons += "workflow(s) now deploy to Pages: $(($deploying | ForEach-Object { $_.File }) -join ', ') -- Pages is no longer orphaned" }
            if ($pagesResult.Data.cname) { $reasons += 'Pages now has a custom domain bound -- no longer orphaned' }
        }
        elseif ($pagesResult.ErrorKind -ne 'NotFound') {
            $reasons += "could not re-read Pages configuration to verify it is still safe to remove (ErrorKind: $($pagesResult.ErrorKind))"
        }
    }
    elseif ($id -match '^hygiene\.environment\.') {
        # Same narrow-identity discipline as Get-OperationMutationSpec's
        # hygiene.environment.* case, plus dependency order (brief
        # section 6): the github-pages ENVIRONMENT must never be deleted
        # while Pages configuration could still reference/deploy to it,
        # independent of plan operation ordering.
        $targetEnvName = ("$($Op.capability)" -replace '^Hygiene:\s*', '') -replace '\s+environment$', ''
        if ($targetEnvName -ne 'github-pages') {
            $reasons += "refusing to re-verify or execute a hygiene.environment operation for any name other than 'github-pages' ('$targetEnvName' requested)"
        }
        else {
            $pagesAlreadyRemoved = @($PriorPlanOps | Where-Object { "$($_.id)" -eq 'hygiene.pages' }).Count -gt 0
            $pagesResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/pages"
            if ($pagesResult.Success -and -not $pagesAlreadyRemoved) { $reasons += 'GitHub Pages configuration still exists -- the github-pages environment must not be deleted while Pages could still reference/deploy to it (dependency order)' }
            $workflows = @(Get-WorkflowsInventory -Owner $Owner -Repo $Repo)
            $referencing = @($workflows | Where-Object { $_.Text -match "environment:\s*(\r?\n\s*name:\s*)?$([regex]::Escape($targetEnvName))" })
            if ($referencing.Count -gt 0) { $reasons += "workflow(s) now reference the '$targetEnvName' environment: $(($referencing | ForEach-Object { $_.File }) -join ', ')" }
        }
    }
    elseif ($id -eq 'repo.defaultBranch') {
        $targetBranch = "$($Op.desired)"
        $branchResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/branches/$targetBranch"
        if (-not $branchResult.Success) { $reasons += "target branch '$targetBranch' does not exist" }
    }
    elseif ($id -eq 'actions.shaPinningRequired') {
        # Staleness fail-safe (brief section 2): the recorded snapshot of
        # sha_pinning_required at assessment time (stateFingerprint.
        # ActionsPermissions, captured by assess-npm-library.ps1) must
        # still match the live value before this operation's PUT
        # (which always reads a FRESH copy of enabled/allowed_actions --
        # see Get-OperationMutationSpec -- but was approved against the
        # OLD sha_pinning_required reading) is allowed to run.
        $apFp = if ($StateFingerprint.PSObject.Properties['ActionsPermissions']) { $StateFingerprint.ActionsPermissions } else { $null }
        $apFpSha = if ($null -ne $apFp -and $apFp.PSObject.Properties['ShaPinningRequired']) { $apFp.ShaPinningRequired } else { $null }
        if ($null -eq $apFpSha) {
            $reasons += 'no sha_pinning_required snapshot was captured at assessment time -- cannot verify staleness'
        }
        else {
            $permResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions"
            if (-not $permResult.Success) { $reasons += 'could not re-read actions/permissions to verify staleness' }
            elseif ($null -eq $permResult.Data.PSObject.Properties['sha_pinning_required']) { $reasons += 'sha_pinning_required is no longer present on the live actions/permissions response' }
            else {
                $liveSha = [bool]$permResult.Data.sha_pinning_required
                if ($liveSha -ne [bool]$apFpSha) { $reasons += "sha_pinning_required drifted since assessment (assessed=$([bool]$apFpSha), live=$liveSha)" }
            }
        }
    }
    elseif ($id -match '^ruleset\.') {
        # BUG FIX (found during live sandbox integration testing): this
        # branch used to call Get-ProtectMainRulesetId unconditionally,
        # which is only correct for the fixed set of Protect-main
        # SUB-FIELD operations (bypass actors / allowed merge methods /
        # strict status checks / required status checks -- see
        # Get-RulesetOperationMutationSpec's own whitelist). For a WHOLE-
        # RULESET reference by name (e.g. ruleset.protectDevelop, or any
        # other differently-named ruleset -- see Comparison.psm1's
        # New-RulesetCapabilityRows), it silently checked the WRONG
        # ruleset's identity, which could have masked real drift on the
        # ruleset the operation actually concerns. Resolve the target
        # ruleset by name instead, derived the same way for both cases.
        $protectMainSubFieldIds = @('ruleset.bypassActors', 'ruleset.allowedMergeMethods', 'ruleset.strictStatusChecks', 'ruleset.requiredStatusChecks')
        $targetRulesetName = if ($id -in $protectMainSubFieldIds) { 'Protect main' } else { ("$($Op.capability)" -replace '^Ruleset:\s*', '') }

        $rulesetMatch = @($StateFingerprint.Rulesets | Where-Object { "$($_.Name)" -eq $targetRulesetName })
        if ($rulesetMatch.Count -eq 1) {
            $rulesetId = "$($rulesetMatch[0].Id)"
            $rsResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/rulesets/$rulesetId"
            if (-not $rsResult.Success) { $reasons += "the ruleset '$targetRulesetName' (id $rulesetId) could not be re-read" }
            elseif ("$($rsResult.Data.updated_at)" -ne "$($rulesetMatch[0].UpdatedAt)") {
                $reasons += "the ruleset '$targetRulesetName' (id $rulesetId) was modified since assessment (updated_at changed)"
            }
        }
        # else: no ruleset by this name existed at assessment time (the
        # expected, fine case for a "create this ruleset" operation --
        # current == absent). Nothing live to compare against, so no
        # staleness reason is added.
    }

    return [PSCustomObject]@{ Satisfied = ($reasons.Count -eq 0); Reasons = $reasons }
}

function Invoke-Preflight {
    <#
        Zero-mutation gate. Everything in this function is a GET. Returns
        Passed=$false if ANYTHING is wrong -- Invoke-ApprovedPlan must
        never be called against a plan whose preflight did not pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ApprovedPlan,
        [Parameter(Mandatory)] [string]$Repository
    )

    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Name, [bool]$Passed, [string]$Detail = '') {
        $checks.Add([PSCustomObject]@{ Name = $Name; Passed = $Passed; Detail = $Detail }) | Out-Null
    }

    Add-Check 'GitHub CLI authenticated' (Test-GhAuthenticated)
    Add-Check 'Plan repository matches -Repository argument' ("$($ApprovedPlan.repository)" -eq $Repository) "plan=$($ApprovedPlan.repository) argument=$Repository"

    $hashCheck = Test-ApprovedPlanHash -ApprovedPlan $ApprovedPlan
    Add-Check 'Plan hash is valid (not tampered since approval)' $hashCheck.Valid "stored=$($hashCheck.Stored) recomputed=$($hashCheck.Recomputed)"

    $approvedOps = @($ApprovedPlan.operations | Where-Object { [bool]$_.approved })
    Add-Check 'Approval metadata present (approvedBy / approvedAt)' (-not [string]::IsNullOrEmpty("$($ApprovedPlan.approvedBy)") -and -not [string]::IsNullOrEmpty("$($ApprovedPlan.approvedAt)"))
    Add-Check 'At least one operation is approved' ($approvedOps.Count -gt 0)

    $badApproved = @($approvedOps | Where-Object { "$($_.classification)" -in @('BLOCKED', 'UNKNOWN') })
    Add-Check 'No BLOCKED or UNKNOWN operation is marked approved' ($badApproved.Count -eq 0) $(if ($badApproved.Count -gt 0) { "offending id(s): $(($badApproved | ForEach-Object { $_.id }) -join ', ')" } else { '' })

    # .ToArray(), not @($checks): wrapping a System.Collections.Generic.
    # List[object] with the array subexpression operator hits a real
    # Windows PowerShell 5.1 DLR binder bug ("Los tipos de argumentos no
    # coinciden" / ArgumentException in PSEnumerableBinder.MaybeDebase) --
    # confirmed empirically, not assumed (same lesson already applied to
    # assess-npm-library.ps1's $rows).
    if (-not (Test-GhAuthenticated) -or "$($ApprovedPlan.repository)" -ne $Repository -or -not $hashCheck.Valid -or $badApproved.Count -gt 0) {
        return [PSCustomObject]@{ Passed = $false; Checks = $checks.ToArray(); OperationChecks = @() }
    }

    if ($Repository -notmatch '^Continuous-DrivenArchitecture/[A-Za-z0-9._-]+$') {
        Add-Check 'Repository owner is Continuous-DrivenArchitecture' $false $Repository
        return [PSCustomObject]@{ Passed = $false; Checks = $checks.ToArray(); OperationChecks = @() }
    }
    Add-Check 'Repository owner is Continuous-DrivenArchitecture' $true

    $parts = $Repository -split '/', 2
    $owner = $parts[0]
    $repo = $parts[1]

    $repoResult = Invoke-ReadOnlyGitHub -Path "repos/$owner/$repo"
    Add-Check 'Repository exists and is reachable' $repoResult.Success $repoResult.ErrorKind
    if (-not $repoResult.Success) {
        return [PSCustomObject]@{ Passed = $false; Checks = $checks.ToArray(); OperationChecks = @() }
    }
    $repoData = $repoResult.Data
    Add-Check 'Repository is not archived' (-not [bool]$repoData.archived)
    Add-Check 'Repository is not a fork' (-not [bool]$repoData.fork)
    Add-Check 'Repository permissions include admin (required for settings/ruleset/secret mutations)' ($null -ne $repoData.permissions -and [bool]$repoData.permissions.admin)

    $fp = $ApprovedPlan.stateFingerprint
    Add-Check 'State fingerprint: default branch name matches assessment' ("$($repoData.default_branch)" -eq "$($fp.DefaultBranch)") "live=$($repoData.default_branch) assessed=$($fp.DefaultBranch)"

    $liveBranches = @{}
    foreach ($b in (Invoke-ReadOnlyGitHub -Path "repos/$owner/$repo/branches?per_page=100").Data) { $liveBranches["$($b.name)"] = "$($b.commit.sha)" }
    if ($fp.DefaultBranchSha) {
        $liveDefaultSha = if ($liveBranches.ContainsKey("$($fp.DefaultBranch)")) { $liveBranches["$($fp.DefaultBranch)"] } else { $null }
        Add-Check 'State fingerprint: default branch HEAD SHA matches assessment' ("$liveDefaultSha" -eq "$($fp.DefaultBranchSha)") "live=$liveDefaultSha assessed=$($fp.DefaultBranchSha)"
    }
    if ($fp.MainSha) {
        $liveMainSha = if ($liveBranches.ContainsKey('main')) { $liveBranches['main'] } else { $null }
        Add-Check 'State fingerprint: main HEAD SHA matches assessment' ("$liveMainSha" -eq "$($fp.MainSha)") "live=$liveMainSha assessed=$($fp.MainSha)"
    }
    if ($fp.DevelopSha) {
        $liveDevelopSha = if ($liveBranches.ContainsKey('develop')) { $liveBranches['develop'] } else { $null }
        Add-Check 'State fingerprint: develop HEAD SHA matches assessment' ("$liveDevelopSha" -eq "$($fp.DevelopSha)") "live=$liveDevelopSha assessed=$($fp.DevelopSha)"
    }

    # BUG FIX (found during a real PRODUCTION migration, 2026-08-23):
    # this used to re-read workflow/release-config/package.json SHAs from
    # $repoData.default_branch. The assessment that built $fp captured
    # those SHAs from the CDA target content branch (main, or legacy
    # master) whenever one exists -- see assess-npm-library.ps1's
    # $contentRef -- which is NOT the same branch as the live default
    # branch during exactly the window this tool is meant to operate in
    # (a legacy repo whose default branch is still 'develop' while real
    # development already lives on 'main'). Re-reading from the wrong
    # branch here would compare a main-sourced SHA against a develop-
    # sourced live read and ALWAYS report false staleness, blocking every
    # safe, unrelated Apply until the default-branch operation itself had
    # already run -- confirmed live. Resolve the same content branch the
    # same way: prefer 'main', then 'master', else the live default.
    $liveContentRef = if ($liveBranches.ContainsKey('main')) { 'main' } elseif ($liveBranches.ContainsKey('master')) { 'master' } else { "$($repoData.default_branch)" }

    foreach ($wf in @($fp.WorkflowShas)) {
        $liveSha = Get-FileSha -Owner $owner -Repo $repo -Path ".github/workflows/$($wf.File)" -Ref $liveContentRef
        Add-Check "State fingerprint: workflow $($wf.File) SHA matches assessment" ("$liveSha" -eq "$($wf.Sha)") "live=$liveSha assessed=$($wf.Sha)"
    }
    if ($fp.ReleaseConfigFile) {
        $liveSha = Get-FileSha -Owner $owner -Repo $repo -Path "$($fp.ReleaseConfigFile)" -Ref $liveContentRef
        Add-Check "State fingerprint: release config ($($fp.ReleaseConfigFile)) SHA matches assessment" ("$liveSha" -eq "$($fp.ReleaseConfigSha)") "live=$liveSha assessed=$($fp.ReleaseConfigSha)"
    }
    if ($fp.PackageJsonSha) {
        $liveSha = Get-FileSha -Owner $owner -Repo $repo -Path 'package.json' -Ref $liveContentRef
        Add-Check 'State fingerprint: package.json SHA matches assessment' ("$liveSha" -eq "$($fp.PackageJsonSha)") "live=$liveSha assessed=$($fp.PackageJsonSha)"
    }

    $rulesetOps = @($approvedOps | Where-Object { "$($_.id)" -match '^ruleset\.' -and -not [bool]$_.requiresManualChange })
    if ($rulesetOps.Count -gt 0) {
        foreach ($rsExpected in @($fp.Rulesets)) {
            $rsLive = Invoke-ReadOnlyGitHub -Path "repos/$owner/$repo/rulesets/$($rsExpected.Id)"
            # Not $matches: that name collides with PowerShell's automatic
            # $Matches variable (populated by -match) and can have
            # undesired side effects on later regex operations in this scope.
            $rulesetUpToDate = $rsLive.Success -and ("$($rsLive.Data.updated_at)" -eq "$($rsExpected.UpdatedAt)")
            Add-Check "State fingerprint: ruleset '$($rsExpected.Name)' (id $($rsExpected.Id)) id+updated_at match assessment" $rulesetUpToDate $(if ($rsLive.Success) { "live updated_at=$($rsLive.Data.updated_at) assessed=$($rsExpected.UpdatedAt)" } else { $rsLive.ErrorKind })
        }
    }

    $opChecks = @()
    $executableOps = @($approvedOps | Where-Object { -not [bool]$_.requiresManualChange })
    for ($i = 0; $i -lt $executableOps.Count; $i++) {
        $op = $executableOps[$i]
        # @(...) wraps the WHOLE if/else, not just its else branch: an
        # empty array `@()` returned as a branch's pipeline output (rather
        # than assigned as a literal) collapses to $null on capture --
        # confirmed empirically (PropertyNotFoundException on `$_.id`
        # downstream, once $null is piped into a Where-Object that
        # dereferences $_) while investigating a real error hit during
        # live sandbox integration testing, not assumed.
        $priorOps = @(if ($i -gt 0) { @($executableOps[0..($i - 1)]) } else { @() })
        $pc = Test-OperationPreconditions -Op $op -Owner $owner -Repo $repo -StateFingerprint $fp -PriorPlanOps $priorOps
        $opChecks += [PSCustomObject]@{ Id = "$($op.id)"; Satisfied = $pc.Satisfied; Reasons = $pc.Reasons }
    }

    $allChecksPassed = -not (@($checks | Where-Object { -not $_.Passed }).Count -gt 0)
    $allPreconditionsSatisfied = -not (@($opChecks | Where-Object { -not $_.Satisfied }).Count -gt 0)

    return [PSCustomObject]@{ Passed = ($allChecksPassed -and $allPreconditionsSatisfied); Checks = $checks.ToArray(); OperationChecks = @($opChecks) }
}

# ---------------------------------------------------------------------
# MUTATION SPEC MAPPING -- read-only to BUILD (may GET current state for
# a merge-safe PATCH/PUT body), never executes anything itself.
# ---------------------------------------------------------------------

function Get-OperationMutationSpec {
    <#
        Maps one operation id to a concrete GitHub API call. Returns
        Defined=$false (never a guess) for any id this v1 mapping does not
        recognize -- Invoke-ApprovedPlan reports those as NOT_EXECUTED
        rather than attempting an unverified shape. GET-modify-PUT/PATCH
        bodies are built from a fresh live read so they never clobber a
        field this operation was not approved to change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Op,
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo,
        [string]$ProfilePath
    )

    $id = "$($Op.id)"
    $desired = "$($Op.desired)"
    $notDefined = [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'No mutation mapping defined for this operation id in Apply v1.' }

    switch ($id) {
        'repo.defaultBranch' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ default_branch = $desired }; Description = "Set default branch to '$desired'." } }
        'repo.deleteBranchOnMerge' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ delete_branch_on_merge = (ConvertTo-BooleanValue $desired) }; Description = "Set delete_branch_on_merge=$desired." } }
        'repo.allowSquashMerge' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ allow_squash_merge = (ConvertTo-BooleanValue $desired) }; Description = "Set allow_squash_merge=$desired." } }
        'repo.allowMergeCommit' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ allow_merge_commit = (ConvertTo-BooleanValue $desired) }; Description = "Set allow_merge_commit=$desired." } }
        'repo.allowRebaseMerge' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ allow_rebase_merge = (ConvertTo-BooleanValue $desired) }; Description = "Set allow_rebase_merge=$desired." } }
        'repo.allowAutoMerge' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ allow_auto_merge = (ConvertTo-BooleanValue $desired) }; Description = "Set allow_auto_merge=$desired." } }

        'actions.enabled' {
            $current = (Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions").Data
            $body = @{ enabled = (ConvertTo-BooleanValue $desired); allowed_actions = $current.allowed_actions }
            if ($null -ne $current.PSObject.Properties['sha_pinning_required']) { $body.sha_pinning_required = [bool]$current.sha_pinning_required }
            return [PSCustomObject]@{ Defined = $true; Method = 'PUT'; Path = "repos/$Owner/$Repo/actions/permissions"; Body = $body; Description = "Set Actions enabled=$desired (other actions/permissions fields preserved from live state)." }
        }
        'actions.allowedActionsPolicy' {
            $current = (Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions").Data
            $body = @{ enabled = [bool]$current.enabled; allowed_actions = $desired }
            if ($null -ne $current.PSObject.Properties['sha_pinning_required']) { $body.sha_pinning_required = [bool]$current.sha_pinning_required }
            return [PSCustomObject]@{ Defined = $true; Method = 'PUT'; Path = "repos/$Owner/$Repo/actions/permissions"; Body = $body; Description = "Set allowed_actions=$desired (other actions/permissions fields preserved from live state)." }
        }
        'actions.shaPinningRequired' {
            <#
                Same endpoint/body shape already validated live by
                repository-provisioner's Get-ActionsPlan (PUT
                repos/{owner}/{repo}/actions/permissions with enabled +
                allowed_actions + sha_pinning_required together) -- reused
                here rather than re-derived, per brief section 1. Reads
                enabled/allowed_actions fresh so this operation only ever
                changes sha_pinning_required, never the other two fields.
            #>
            $current = (Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions").Data
            if ($null -eq $current -or $null -eq $current.PSObject.Properties['sha_pinning_required']) {
                return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = "sha_pinning_required is not present on this repository's actions/permissions response -- cannot build a safe PUT body." }
            }
            $body = @{ enabled = [bool]$current.enabled; allowed_actions = $current.allowed_actions; sha_pinning_required = (ConvertTo-BooleanValue $desired) }
            return [PSCustomObject]@{ Defined = $true; Method = 'PUT'; Path = "repos/$Owner/$Repo/actions/permissions"; Body = $body; Description = "Set sha_pinning_required=$desired (enabled/allowed_actions preserved from live state)." }
        }
        'actions.defaultWorkflowPermissions' {
            $current = (Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions/workflow").Data
            $body = @{ default_workflow_permissions = $desired; can_approve_pull_request_reviews = [bool]$current.can_approve_pull_request_reviews }
            return [PSCustomObject]@{ Defined = $true; Method = 'PUT'; Path = "repos/$Owner/$Repo/actions/permissions/workflow"; Body = $body; Description = "Set default_workflow_permissions=$desired (can_approve_pull_request_reviews preserved from live state)." }
        }

        'security.secretScanning' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ security_and_analysis = @{ secret_scanning = @{ status = $(if (ConvertTo-BooleanValue $desired) { 'enabled' } else { 'disabled' }) } } }; Description = "Set security_and_analysis.secret_scanning.status per desired=$desired." } }
        'security.secretScanningPushProtection' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ security_and_analysis = @{ secret_scanning_push_protection = @{ status = $(if (ConvertTo-BooleanValue $desired) { 'enabled' } else { 'disabled' }) } } }; Description = "Set security_and_analysis.secret_scanning_push_protection.status per desired=$desired." } }
        'security.dependabotSecurityUpdates' { return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo"; Body = @{ security_and_analysis = @{ dependabot_security_updates = @{ status = $(if (ConvertTo-BooleanValue $desired) { 'enabled' } else { 'disabled' }) } } }; Description = "Set security_and_analysis.dependabot_security_updates.status per desired=$desired." } }
        'security.vulnerabilityAlerts' {
            $method = if (ConvertTo-BooleanValue $desired) { 'PUT' } else { 'DELETE' }
            return [PSCustomObject]@{ Defined = $true; Method = $method; Path = "repos/$Owner/$Repo/vulnerability-alerts"; Body = $null; Description = "$method vulnerability-alerts (desired=$desired)." }
        }
        'security.codeQL' {
            $languages = @('javascript-typescript')
            $querySuite = 'default'
            if ($ProfilePath -and (Test-Path -LiteralPath $ProfilePath)) {
                try {
                    # Get-EffectiveCdaProfile, not a raw parse: profiles/npm-
                    # library.json is a thin OVERLAY on profiles/repository-
                    # baseline.json (see docs/profiles.md) -- a raw parse of
                    # the overlay file alone would silently miss any field
                    # (including this one, when the overlay doesn't touch it)
                    # that is only defined on the base profile.
                    $effectiveResult = Get-EffectiveCdaProfile -Path $ProfilePath
                    if ($effectiveResult.Success) {
                        $cdaProfile = $effectiveResult.Profile
                        if ($cdaProfile.security.codeQLDefaultSetup.setupLanguages) { $languages = @($cdaProfile.security.codeQLDefaultSetup.setupLanguages) }
                        if ($cdaProfile.security.codeQLDefaultSetup.querySuite) { $querySuite = "$($cdaProfile.security.codeQLDefaultSetup.querySuite)" }
                    }
                }
                catch { }
            }
            $body = @{ state = 'configured'; query_suite = $querySuite; languages = $languages }
            return [PSCustomObject]@{ Defined = $true; Method = 'PATCH'; Path = "repos/$Owner/$Repo/code-scanning/default-setup"; Body = $body; Description = "Configure CodeQL default setup (languages: $($languages -join ', '))." }
        }

        default {
            if ($id -eq 'branch.delete.develop') {
                # Evidence-rich description (brief section 22): re-reads
                # live retirement evidence so DryRun's Detail column shows
                # the SHAs/tree-equivalence result actually being relied
                # on, not just "DELETE ...". Read-only -- Test-Operation-
                # Preconditions is still the sole gate that can block this.
                $evidence = Get-BranchRetirementEvidence -Owner $Owner -Repo $Repo -Branch 'develop' -TargetBranch 'main'
                $evidenceSummary = if ($evidence.Available) {
                    "develop=$($evidence.BranchHeadSha) main=$($evidence.TargetHeadSha) mergeBase=$($evidence.MergeBaseSha) exclusiveCommits=$($evidence.BranchExclusiveCommitCount) contentUniqueToBranch=$($evidence.ContentUniqueToBranch) semanticEquivalenceProven=$($evidence.SemanticEquivalenceProven)"
                } else { "retirement evidence unavailable ($($evidence.Reason))" }
                return [PSCustomObject]@{ Defined = $true; Method = 'DELETE'; Path = "repos/$Owner/$Repo/git/refs/heads/develop"; Body = $null; Description = "DESTRUCTIVE: delete the develop branch ref. Evidence: $evidenceSummary" }
            }
            if ($id -match '^secret\.') {
                $name = $id.Substring(7)
                return [PSCustomObject]@{ Defined = $true; Method = 'DELETE'; Path = "repos/$Owner/$Repo/actions/secrets/$name"; Body = $null; Description = "DESTRUCTIVE: delete secret $name. Its value is never read." }
            }
            if ($id -eq 'hygiene.pages') {
                # Baseline-hygiene orphan removal (Phase 7, section 7):
                # GitHub's own DELETE /pages disables/removes the Pages
                # site configuration. Never touches the github-pages
                # ENVIRONMENT -- that is a separate, separately-approved
                # operation (hygiene.environment.*), and dependency order
                # (Phase 7 section 6) requires this one to run first.
                return [PSCustomObject]@{ Defined = $true; Method = 'DELETE'; Path = "repos/$Owner/$Repo/pages"; Body = $null; Description = 'DESTRUCTIVE: remove the GitHub Pages configuration (DELETE repos/{owner}/{repo}/pages). Never affects environments, workflows, or repository content.' }
            }
            if ($id -match '^hygiene\.environment\.') {
                # Deliberately narrow (Phase 7 section 7: "do not
                # generalize arbitrary environment deletion recklessly"):
                # the target environment name is re-derived from the
                # operation's own capability text (same discipline as
                # Get-RulesetOperationMutationSpec's non-Protect-main
                # ruleset deletion below), then hard-refused unless it is
                # EXACTLY 'github-pages'. This v1 Apply mapping supports
                # deleting no other environment, regardless of what a
                # future classification pass might ever propose.
                $targetEnvName = ("$($Op.capability)" -replace '^Hygiene:\s*', '') -replace '\s+environment$', ''
                if ($targetEnvName -ne 'github-pages') {
                    return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = "Apply v1 refuses to delete any environment other than 'github-pages' -- '$targetEnvName' is not a supported target for this operation id, by explicit design (never generalize environment deletion)." }
                }
                return [PSCustomObject]@{ Defined = $true; Method = 'DELETE'; Path = "repos/$Owner/$Repo/environments/$targetEnvName"; Body = $null; Description = "DESTRUCTIVE: delete the GitHub Environment '$targetEnvName' (DELETE repos/$Owner/$Repo/environments/$targetEnvName). Secret/variable VALUES are never read; only their names were inspected during classification." }
            }
            # ruleset.* ids are routed to Get-RulesetOperationMutationSpec by
            # Get-EffectiveMutationSpec before ever reaching this function --
            # they never fall through to here.
            return $notDefined
        }
    }
}

function Test-RequiredCheckEvidence {
    <#
        Read-only. Looks for a check run literally named ci-required on
        the tip commit of the given branch -- a deliberately narrow,
        honest check: it proves the check has executed at least once on
        the current branch tip, not an exhaustive history search. Mirrors
        repository-provisioner's own Test-RequiredCheckEvidence (same
        contract, reused rather than re-invented) since creating a
        ruleset that REQUIRES a check which has never actually run would
        leave the repository unable to merge anything.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Branch)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/commits/$Branch/check-runs"
    if (-not $result.Success -or $null -eq $result.Data) { return $false }
    $match = @($result.Data.check_runs | Where-Object { $_.name -eq 'ci-required' -and $_.conclusion -eq 'success' })
    return ($match.Count -gt 0)
}

function Get-CreateProtectMainRulesetSpec {
    <#
        Builds the POST body for creating a brand-new "Protect main"
        ruleset from the CDA profile's own .ruleset section -- the exact
        same field shape repository-provisioner's New-DesiredRulesetBody
        already proved correct against a live ruleset, reused here rather
        than re-derived, so both tools agree on what "Protect main"
        means. Never attempted if a ruleset by that name already exists
        in the assessment-time fingerprint (that is a PUT/update case,
        not a create, and this v1 does not support converting one to the
        other automatically) or if ci-required has no real execution
        evidence on the current default branch (requiring a check that
        has never run would brick merging).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Op,
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] $StateFingerprint,
        [string]$ProfilePath
    )

    $notDefined = [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'No mutation mapping defined for this operation id in Apply v1.' }

    if (-not $ProfilePath -or -not (Test-Path -LiteralPath $ProfilePath)) {
        return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'CDA profile path not available -- cannot build the desired ruleset body.' }
    }
    if (Get-ProtectMainRulesetId -StateFingerprint $StateFingerprint) {
        return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'A ruleset named Protect main already existed at assessment time -- this is a create-only mapping, not update.' }
    }

    $repoResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo"
    if (-not $repoResult.Success) { return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'Could not re-read repository state to find the default branch.' } }
    $defaultBranch = "$($repoResult.Data.default_branch)"

    $includeRsc = Test-RequiredCheckEvidence -Owner $Owner -Repo $Repo -Branch $defaultBranch
    if (-not $includeRsc) {
        return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = "ci-required has no successful execution evidence on '$defaultBranch' yet -- refusing to create a ruleset that requires a check which has never run." }
    }

    # Get-EffectiveCdaProfile, not a raw parse -- see the matching comment
    # on the 'security.codeQL' case above.
    $effectiveResult = Get-EffectiveCdaProfile -Path $ProfilePath
    if (-not $effectiveResult.Success) { return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = "Could not resolve the effective CDA profile: $($effectiveResult.Error)" } }
    $cdaProfile = $effectiveResult.Profile
    $rs = $cdaProfile.ruleset
    $dismissStale = [bool]($rs.pullRequest.requiredApprovingReviewCount -gt 0)

    $rules = @(
        @{
            type       = 'pull_request'
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
        @{
            type       = 'required_status_checks'
            parameters = @{
                strict_required_status_checks_policy = [bool]$rs.requiredStatusChecks.strict
                required_status_checks = @(@{ context = "$($rs.requiredStatusChecks.context)" })
            }
        }
    )
    if ($rs.nonFastForward) { $rules += @{ type = 'non_fast_forward' } }
    if ($rs.deletion) { $rules += @{ type = 'deletion' } }

    $refInclude = @($rs.refInclude | ForEach-Object { if ("$_" -eq '~DEFAULT_BRANCH') { '~DEFAULT_BRANCH' } else { "$_" } })
    $body = @{
        name          = "$($rs.name)"
        target        = "$($rs.target)"
        enforcement   = "$($rs.enforcement)"
        conditions    = @{ ref_name = @{ include = $refInclude; exclude = @() } }
        rules         = $rules
        bypass_actors = @($rs.bypassActors)
    }

    return [PSCustomObject]@{ Defined = $true; Method = 'POST'; Path = "repos/$Owner/$Repo/rulesets"; Body = $body; Description = "Create the '$($rs.name)' ruleset per the CDA profile (PR required, ci-required, strict, force-push and deletion blocked, no bypass actors)." }
}

function Get-RulesetOperationMutationSpec {
    <#
        ruleset.* operations need the live full ruleset body (a PUT to
        /rulesets/{id} replaces the whole object, unlike the partial-PATCH
        repo settings above) plus the id from the plan's own state
        fingerprint -- never guessed or matched by name alone (brief
        section 24). Kept as a separate function (rather than a case in
        Get-OperationMutationSpec) because it needs $StateFingerprint,
        which the generic dispatcher above does not take.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Op,
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] $StateFingerprint,
        [string]$ProfilePath
    )

    $id = "$($Op.id)"

    if ($id -eq 'ruleset.protectMain') {
        return Get-CreateProtectMainRulesetSpec -Op $Op -Owner $Owner -Repo $Repo -StateFingerprint $StateFingerprint -ProfilePath $ProfilePath
    }

    $protectMainSubFieldIds = @('ruleset.bypassActors', 'ruleset.allowedMergeMethods', 'ruleset.strictStatusChecks', 'ruleset.requiredStatusChecks')
    if ($id -notin $protectMainSubFieldIds) {
        # By construction (see Comparison.psm1's New-RulesetCapabilityRows),
        # every OTHER ruleset.* id reaching this function is the "a
        # ruleset not named Protect main exists" row -- its target is
        # literally "n/a (not part of the profile)", so the only concrete
        # mutation Apply v1 offers is deleting it, matched strictly by the
        # id captured in the assessment-time fingerprint, never by name
        # alone at mutation time (brief section 24 -- same identity
        # discipline as every other ruleset mutation here).
        $targetName = ("$($Op.capability)" -replace '^Ruleset:\s*', '')
        $match = @($StateFingerprint.Rulesets | Where-Object { "$($_.Name)" -eq $targetName })
        if ($match.Count -ne 1) {
            return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = "No ruleset named '$targetName' was captured at assessment time -- refusing to guess which ruleset to delete." }
        }
        return [PSCustomObject]@{ Defined = $true; Method = 'DELETE'; Path = "repos/$Owner/$Repo/rulesets/$($match[0].Id)"; Body = $null; Description = "DESTRUCTIVE: DELETE ruleset '$targetName' (id $($match[0].Id))." }
    }

    $rulesetId = Get-ProtectMainRulesetId -StateFingerprint $StateFingerprint
    if (-not $rulesetId) {
        return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'No Protect main ruleset id was captured at assessment time -- refusing to guess which ruleset to mutate.' }
    }
    $live = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/rulesets/$rulesetId"
    if (-not $live.Success) {
        return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = "Could not re-read ruleset id $rulesetId to build a safe PUT body." }
    }

    $body = @{
        name         = $live.Data.name
        target       = $live.Data.target
        enforcement  = $live.Data.enforcement
        bypass_actors = @($live.Data.bypass_actors)
        conditions   = $live.Data.conditions
        rules        = @($live.Data.rules)
    }

    switch ($id) {
        'ruleset.bypassActors' {
            $body.bypass_actors = @()
            return [PSCustomObject]@{ Defined = $true; Method = 'PUT'; Path = "repos/$Owner/$Repo/rulesets/$rulesetId"; Body = $body; Description = "DESTRUCTIVE: PUT ruleset $rulesetId with bypass_actors cleared to []." }
        }
        'ruleset.allowedMergeMethods' {
            $prRule = @($body.rules | Where-Object { $_.type -eq 'pull_request' })
            if ($prRule.Count -eq 0) { return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'Live ruleset has no pull_request rule to modify.' } }
            $prRule[0].parameters.allowed_merge_methods = @('squash')
            return [PSCustomObject]@{ Defined = $true; Method = 'PUT'; Path = "repos/$Owner/$Repo/rulesets/$rulesetId"; Body = $body; Description = "PUT ruleset $rulesetId with allowed_merge_methods restricted to ['squash']." }
        }
        'ruleset.strictStatusChecks' {
            $rscRule = @($body.rules | Where-Object { $_.type -eq 'required_status_checks' })
            if ($rscRule.Count -eq 0) { return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'Live ruleset has no required_status_checks rule to modify.' } }
            $rscRule[0].parameters.strict_required_status_checks_policy = $true
            return [PSCustomObject]@{ Defined = $true; Method = 'PUT'; Path = "repos/$Owner/$Repo/rulesets/$rulesetId"; Body = $body; Description = "PUT ruleset $rulesetId with strict_required_status_checks_policy=true." }
        }
        'ruleset.requiredStatusChecks' {
            # Swaps the required-check LIST from whatever matrix-leg-
            # dependent checks are currently required to just the CDA
            # profile's stable "ci-required" context. Guarded by the same
            # execution-evidence check as ruleset creation (brief section
            # 10 / Get-CreateProtectMainRulesetSpec): requiring a check
            # that has never actually run would brick merging on main.
            $rscRule = @($body.rules | Where-Object { $_.type -eq 'required_status_checks' })
            if ($rscRule.Count -eq 0) { return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'Live ruleset has no required_status_checks rule to modify.' } }
            if (-not $ProfilePath -or -not (Test-Path -LiteralPath $ProfilePath)) {
                return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'CDA profile path not available -- cannot determine the target required-check context.' }
            }
            $effectiveResult = Get-EffectiveCdaProfile -Path $ProfilePath
            if (-not $effectiveResult.Success) { return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = "Could not resolve the effective CDA profile: $($effectiveResult.Error)" } }
            $cdaProfile = $effectiveResult.Profile
            $targetContext = "$($cdaProfile.ruleset.requiredStatusChecks.context)"
            if (-not $targetContext) { return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'CDA profile does not define ruleset.requiredStatusChecks.context.' } }
            $repoResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo"
            if (-not $repoResult.Success) { return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = 'Could not re-read repository state to find the default branch.' } }
            if (-not (Test-RequiredCheckEvidence -Owner $Owner -Repo $Repo -Branch "$($repoResult.Data.default_branch)")) {
                return [PSCustomObject]@{ Defined = $false; Method = $null; Path = $null; Body = $null; Description = "'$targetContext' has no successful execution evidence on '$($repoResult.Data.default_branch)' yet -- refusing to require a check that has never run." }
            }
            $rscRule[0].parameters.required_status_checks = @(@{ context = $targetContext })
            return [PSCustomObject]@{ Defined = $true; Method = 'PUT'; Path = "repos/$Owner/$Repo/rulesets/$rulesetId"; Body = $body; Description = "PUT ruleset $rulesetId with required_status_checks replaced by ['$targetContext']." }
        }
    }
}

function Get-EffectiveMutationSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Op, [Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [string]$ProfilePath, [Parameter(Mandatory)] $StateFingerprint)

    if ("$($Op.id)" -match '^ruleset\.') {
        return Get-RulesetOperationMutationSpec -Op $Op -Owner $Owner -Repo $Repo -StateFingerprint $StateFingerprint -ProfilePath $ProfilePath
    }
    return Get-OperationMutationSpec -Op $Op -Owner $Owner -Repo $Repo -ProfilePath $ProfilePath
}

# ---------------------------------------------------------------------
# EXECUTION -- ordered, stop-on-first-failure, zero mutations under
# -DryRun.
# ---------------------------------------------------------------------

function Invoke-ApprovedPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ApprovedPlan,
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo,
        [string]$ProfilePath,
        [switch]$DryRun
    )

    $results = New-Object System.Collections.Generic.List[object]
    $approvedOps = @($ApprovedPlan.operations | Where-Object { [bool]$_.approved })
    $stopped = $false
    $stopReason = $null
    # Operations already executed (APPLIED) or, under -DryRun, simulated
    # (WOULD_APPLY) successfully so far -- passed to each later operation's
    # precondition check as -PriorPlanOps (see Test-OperationPreconditions'
    # comment on the default-branch-then-delete-develop sequencing case).
    $priorSucceeded = New-Object System.Collections.Generic.List[object]

    foreach ($op in $approvedOps) {
        if ($stopped) {
            $results.Add([PSCustomObject]@{ Id = "$($op.id)"; Capability = "$($op.capability)"; Status = 'NOT_EXECUTED'; Detail = "Skipped: a prior operation failed ($stopReason)." }) | Out-Null
            continue
        }

        if ([bool]$op.requiresManualChange) {
            $results.Add([PSCustomObject]@{ Id = "$($op.id)"; Capability = "$($op.capability)"; Status = 'MANUAL_CHANGE_REQUIRED'; Detail = 'This is a repository file change. Apply v1 cannot execute it -- make the change via a normal pull request, merge it, then run a new assessment.' }) | Out-Null
            continue
        }

        $pc = Test-OperationPreconditions -Op $op -Owner $Owner -Repo $Repo -StateFingerprint $ApprovedPlan.stateFingerprint -PriorPlanOps $priorSucceeded.ToArray()
        if (-not $pc.Satisfied) {
            $detail = "Precondition(s) not satisfied: $($pc.Reasons -join '; ')"
            $results.Add([PSCustomObject]@{ Id = "$($op.id)"; Capability = "$($op.capability)"; Status = 'FAILED'; Detail = $detail }) | Out-Null
            $stopped = $true
            $stopReason = "$($op.id): $detail"
            continue
        }

        $spec = Get-EffectiveMutationSpec -Op $op -Owner $Owner -Repo $Repo -ProfilePath $ProfilePath -StateFingerprint $ApprovedPlan.stateFingerprint
        if (-not $spec.Defined) {
            $results.Add([PSCustomObject]@{ Id = "$($op.id)"; Capability = "$($op.capability)"; Status = 'NOT_EXECUTED'; Detail = $spec.Description }) | Out-Null
            continue
        }

        if ($DryRun) {
            $marker = if ([bool]$op.destructive) { 'DESTRUCTIVE OPERATION -- ' } else { '' }
            # branch.delete.develop's Description carries the full
            # tree/content retirement-evidence summary (brief section 22)
            # -- worth the extra line in DryRun output. Other operations
            # keep the terse Method+Path Detail they always had.
            $detail = if ("$($op.id)" -eq 'branch.delete.develop') { "${marker}$($spec.Method) $($spec.Path) | $($spec.Description)" } else { "${marker}$($spec.Method) $($spec.Path)" }
            $results.Add([PSCustomObject]@{ Id = "$($op.id)"; Capability = "$($op.capability)"; Status = 'WOULD_APPLY'; Detail = $detail; Method = $spec.Method; Path = $spec.Path }) | Out-Null
            $priorSucceeded.Add($op) | Out-Null
            continue
        }

        $mutationResult = if ($null -ne $spec.Body) {
            Invoke-MutationGitHub -Path $spec.Path -Method $spec.Method -BodyObject $spec.Body
        }
        else {
            Invoke-MutationGitHub -Path $spec.Path -Method $spec.Method
        }

        if (-not $mutationResult.Success) {
            $detail = "$($spec.Method) $($spec.Path) failed: $($mutationResult.ErrorKind) (HTTP $($mutationResult.StatusCode))"
            $results.Add([PSCustomObject]@{ Id = "$($op.id)"; Capability = "$($op.capability)"; Status = 'FAILED'; Detail = $detail }) | Out-Null
            $stopped = $true
            $stopReason = "$($op.id): $detail"
            continue
        }

        $results.Add([PSCustomObject]@{ Id = "$($op.id)"; Capability = "$($op.capability)"; Status = 'APPLIED'; Detail = "$($spec.Method) $($spec.Path) succeeded (HTTP $($mutationResult.StatusCode))." }) | Out-Null
        $priorSucceeded.Add($op) | Out-Null
    }

    # .ToArray(), not @($results) -- see the matching comment in
    # Invoke-Preflight above.
    return [PSCustomObject]@{ Results = $results.ToArray(); Stopped = $stopped; StopReason = $stopReason }
}

Export-ModuleMember -Function Test-OperationPreconditions, Invoke-Preflight, Get-OperationMutationSpec, Get-RulesetOperationMutationSpec, Get-CreateProtectMainRulesetSpec, Test-RequiredCheckEvidence, Get-EffectiveMutationSpec, Invoke-ApprovedPlan, Get-ProtectMainRulesetId, ConvertTo-BooleanValue
