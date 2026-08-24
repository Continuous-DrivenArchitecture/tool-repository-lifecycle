#Requires -Version 5.1
<#
    Classification.psm1

    Pure decision logic -- no network calls, no file I/O. Every function
    here takes already-discovered facts and returns a classification from
    the fixed taxonomy. This is what tests/run-tests.ps1 exercises with
    fixture data (see CDA repository-adopter brief, section 23).
#>

Set-StrictMode -Version Latest

$script:ValidClassifications = @(
    'COMPLIANT', 'SAFE_CHANGE', 'REVIEW_REQUIRED', 'BLOCKED',
    'KEEP_STRONGER', 'REMOVE_CANDIDATE', 'NOT_AVAILABLE', 'UNKNOWN'
)

function Get-AdopterClassificationTaxonomy {
    <# Returns the fixed, valid classification set -- used by tests to
       assert nothing outside this list is ever produced. #>
    [CmdletBinding()]
    param()
    return $script:ValidClassifications
}

function ConvertTo-IdSlug {
    <# Pure text transform: "Allow merge commit" -> "allowMergeCommit". #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Text)

    # @() wrap is required: a Matches-then-ForEach-Object pipeline with
    # exactly one result collapses to a bare string on assignment (no
    # .Count), and $arr[1..($arr.Count-1)] on a 1-element array is a
    # DESCENDING range (1,0), not empty -- both confirmed empirically,
    # not assumed. Handling the single-word case explicitly sidesteps both.
    $words = @([regex]::Matches($Text, '[A-Za-z0-9]+') | ForEach-Object { $_.Value })
    if ($words.Count -eq 0) { return 'unknown' }
    $first = $words[0].ToLowerInvariant()
    if ($words.Count -eq 1) { return $first }
    $rest = @($words[1..($words.Count - 1)]) | ForEach-Object {
        $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant()
    }
    return ($first + ($rest -join ''))
}

function Get-StableOperationId {
    <#
        Deterministic id for a capability row, e.g. "repo.deleteBranchOnMerge",
        "branch.delete.develop", "secret.RELEASE_APP_ID". Same capability
        text always yields the same id -- this is what lets an approved
        plan reference an operation unambiguously, and what lets Apply
        match an approved operation back to the capability it came from.
        Known capability names (the fixed set assess-npm-library.ps1
        actually produces) use a curated namespace; anything else falls
        back to a generic, still-deterministic slug.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Capability)

    if ($Capability -match '^Secret: (.+)$') { return "secret.$($Matches[1])" }
    if ($Capability -match '^Branch: delete develop$') { return 'branch.delete.develop' }
    if ($Capability -match '^Hygiene: GitHub Pages configuration$') { return 'hygiene.pages' }
    if ($Capability -match '^Hygiene: (.+) environment$') { return "hygiene.environment.$(ConvertTo-IdSlug $Matches[1])" }
    if ($Capability -match '^Ruleset: (.+)$') { return "ruleset.$(ConvertTo-IdSlug $Matches[1])" }
    if ($Capability -match '^Release: (.+)$') { return "release.$(ConvertTo-IdSlug $Matches[1])" }
    if ($Capability -match '^Dependabot: (.+)$') { return "dependabot.$(ConvertTo-IdSlug $Matches[1])" }

    switch ($Capability) {
        'Default branch' { return 'repo.defaultBranch' }
        'Delete branch on merge' { return 'repo.deleteBranchOnMerge' }
        'Allow squash merge' { return 'repo.allowSquashMerge' }
        'Allow merge commit' { return 'repo.allowMergeCommit' }
        'Allow rebase merge' { return 'repo.allowRebaseMerge' }
        'Allow auto-merge' { return 'repo.allowAutoMerge' }
        'Actions enabled' { return 'actions.enabled' }
        'Allowed actions policy' { return 'actions.allowedActionsPolicy' }
        'SHA pinning required' { return 'actions.shaPinningRequired' }
        'Default workflow permissions' { return 'actions.defaultWorkflowPermissions' }
        'Selected-actions allow-list' { return 'actions.selectedActionsAllowList' }
        'Secret scanning' { return 'security.secretScanning' }
        'Secret scanning push protection' { return 'security.secretScanningPushProtection' }
        'Dependabot security updates' { return 'security.dependabotSecurityUpdates' }
        'Dependabot vulnerability alerts' { return 'security.vulnerabilityAlerts' }
        'CodeQL default setup' { return 'security.codeQL' }
        'Required check execution evidence' { return 'ci.requiredCheckEvidence' }
        'npm Trusted Publisher' { return 'npm.trustedPublisher' }
        default { return "capability.$(ConvertTo-IdSlug $Capability)" }
    }
}

function New-CapabilityRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Capability,
        [Parameter(Mandatory)] [AllowNull()] $Current,
        [Parameter(Mandatory)] [AllowNull()] $Target,
        [Parameter(Mandatory)]
        [ValidateSet('COMPLIANT', 'SAFE_CHANGE', 'REVIEW_REQUIRED', 'BLOCKED', 'KEEP_STRONGER', 'REMOVE_CANDIDATE', 'NOT_AVAILABLE', 'UNKNOWN')]
        [string]$Classification,
        [Parameter(Mandatory)] [string]$Rationale,
        [string]$Id,
        [switch]$RequiresManualChange,
        [switch]$Destructive,
        # Distinguishes the npm-library PROFILE's own target-state
        # capabilities from CDA repository BASELINE HYGIENE checks
        # (orphan Pages/environment/workflow cleanup -- a baseline-level
        # MUST independent of any profile, see
        # docs/standards/cda-repository-baseline-v1.md, "Repository
        # hygiene"). Defaults to 'Profile' so every pre-existing call site
        # is unaffected; only the new hygiene classifiers below pass
        # 'BaselineHygiene' explicitly. Full CDA compliance requires both
        # categories to independently resolve -- see AdoptionPlan.psm1's
        # Get-FullCdaComplianceResult.
        [ValidateSet('Profile', 'BaselineHygiene')]
        [string]$Category = 'Profile'
    )
    if ([string]::IsNullOrEmpty($Id)) { $Id = Get-StableOperationId -Capability $Capability }
    return [PSCustomObject]@{
        Id                    = $Id
        Capability            = $Capability
        Current               = $Current
        Target                = $Target
        Classification        = $Classification
        Rationale             = $Rationale
        RequiresManualChange  = [bool]$RequiresManualChange
        Destructive           = [bool]$Destructive
        Category              = $Category
    }
}

function Get-BooleanToggleClassification {
    <#
        Generic classifier for a simple on/off setting where "on" is what
        CDA wants (secret scanning, push protection, vulnerability
        alerts, delete-branch-on-merge, ...). Turning ON a protection
        that's currently off is a SAFE_CHANGE candidate per the brief's
        own examples (section 14) -- it has no semantic/historical impact.
        Anything unreadable is UNKNOWN, never assumed compliant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Capability,
        [Parameter(Mandatory)] [bool]$Applicable,
        [AllowNull()] [Nullable[bool]]$Current,
        [Parameter(Mandatory)] [bool]$TargetOn
    )

    if (-not $Applicable) {
        return New-CapabilityRow -Capability $Capability -Current 'n/a' -Target $TargetOn -Classification NOT_AVAILABLE -Rationale 'Not available via the API for this repository/plan.'
    }
    if ($null -eq $Current) {
        return New-CapabilityRow -Capability $Capability -Current 'unknown' -Target $TargetOn -Classification UNKNOWN -Rationale 'State could not be read reliably.'
    }
    if ($Current -eq $TargetOn) {
        return New-CapabilityRow -Capability $Capability -Current $Current -Target $TargetOn -Classification COMPLIANT -Rationale 'Already matches the CDA target.'
    }
    if ($TargetOn -and -not $Current) {
        return New-CapabilityRow -Capability $Capability -Current $Current -Target $TargetOn -Classification SAFE_CHANGE -Rationale 'Enabling this protection has no semantic or historical impact on the repository.'
    }
    # Current is ON, target wants it OFF (rare for this profile) -- never
    # treat weakening a protection as safe by default.
    return New-CapabilityRow -Capability $Capability -Current $Current -Target $TargetOn -Classification REVIEW_REQUIRED -Rationale 'Current setting is stricter than the CDA target; turning it off must be a deliberate, reviewed decision.'
}

function Get-StructuralCapabilityClassification {
    <#
        For settings with real behavioral consequences if changed
        (default branch, merge strategy, Actions permissions/allowed-
        actions policy). Never SAFE_CHANGE by default -- always
        REVIEW_REQUIRED when it differs, per section 14's conservatism
        instruction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Capability,
        [Parameter(Mandatory)] [bool]$Applicable,
        [AllowNull()] $Current,
        [Parameter(Mandatory)] $Target,
        [string]$ReviewRationale = 'Differs from the CDA target and affects repository/workflow behavior; requires maintainer review before changing.'
    )

    if (-not $Applicable) {
        return New-CapabilityRow -Capability $Capability -Current 'n/a' -Target $Target -Classification NOT_AVAILABLE -Rationale 'Not available via the API for this repository/plan.'
    }
    if ($null -eq $Current) {
        return New-CapabilityRow -Capability $Capability -Current 'unknown' -Target $Target -Classification UNKNOWN -Rationale 'State could not be read reliably.'
    }
    if ("$Current" -ceq "$Target") {
        return New-CapabilityRow -Capability $Capability -Current $Current -Target $Target -Classification COMPLIANT -Rationale 'Already matches the CDA target.'
    }
    return New-CapabilityRow -Capability $Capability -Current $Current -Target $Target -Classification REVIEW_REQUIRED -Rationale $ReviewRationale
}

function Get-ApprovalCountClassification {
    <#
        Compares an existing ruleset's required-approval count against
        the CDA single-maintainer bootstrap default (0 in the current
        profile). Never suggests weakening: a stricter existing value is
        KEEP_STRONGER, not "UPDATE TO 0" (see brief section 11, explicit
        example).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$CurrentCount, [Parameter(Mandatory)] [int]$TargetCount)

    if ($CurrentCount -eq $TargetCount) {
        return New-CapabilityRow -Capability 'Ruleset: required approving review count' -Current $CurrentCount -Target $TargetCount -Classification COMPLIANT -Rationale 'Matches the CDA target.'
    }
    if ($CurrentCount -gt $TargetCount) {
        return New-CapabilityRow -Capability 'Ruleset: required approving review count' -Current $CurrentCount -Target $TargetCount -Classification KEEP_STRONGER -Rationale "Existing requirement ($CurrentCount) is stricter than the CDA single-maintainer bootstrap default ($TargetCount). The CDA baseline explicitly treats 0 as a documented exception for single-maintainer repositories, not a floor to converge every repository toward -- do not weaken an existing, presumably deliberate, stronger review requirement."
    }
    return New-CapabilityRow -Capability 'Ruleset: required approving review count' -Current $CurrentCount -Target $TargetCount -Classification REVIEW_REQUIRED -Rationale "Existing requirement ($CurrentCount) is weaker than the CDA target ($TargetCount); raising it is a governance decision for the maintainer, not an automatic change."
}

function Get-DevelopDeletionClassification {
    <#
        Implements the brief's section 7/17 rule set exactly. Every
        input is a plain fact already established by Discovery -- this
        function only combines them. BLOCKED wins over everything else;
        REVIEW_REQUIRED wins over SAFE_CHANGE. Nothing here ever returns
        SAFE_CHANGE unless every single condition is independently true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$HasCommitsNotInMain,       # develop has commits main can't reach (GRAPH divergence)
        [Parameter(Mandatory)] [bool]$HasOpenPRsTargetingDevelop,
        [Parameter(Mandatory)] [bool]$WorkflowsReferenceDevelop,
        [Parameter(Mandatory)] [bool]$DependabotTargetsDevelop,
        [Parameter(Mandatory)] [bool]$DocsReferenceDevelop,
        # Tree/content evidence (Get-BranchRetirementEvidence), never
        # commit-subject guessing. Only consulted when
        # HasCommitsNotInMain is true; ignored otherwise (brief section
        # 2/3). $null means "not computed" -- treated the same as $false
        # (never assume equivalence without positive proof).
        [AllowNull()] [Nullable[bool]]$SemanticEquivalenceProven = $null,
        [int]$BranchExclusiveCommitCount = 0
    )

    if ($HasCommitsNotInMain -and $SemanticEquivalenceProven -ne $true) {
        return New-CapabilityRow -Capability 'Branch: delete develop' -Current 'exists, contains commits not reachable from main' -Target 'deleted (main-only)' -Classification BLOCKED -Rationale 'develop contains commits not reachable from main, and tree/content evidence does not prove those commits are free of content unique to develop. Deleting it would destroy history that has never been merged. This must be resolved (merge, or explicit decision to abandon those commits) before deletion can even be considered.' -Destructive
    }

    $reviewReasons = @()
    if ($HasCommitsNotInMain -and $SemanticEquivalenceProven -eq $true) {
        $reviewReasons += "develop has $BranchExclusiveCommitCount graph-exclusive commit(s), but tree/content evidence proves none of them introduce content unique to develop (semantic equivalence proven -- see BranchRetirementEvidence)"
    }
    if ($HasOpenPRsTargetingDevelop) { $reviewReasons += 'at least one open PR targets develop' }
    if ($WorkflowsReferenceDevelop) { $reviewReasons += 'a workflow file references develop' }
    if ($DependabotTargetsDevelop) { $reviewReasons += 'Dependabot is configured with target-branch: develop' }
    if ($DocsReferenceDevelop) { $reviewReasons += 'repository documentation (CONTRIBUTING/SECURITY/CODEOWNERS/PR template) references develop' }

    if ($reviewReasons.Count -gt 0) {
        $current = if ($HasCommitsNotInMain) { 'exists, graph-exclusive commits but semantic equivalence proven' } else { 'exists, fully merged into main' }
        return New-CapabilityRow -Capability 'Branch: delete develop' -Current $current -Target 'deleted (main-only)' -Classification REVIEW_REQUIRED -Rationale "develop is not yet a safe deletion candidate: $($reviewReasons -join '; '). Each reference must be migrated or explicitly retired before deletion is safe. This is deliberately never SAFE_CHANGE -- deletion is destructive and requires explicit individual approval (-ApproveOperation branch.delete.develop), never -ApproveSafeChanges." -Destructive
    }

    return New-CapabilityRow -Capability 'Branch: delete develop' -Current 'exists, fully merged into main, unreferenced' -Target 'deleted (main-only)' -Classification SAFE_CHANGE -Rationale 'develop is fully merged into main, no open PR targets it, no workflow or Dependabot config references it, and no scanned documentation references it. Deletion is a safe-change candidate -- still requires the explicit maintainer approval this tool never grants itself.' -Destructive
}

function Get-SecretClassification {
    <#
        Name-pattern heuristic only -- this function never sees a secret
        value, only its name and where it's referenced. A sentinel-shaped
        name used exclusively by a workflow that itself looks like the
        legacy release-commit model is a REMOVE_CANDIDATE for migration
        planning purposes, never an instruction to delete it now.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SecretName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$ReferencedByWorkflows,
        [Parameter(Mandatory)] [bool]$ReleaseWorkflowUsesSentinelPattern
    )

    $looksLikeSentinelCredential = ($SecretName -match '(?i)RELEASE_APP_(ID|PRIVATE_KEY)|SENTINEL')
    $looksLikeNpmToken = ($SecretName -match '(?i)NPM_TOKEN')

    if ($ReferencedByWorkflows.Count -eq 0) {
        return New-CapabilityRow -Capability "Secret: $SecretName" -Current 'configured, not referenced by any workflow found' -Target 'n/a' -Classification REVIEW_REQUIRED -Rationale 'No workflow in .github/workflows references this secret by name (a reference could exist in a workflow this scan could not read, or in a reusable/called workflow). Confirm before assuming it is unused.' -Destructive
    }

    if ($looksLikeSentinelCredential -and $ReleaseWorkflowUsesSentinelPattern) {
        return New-CapabilityRow -Capability "Secret: $SecretName" -Current "used by: $($ReferencedByWorkflows -join ', ')" -Target 'not required by the CDA Model B release architecture (immutable main, no release commit, no bypass identity)' -Classification REMOVE_CANDIDATE -Rationale 'Name and usage pattern match the legacy release-sentinel model (a GitHub App credential used to push a release commit past a protected main). CDA Model B does not write to main after merge, so this credential is not needed under the target architecture. This is a proven legacy mechanism, not a defect -- removal must be planned as part of the release-architecture migration phase, never deleted ad hoc.' -Destructive
    }

    if ($looksLikeNpmToken) {
        return New-CapabilityRow -Capability "Secret: $SecretName" -Current "used by: $($ReferencedByWorkflows -join ', ')" -Target 'npm Trusted Publishing (OIDC) -- no static token' -Classification REMOVE_CANDIDATE -Rationale 'CDA npm Library Profile v1 requires npm Trusted Publishing via OIDC; a static NPM_TOKEN is a legacy credential under the target model. Removal must happen only after the npm package''s Trusted Publisher binding is configured and verified working -- never before, or publishing breaks.' -Destructive
    }

    return New-CapabilityRow -Capability "Secret: $SecretName" -Current "used by: $($ReferencedByWorkflows -join ', ')" -Target 'unclassified' -Classification REVIEW_REQUIRED -Rationale 'Referenced by at least one workflow; purpose does not match a known legacy pattern this tool recognizes. Needs manual review to classify.'
}

function Get-PagesHygieneClassification {
    <#
        CDA repository baseline v1, "Repository hygiene": "No GitHub
        Pages configuration exists that is not actively populated by a
        current workflow." Presence alone is never a defect (baseline
        section 3, "Active vs Orphaned") -- only PROVEN orphan status is.
        Every input here is a plain, already-discovered fact (Discovery
        module output); nothing is inferred or guessed from this
        function's own logic. Missing/unreadable evidence is UNKNOWN,
        never silently treated as either "active" or "orphaned" -- this
        mirrors Get-DevelopDeletionClassification's own fail-closed
        philosophy exactly.

        Three evidence tiers, matching the brief's own strict-orphan-bar
        language (section 4):
          - STRONG active signal (a current workflow actually deploys to
            Pages, a recent/active build exists, a custom domain is
            bound, or the live URL actually serves content) -> COMPLIANT.
          - WEAK signal only (a workflow merely mentions Pages without
            deploying to it, historical-but-not-recent build activity, or
            a documentation reference) -> REVIEW_REQUIRED. Not eligible
            for the strict orphan bar; needs a human, not an automatic
            removal.
          - ZERO signal of any kind -> REMOVE_CANDIDATE. This is the
            baseline's own named counter-example
            (archi-semantic-core's orphaned github-pages configuration).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$EvidenceAvailable,
        [Parameter(Mandatory)] [bool]$Configured,
        [AllowNull()] [Nullable[bool]]$WorkflowDeploysPages = $null,
        [AllowNull()] [Nullable[bool]]$WorkflowReferencesPages = $null,
        [AllowNull()] [Nullable[bool]]$HasActiveOrRecentBuild = $null,
        [AllowNull()] [Nullable[bool]]$HasAnyBuildHistory = $null,
        [AllowNull()] [Nullable[bool]]$HasCustomDomain = $null,
        [AllowNull()] [Nullable[bool]]$LiveUrlServing = $null,
        [AllowNull()] [Nullable[bool]]$DocReferencesPages = $null
    )

    $cap = 'Hygiene: GitHub Pages configuration'
    if (-not $Configured) {
        return New-CapabilityRow -Capability $cap -Current 'absent' -Target 'absent' -Classification COMPLIANT -Rationale 'No GitHub Pages configuration exists for this repository -- nothing to clean up.' -Category BaselineHygiene
    }
    if (-not $EvidenceAvailable) {
        return New-CapabilityRow -Capability $cap -Current 'configured, evidence incomplete' -Target 'actively used, or absent' -Classification UNKNOWN -Rationale 'Pages is configured, but at least one required orphan-evidence signal (workflow deployment/reference, build history, live URL reachability, custom domain, documentation reference) could not be read reliably. Incomplete evidence is never treated as proof of orphan status.' -Category BaselineHygiene
    }

    $strongActiveSignals = @($WorkflowDeploysPages, $HasActiveOrRecentBuild, $HasCustomDomain, $LiveUrlServing) | Where-Object { $_ -eq $true }
    if (@($strongActiveSignals).Count -gt 0) {
        return New-CapabilityRow -Capability $cap -Current 'configured, actively used' -Target 'actively used, or absent' -Classification COMPLIANT -Rationale 'Pages is configured and at least one strong live-use signal (a current workflow deploys to it, a recent/active build exists, a custom domain is bound, or the live URL actually serves content) confirms it is not orphaned. Presence with active use is not a hygiene defect.' -Category BaselineHygiene
    }

    $weakSignals = @($WorkflowReferencesPages, $HasAnyBuildHistory, $DocReferencesPages) | Where-Object { $_ -eq $true }
    if (@($weakSignals).Count -gt 0) {
        return New-CapabilityRow -Capability $cap -Current 'configured, ambiguous evidence' -Target 'actively used, or absent' -Classification REVIEW_REQUIRED -Rationale 'Pages is configured; no strong active-use signal was found, but at least one weak signal (a non-deploying workflow reference, historical build activity, or a documentation reference) exists. This does not meet the strict orphan bar -- needs maintainer judgment, not an automatic removal.' -Category BaselineHygiene
    }

    return New-CapabilityRow -Capability $cap -Current 'configured, no deploying/referencing workflow, no build history, no custom domain, no live consumer, no doc reference, live URL not serving' -Target 'absent' -Classification REMOVE_CANDIDATE -Rationale 'Pages is configured but meets every strict orphan condition in the CDA repository baseline: no active or referencing workflow, no meaningful build/deployment history, no custom domain, no documentation dependency, and the live URL does not serve content. This is a direct instance of the baseline''s own named counter-example (archi-semantic-core''s orphaned github-pages configuration). Removal is destructive and requires explicit maintainer approval -- never -ApproveSafeChanges.' -Category BaselineHygiene -Destructive
}

function Get-EnvironmentHygieneClassification {
    <#
        CDA repository baseline v1, "Repository hygiene": "No GitHub
        Environment exists that is not referenced by any current
        workflow." Same fail-closed philosophy as
        Get-PagesHygieneClassification above: presence alone is never a
        defect, incomplete evidence is UNKNOWN (never orphaned), and
        genuine operational configuration (secrets, variables, protection
        rules, deployment history) on an otherwise workflow-unreferenced
        environment is REVIEW_REQUIRED, never a silent REMOVE_CANDIDATE
        -- the brief's own explicit instruction (section 14) that such
        configuration must never be silently discarded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$EnvironmentName,
        [Parameter(Mandatory)] [bool]$EvidenceAvailable,
        [Parameter(Mandatory)] [bool]$Exists,
        [AllowNull()] [Nullable[bool]]$WorkflowReferencesEnvironment = $null,
        [AllowNull()] [Nullable[bool]]$HasActiveOrRecentDeployment = $null,
        [AllowNull()] [Nullable[bool]]$HasAnyDeploymentHistory = $null,
        [AllowNull()] [Nullable[bool]]$HasOperationalProtectionRule = $null,
        [AllowNull()] [Nullable[bool]]$HasSecretsOrVariables = $null
    )

    $cap = "Hygiene: $EnvironmentName environment"
    if (-not $Exists) {
        return New-CapabilityRow -Capability $cap -Current 'absent' -Target 'absent' -Classification COMPLIANT -Rationale "No GitHub Environment named '$EnvironmentName' exists -- nothing to clean up." -Category BaselineHygiene
    }
    if (-not $EvidenceAvailable) {
        return New-CapabilityRow -Capability $cap -Current 'exists, evidence incomplete' -Target 'referenced by a workflow, or absent' -Classification UNKNOWN -Rationale "The '$EnvironmentName' environment exists, but at least one required orphan-evidence signal (workflow reference, deployment history, protection rules, secrets/variables metadata) could not be read reliably. Incomplete evidence is never treated as proof of orphan status." -Category BaselineHygiene
    }

    $strongActiveSignals = @($WorkflowReferencesEnvironment, $HasActiveOrRecentDeployment) | Where-Object { $_ -eq $true }
    if (@($strongActiveSignals).Count -gt 0) {
        return New-CapabilityRow -Capability $cap -Current 'exists, referenced by a workflow or has an active/recent deployment' -Target 'referenced by a workflow, or absent' -Classification COMPLIANT -Rationale "The '$EnvironmentName' environment is referenced by a current workflow or has an active/recent deployment -- presence is not a hygiene defect." -Category BaselineHygiene
    }

    if ($HasOperationalProtectionRule -eq $true -or $HasSecretsOrVariables -eq $true -or $HasAnyDeploymentHistory -eq $true) {
        return New-CapabilityRow -Capability $cap -Current 'exists, unreferenced by any current workflow, but carries operational configuration' -Target 'referenced by a workflow, or absent' -Classification REVIEW_REQUIRED -Rationale "No current workflow references '$EnvironmentName', but it still has real operational configuration (a protection rule, a secret/variable, or deployment history) that must never be silently discarded. Requires explicit maintainer review before any removal decision, even though it is orphaned by workflow-reference alone." -Category BaselineHygiene -Destructive
    }

    return New-CapabilityRow -Capability $cap -Current 'exists, unreferenced, no deployment history, no operational protection rules, no secrets/variables' -Target 'absent' -Classification REMOVE_CANDIDATE -Rationale "The '$EnvironmentName' environment meets every strict orphan condition in the CDA repository baseline: no referencing workflow, no active/recent or historical deployment, no operationally-needed protection rule, and no secrets or variables. This is a direct instance of the baseline's own named counter-example (archi-semantic-core's orphaned github-pages environment). Removal is destructive and requires explicit maintainer approval -- never -ApproveSafeChanges." -Category BaselineHygiene -Destructive
}

Export-ModuleMember -Function `
    Get-AdopterClassificationTaxonomy, New-CapabilityRow, ConvertTo-IdSlug, Get-StableOperationId, `
    Get-BooleanToggleClassification, Get-StructuralCapabilityClassification, `
    Get-ApprovalCountClassification, Get-DevelopDeletionClassification, Get-SecretClassification, `
    Get-PagesHygieneClassification, Get-EnvironmentHygieneClassification
