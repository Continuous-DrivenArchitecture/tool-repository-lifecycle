#Requires -Version 5.1
<#
    AdoptionPlan.psm1

    Turns a set of classified capability rows into a phased plan (never
    executed by this tool -- see README.md, "Future Apply model") and
    renders the human-readable Markdown report plus the machine-readable
    JSON model.
#>

Set-StrictMode -Version Latest

function Get-PhaseForRow {
    <#
        Heuristic bucketing of one classified capability row into a
        migration phase. This is a starting point for maintainer
        judgment, not an authoritative assignment -- see the report's own
        phase descriptions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Row)

    if ($Row.Classification -eq 'BLOCKED') { return 0 }

    $cap = $Row.Capability
    if ($cap -match '(?i)develop|default branch') { return 3 }
    if ($cap -match '(?i)sentinel|bypass actors|NPM_TOKEN|RELEASE_APP') { return 4 }
    if ($cap -match '(?i)secret:') {
        if ($Row.Classification -eq 'REMOVE_CANDIDATE') { return 6 }
        return 4
    }
    if ($cap -match '(?i)ruleset|required status check|SHA pinning|Allowed actions|Actions enabled|workflow permissions|merge (commit|methods)|squash|rebase') { return 2 }
    if ($cap -match '(?i)secret scanning|push protection|vulnerability|delete branch on merge|CodeQL|dependency review') {
        if ($Row.Classification -eq 'SAFE_CHANGE') { return 1 }
        return 5
    }
    return 5
}

function New-AdoptionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [array]$CapabilityRows)

    $actionable = $CapabilityRows | Where-Object { $_.Classification -notin @('COMPLIANT', 'NOT_AVAILABLE', 'KEEP_STRONGER') }

    # Keys are strings ("0".."7"), never bare integers: a
    # System.Collections.Specialized.OrderedDictionary's indexer treats an
    # Int32 key ambiguously with positional insertion once mixed with
    # assignment -- confirmed empirically (ArgumentOutOfRangeException on
    # `$dict[1] = x` when key 0 hadn't been added yet), not assumed.
    # String keys sidestep the ambiguity entirely.
    $phases = [ordered]@{
        '0' = @{ Name = 'PHASE 0 - Blockers / prerequisites'; Items = @() }
        '1' = @{ Name = 'PHASE 1 - Repository hygiene and safe settings'; Items = @() }
        '2' = @{ Name = 'PHASE 2 - CI normalization'; Items = @() }
        '3' = @{ Name = 'PHASE 3 - Branching migration'; Items = @() }
        '4' = @{ Name = 'PHASE 4 - Release architecture migration'; Items = @() }
        '5' = @{ Name = 'PHASE 5 - Security hardening'; Items = @() }
        '6' = @{ Name = 'PHASE 6 - Cleanup legacy configuration'; Items = @() }
        '7' = @{ Name = 'PHASE 7 - Final verification'; Items = @() }
    }

    foreach ($row in $actionable) {
        $phaseKey = "$(Get-PhaseForRow -Row $row)"
        $phases[$phaseKey].Items += $row
    }

    if ($phases['0'].Items.Count -eq 0 -and ($actionable | Where-Object { $_.Classification -ne 'BLOCKED' })) {
        $phases['7'].Items += (New-Object PSObject -Property @{
                Id                   = 'verification.reassess'
                Capability           = 'Final verification'
                Current              = 'n/a'
                Target               = 'n/a'
                Classification       = 'REVIEW_REQUIRED'
                Rationale            = 'After Phases 1-6 are approved and (in a future Apply capability) executed, re-run this assessment and confirm every capability reads COMPLIANT or KEEP_STRONGER.'
                RequiresManualChange = $false
                Destructive          = $false
            })
    }

    # Drop empty phases -- "Only include phases actually needed."
    $result = [ordered]@{}
    foreach ($key in $phases.Keys) {
        if ($phases[$key].Items.Count -gt 0) { $result[$key] = $phases[$key] }
    }
    return $result
}

function Get-ApprovalBoundary {
    <#
        Splits actionable rows into "could eventually be grouped for
        approval" vs. "needs individual, explicit approval" -- per brief
        section 19. Nothing here is ever auto-applied; this is
        classification of *future* approval granularity only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [array]$CapabilityRows)

    $groupable = @($CapabilityRows | Where-Object { $_.Classification -eq 'SAFE_CHANGE' })
    $individual = @($CapabilityRows | Where-Object { $_.Classification -in @('REVIEW_REQUIRED', 'REMOVE_CANDIDATE', 'BLOCKED') })
    return [PSCustomObject]@{ Groupable = $groupable; IndividualApproval = $individual }
}

function Get-FullCdaComplianceResult {
    <#
        CDA repository baseline v1 / npm Library Profile v1 distinguish
        PROFILE capabilities (the npm-library-specific target state --
        every pre-existing capability row) from BASELINE HYGIENE (orphan
        Pages/environment cleanup -- a baseline-level MUST, independent
        of any profile; see docs/standards/cda-repository-baseline-v1.md,
        "Repository hygiene", and Classification.psm1's
        Get-PagesHygieneClassification / Get-EnvironmentHygieneClassification,
        which are the only functions that ever produce a
        Category=BaselineHygiene row).

        Full CDA compliance requires BOTH categories to independently
        resolve, with zero BLOCKED, zero UNKNOWN, and zero unresolved
        REVIEW_REQUIRED/REMOVE_CANDIDATE anywhere across ALL rows -- never
        computed from the profile-only row count alone. This is
        deliberately conservative: a single unresolved hygiene gap (e.g.
        an orphaned github-pages environment) is enough to keep the
        overall result at PARTIAL even when every profile capability
        reads COMPLIANT.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [array]$CapabilityRows)

    $rows = @($CapabilityRows)
    $isHygiene = { param($r) $r.PSObject.Properties['Category'] -and "$($r.Category)" -eq 'BaselineHygiene' }
    $profileRows = @($rows | Where-Object { -not (& $isHygiene $_) })
    $hygieneRows = @($rows | Where-Object { & $isHygiene $_ })

    $resolvedClassifications = @('COMPLIANT', 'KEEP_STRONGER', 'NOT_AVAILABLE')
    $unresolvedRows = @($rows | Where-Object { "$($_.Classification)" -notin $resolvedClassifications })
    $blockedRows = @($rows | Where-Object { "$($_.Classification)" -eq 'BLOCKED' })
    $unknownRows = @($rows | Where-Object { "$($_.Classification)" -eq 'UNKNOWN' })

    $profileCompliance = (@($profileRows | Where-Object { "$($_.Classification)" -notin $resolvedClassifications }).Count -eq 0)
    $baselineHygieneCompliance = (@($hygieneRows | Where-Object { "$($_.Classification)" -notin $resolvedClassifications }).Count -eq 0)
    $overall = ($profileCompliance -and $baselineHygieneCompliance -and $blockedRows.Count -eq 0 -and $unknownRows.Count -eq 0 -and $unresolvedRows.Count -eq 0)

    $result = if ($overall) { 'PASS' } elseif ($blockedRows.Count -gt 0 -or $unknownRows.Count -gt 0) { 'BLOCKED' } else { 'PARTIAL' }

    $gaps = @($unresolvedRows | ForEach-Object {
            [PSCustomObject]@{
                Capability     = $_.Capability
                Classification = "$($_.Classification)"
                Category       = $(if (& $isHygiene $_) { 'BaselineHygiene' } else { 'Profile' })
            }
        })

    return [PSCustomObject]@{
        Result                    = $result
        ProfileCompliance         = $profileCompliance
        BaselineHygieneCompliance = $baselineHygieneCompliance
        ProfileRowCount           = $profileRows.Count
        BaselineHygieneRowCount   = $hygieneRows.Count
        RemainingGaps             = $gaps
    }
}

function ConvertTo-AdoptionMarkdownReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Assessment)

    $sb = New-Object System.Text.StringBuilder
    function Add([string]$line = '') { [void]$sb.AppendLine($line) }

    Add "# CDA Repository Adoption Assessment"
    Add ""
    Add "Repository: $($Assessment.Repository)"
    Add "Profile: $($Assessment.ProfileName) (source: $($Assessment.ProfileSourcePath))"
    Add "Assessment date: $($Assessment.AssessmentDate)"
    Add ""

    Add "## Executive summary"
    Add ""
    $counts = $Assessment.CapabilityRows | Group-Object Classification | Sort-Object Name
    $countText = ($counts | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
    Add "Current maturity: $countText"
    Add "Major differences: $($Assessment.Blockers.Count) blocker(s), $((@($Assessment.CapabilityRows | Where-Object {$_.Classification -eq 'REVIEW_REQUIRED'})).Count) review-required item(s)"
    Add "Blockers: $($Assessment.Blockers.Count)"
    Add "Safe changes: $((@($Assessment.CapabilityRows | Where-Object {$_.Classification -eq 'SAFE_CHANGE'})).Count)"
    Add "Review-required changes: $((@($Assessment.CapabilityRows | Where-Object {$_.Classification -eq 'REVIEW_REQUIRED'})).Count)"
    Add ""

    Add "## Current repository model"
    Add ""
    Add "Default branch: $($Assessment.Overview.DefaultBranch)"
    Add "Permanent branches (observed): $($Assessment.BranchAnalysis.PermanentBranchNames -join ', ')"
    Add "Effective development branch: $($Assessment.BranchAnalysis.EffectiveDevelopmentBranch)"
    Add "Release source: $($Assessment.ReleaseModel.ReleaseWorkflowFile)"
    Add "Merge strategy: squash=$($Assessment.Overview.AllowSquashMerge) merge=$($Assessment.Overview.AllowMergeCommit) rebase=$($Assessment.Overview.AllowRebaseMerge)"
    Add "Release architecture: $($Assessment.ReleaseModel.Model)"
    Add ""

    Add "## Branch analysis"
    Add ""
    Add "Branches: $($Assessment.BranchAnalysis.AllBranchNames -join ', ')"
    if ($Assessment.BranchAnalysis.MainDevelopComparison) {
        $c = $Assessment.BranchAnalysis.MainDevelopComparison
        Add "main...develop: status=$($c.Status), ahead_by=$($c.AheadBy), behind_by=$($c.BehindBy)"
    }
    $retirementEvidence = if ($Assessment.BranchAnalysis.PSObject.Properties['RetirementEvidence']) { $Assessment.BranchAnalysis.RetirementEvidence } else { $null }
    if ($retirementEvidence -and $retirementEvidence.Available) {
        $rev = $retirementEvidence
        Add ""
        Add "### Branch retirement evidence (develop)"
        Add ""
        if ($Assessment.BranchAnalysis.PSObject.Properties['InstalledGitVersion'] -and $Assessment.BranchAnalysis.InstalledGitVersion) {
            Add "Git version used for merge-reproducibility evidence: $($Assessment.BranchAnalysis.InstalledGitVersion)"
        }
        Add "Branch HEAD: $($rev.BranchHeadSha)"
        Add "Target HEAD: $($rev.TargetHeadSha)"
        Add "Merge base: $($rev.MergeBaseSha)"
        Add "Branch HEAD tree: $($rev.BranchHeadTreeSha)"
        Add "Target HEAD tree: $($rev.TargetHeadTreeSha)"
        Add "Merge base tree: $($rev.MergeBaseTreeSha)"
        Add "Branch-exclusive commits: $($rev.BranchExclusiveCommitCount)"
        Add "Target-exclusive commits: $($rev.TargetExclusiveCommitCount)"
        foreach ($e in @($rev.ExclusiveCommitEvidence)) {
            Add "  - $($e.Sha.Substring(0,7)) `"$($e.Subject)`""
            Add "      merge=$($e.IsMergeCommit) parents=$($e.Parents -join ',') parentsReachableFromTarget=$($e.ParentsReachableFromTarget)"
            Add "      recordedTree=$($e.TreeSha) historicalTreeUnique=$($e.HistoricalTreeUnique)"
            Add "      reproducedMergeTree=$($e.ReproducedMergeTreeSha) mergeTreeReproducible=$($e.MergeTreeReproducible) manualMergeResolutionDetected=$($e.ManualMergeResolutionDetected)"
            Add "      uniqueAuthoredContent=$($e.UniqueAuthoredContent) retirementEvidenceLevel=$($e.RetirementEvidenceLevel)"
        }
        Add "GRAPH DIVERGENCE: $(if ($rev.BranchExclusiveCommitCount -gt 0) { 'YES' } else { 'NO' })"
        Add "UNIQUE CONTENT DIVERGENCE: $(if ($rev.ContentUniqueToBranch) { 'YES' } else { 'NO' })"
        Add "SEMANTIC RETIREMENT PROOF: $(if ($rev.SemanticEquivalenceProven) { 'PASS' } elseif ($rev.RetirementEvidenceLevel -eq 'INSUFFICIENT') { 'INCONCLUSIVE' } else { 'NOT PROVEN' })"
        Add "RETIREMENT EVIDENCE LEVEL: $($rev.RetirementEvidenceLevel)"
        Add ""
    }
    $openPrCount = @($Assessment.BranchAnalysis.OpenPRsTargetingDevelop).Count
    $workflowsRefDevelop = @($Assessment.BranchAnalysis.WorkflowsReferencingDevelop)
    Add "Open PRs targeting develop: $openPrCount"
    Add "Workflows referencing develop: $($workflowsRefDevelop -join ', ')"
    Add "Dependabot targets develop: $($Assessment.BranchAnalysis.DependabotTargetsDevelop)"
    Add "Docs referencing develop: $($Assessment.BranchAnalysis.DocsReferencingDevelop -join ', ')"
    Add ""

    Add "## GitHub settings"
    Add ""
    Add "## Rulesets"
    Add ""
    Add "## CI / GitHub Actions"
    Add ""
    $workflowFiles = @($Assessment.Workflows | ForEach-Object { $_.File })
    Add ("Workflows discovered: " + ($workflowFiles -join ', '))
    Add ""
    Add "## Security"
    Add ""
    Add "## Secrets / variables"
    Add ""
    $secretNames = @(@($Assessment.SecretsMeta.Secrets) | ForEach-Object { $_.Name })
    $variableNames = @(@($Assessment.VariablesMeta.Variables) | ForEach-Object { $_.Name })
    Add ("Secrets (names only): " + ($secretNames -join ', '))
    Add ("Variables (names only): " + ($variableNames -join ', '))
    Add ""
    Add "## npm publishing"
    Add ""
    Add "Package name: $($Assessment.PackageName)"
    Add "package.json version: $($Assessment.PackageJsonVersion)"
    Add "npm registry version: $($Assessment.NpmRegistryVersion)"
    Add ""
    Add "## Release history"
    Add ""
    $tagsCount = @($Assessment.TagsAndReleases.Tags).Count
    $releasesCount = @($Assessment.TagsAndReleases.Releases).Count
    Add "Tags: $tagsCount"
    Add "GitHub Releases: $releasesCount"
    Add ""
    Add "## Documentation coherence"
    Add ""
    $docsRefDevelop = @($Assessment.BranchAnalysis.DocsReferencingDevelop)
    Add ("Docs referencing develop: " + ($(if ($docsRefDevelop.Count -gt 0) { $docsRefDevelop -join ', ' } else { 'none found' })))
    Add ""

    Add "## CDA comparison"
    Add ""
    Add "| Capability | Current | CDA Target | Classification | Rationale |"
    Add "|---|---|---|---|---|"
    foreach ($row in $Assessment.CapabilityRows) {
        $current = "$($row.Current)" -replace '\|', '\|'
        $target = "$($row.Target)" -replace '\|', '\|'
        $rationale = "$($row.Rationale)" -replace '\|', '\|'
        Add "| $($row.Capability) | $current | $target | $($row.Classification) | $rationale |"
    }
    Add ""

    Add "## Blockers"
    Add ""
    if ($Assessment.Blockers.Count -eq 0) { Add "None identified." }
    else { foreach ($b in $Assessment.Blockers) { Add "- $b" } }
    Add ""

    Add "## Safe change candidates"
    Add ""
    $safe = @($Assessment.CapabilityRows | Where-Object { $_.Classification -eq 'SAFE_CHANGE' })
    if ($safe.Count -eq 0) { Add "None." } else { foreach ($r in $safe) { Add "- $($r.Capability): $($r.Rationale)" } }
    Add ""

    Add "## Review required"
    Add ""
    $review = @($Assessment.CapabilityRows | Where-Object { $_.Classification -eq 'REVIEW_REQUIRED' })
    if ($review.Count -eq 0) { Add "None." } else { foreach ($r in $review) { Add "- $($r.Capability): $($r.Rationale)" } }
    Add ""

    Add "## Keep stronger"
    Add ""
    $stronger = @($Assessment.CapabilityRows | Where-Object { $_.Classification -eq 'KEEP_STRONGER' })
    if ($stronger.Count -eq 0) { Add "None." } else { foreach ($r in $stronger) { Add "- $($r.Capability): $($r.Rationale)" } }
    Add ""

    Add "## Remove candidates"
    Add ""
    $removeCand = @($Assessment.CapabilityRows | Where-Object { $_.Classification -eq 'REMOVE_CANDIDATE' })
    if ($removeCand.Count -eq 0) { Add "None." } else { foreach ($r in $removeCand) { Add "- $($r.Capability): $($r.Rationale)" } }
    Add ""

    Add "## Adoption plan"
    Add ""
    Add "Nothing below is executed by this tool. See README.md, 'Future Apply model'."
    Add ""
    foreach ($key in $Assessment.Plan.Keys) {
        $phase = $Assessment.Plan[$key]
        Add "### $($phase.Name)"
        Add ""
        foreach ($item in $phase.Items) {
            Add "- **Change:** $($item.Capability) ($($item.Current) -> $($item.Target))"
            Add "  **Why:** $($item.Rationale)"
            Add "  **Classification:** $($item.Classification)"
            Add "  **Verification condition:** re-run this assessment; the capability must read COMPLIANT (or KEEP_STRONGER, where applicable) afterward."
            Add ""
        }
    }

    Add "## Approval boundaries"
    Add ""
    Add "AUTO-APPLY CANDIDATES (after future approval):"
    $groupableRows = @($Assessment.ApprovalBoundary.Groupable)
    if ($groupableRows.Count -eq 0) { Add "- None." }
    else { foreach ($r in $groupableRows) { Add "- $($r.Capability)" } }
    Add ""
    Add "EXPLICIT APPROVAL REQUIRED:"
    $individualRows = @($Assessment.ApprovalBoundary.IndividualApproval)
    if ($individualRows.Count -eq 0) { Add "- None." }
    else { foreach ($r in $individualRows) { Add "- $($r.Capability) ($($r.Classification))" } }
    Add ""

    Add "## Final target state"
    Add ""
    Add "main as the only permanent branch; squash-only merges; Protect main ruleset active with ci-required as the sole required status check, strict, force-push and deletion blocked, zero bypass actors; Actions default token read, allowed_actions=selected (github-owned), SHA pinning required; secret scanning, push protection, Dependabot alerts, and CodeQL default setup all enabled; release model converged to CDA Model B (immutable main, semantic-release without @semantic-release/git, npm Trusted Publishing via OIDC, no NPM_TOKEN, no sentinel/bypass identity)."
    Add ""

    Add "## Full CDA compliance"
    Add ""
    $fullCda = Get-FullCdaComplianceResult -CapabilityRows $Assessment.CapabilityRows
    Add "Result: $($fullCda.Result)"
    Add "Profile compliance (npm Library Profile v1 target-state capabilities): $($fullCda.ProfileCompliance) ($($fullCda.ProfileRowCount) row(s))"
    Add "Baseline hygiene compliance (orphan Pages/environment cleanup): $($fullCda.BaselineHygieneCompliance) ($($fullCda.BaselineHygieneRowCount) row(s))"
    if ($fullCda.RemainingGaps.Count -eq 0) { Add "Remaining gaps: none." }
    else {
        Add "Remaining gaps:"
        foreach ($g in $fullCda.RemainingGaps) { Add "- [$($g.Category)] $($g.Capability): $($g.Classification)" }
    }
    Add ""
    Add "PASS is only reported when every profile capability AND every baseline-hygiene capability independently resolves (COMPLIANT/KEEP_STRONGER/NOT_AVAILABLE) with zero BLOCKED, zero UNKNOWN, and zero unresolved REVIEW_REQUIRED/REMOVE_CANDIDATE anywhere -- never inferred from the profile capability count alone."
    Add ""

    Add "## Mutations performed"
    Add ""
    Add "NONE"
    Add ""

    return $sb.ToString()
}

function ConvertTo-AdoptionJsonReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Assessment)

    $planArray = @()
    foreach ($key in $Assessment.Plan.Keys) {
        $phase = $Assessment.Plan[$key]
        $planArray += [PSCustomObject]@{
            phase = [int]$key
            name  = $phase.Name
            items = @(@($phase.Items) | ForEach-Object {
                    [PSCustomObject]@{
                        id                   = $_.Id
                        capability           = $_.Capability
                        current              = "$($_.Current)"
                        target               = "$($_.Target)"
                        classification       = $_.Classification
                        rationale            = $_.Rationale
                        requiresManualChange = [bool]$_.RequiresManualChange
                        destructive          = [bool]$_.Destructive
                    }
                })
        }
    }

    $obj = [PSCustomObject]@{
        schemaVersion    = '1.0'
        repository       = $Assessment.Repository
        profile          = $Assessment.ProfileName
        assessedAt       = $Assessment.AssessmentDate
        stateFingerprint = $Assessment.StateFingerprint
        capabilities     = @(@($Assessment.CapabilityRows) | ForEach-Object {
                [PSCustomObject]@{
                    id                   = $_.Id
                    name                 = $_.Capability
                    current              = "$($_.Current)"
                    target               = "$($_.Target)"
                    classification       = $_.Classification
                    rationale            = $_.Rationale
                    requiresManualChange = [bool]$_.RequiresManualChange
                    destructive          = [bool]$_.Destructive
                }
            })
        blockers = @($Assessment.Blockers)
        plan     = $planArray
        fullCdaCompliance = (Get-FullCdaComplianceResult -CapabilityRows $Assessment.CapabilityRows)
    }
    return ($obj | ConvertTo-Json -Depth 12)
}

Export-ModuleMember -Function Get-PhaseForRow, New-AdoptionPlan, Get-ApprovalBoundary, Get-FullCdaComplianceResult, ConvertTo-AdoptionMarkdownReport, ConvertTo-AdoptionJsonReport
