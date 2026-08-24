#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only CDA adoption assessment for an EXISTING npm-library
    repository: ASSESS -> COMPARE -> CLASSIFY -> PLAN. Never mutates
    anything -- see README.md, "Mutation guard".

.DESCRIPTION
    This is the EXISTING-repository sibling of commands/provision-
    npm-library.ps1 (which handles NEW repositories) -- see
    docs/lifecycle.md, "Provisioning != Adoption". It does not converge
    anything automatically. It produces a report a maintainer reads and,
    separately and later, approves (commands/approve-plan.ps1).

    Desired state is read from profiles/npm-library.json -- the same,
    single, already-approved profile commands/provision-npm-library.ps1
    uses for new repositories. This script never defines its own copy of
    that target.

.PARAMETER Repository
    "Continuous-DrivenArchitecture/<repo-name>". Any other owner is refused.

.PARAMETER OutputPath
    Optional path to write the Markdown report to.

.PARAMETER JsonOutputPath
    Optional path to write the machine-readable JSON assessment to.

.PARAMETER ProfilePath
    Defaults to profiles/npm-library.json at the repository root.

.PARAMETER AllowFork
    Explicit acknowledgement to assess a fork. Without it, a fork is still
    assessed (per the brief, forks are flagged, not rejected outright) but
    the flag makes the situation explicit in automation contexts.

.EXAMPLE
    .\assess-npm-library.ps1 -Repository Continuous-DrivenArchitecture/adapter-xma -OutputPath .\reports\adapter-xma-adoption.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Repository,

    [string]$OutputPath,

    [string]$JsonOutputPath,

    [string]$ProfilePath,

    [switch]$AllowFork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot '..\profiles\npm-library.json'
}

# Import order matters (learned the hard way while building this
# tooling): Comparison.psm1 imports Discovery.psm1 and Classification.psm1
# as NESTED modules of its own (and Discovery.psm1, in turn, nests
# src/common/github/ReadOnlyGitHub.psm1 + RepositoryDiscovery.psm1 +
# src/common/repository/Validation.psm1), which un-registers them as
# independent top-level modules. This script calls functions from all of
# them directly, so each leaf module is imported again, last, in the exact
# order needed to leave every one of them independently callable:
# Comparison first (establishing its own exports), then AdoptionPlan (no
# dependencies of its own), then Discovery, then Classification, then the
# common modules -- each later re-import restores that module's own
# top-level visibility without disturbing modules already finalized before
# it.
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\adopter\lib\Comparison.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\adopter\lib\AdoptionPlan.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\adopter\lib\Discovery.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\adopter\lib\Classification.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\adopter\lib\MergeReproducibility.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\ReadOnlyGitHub.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\github\RepositoryDiscovery.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\repository\Validation.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\common\profile\ProfileLoader.psm1') -Force

$profileResult = Get-EffectiveCdaProfile -Path $ProfilePath
if (-not $profileResult.Success) {
    Write-Error $profileResult.Error
    exit 2
}
$targetProfile = $profileResult.Profile

Write-Host ""
Write-Host "CDA repository adopter -- read-only assessment" -ForegroundColor Cyan
Write-Host "Repository : $Repository"
Write-Host "Profile    : $($targetProfile.profileName) (source: $ProfilePath)"
Write-Host "Mode       : ASSESS -> COMPARE -> CLASSIFY -> PLAN (no mutation is possible in this version)"
Write-Host ""

$nameCheck = Test-RepositoryNameFormat -Repository $Repository
if (-not $nameCheck.Valid) {
    Write-Host "BLOCKED: $($nameCheck.Reason)" -ForegroundColor Red
    exit 2
}

if (-not (Test-GhAuthenticated)) {
    Write-Host "BLOCKED: 'gh auth status' failed. Authenticate gh before running the adopter." -ForegroundColor Red
    exit 2
}

$eligibility = Test-RepositoryEligibility -Owner $nameCheck.Owner -Repo $nameCheck.Repo
if (-not $eligibility.Eligible) {
    Write-Host "BLOCKED: $($eligibility.Reason)" -ForegroundColor Red
    exit 2
}
if ($eligibility.IsFork -and -not $AllowFork) {
    Write-Host "NOTE: $Repository is a fork. Continuing (forks are flagged, not rejected), but pass -AllowFork to acknowledge this explicitly in automated contexts." -ForegroundColor Yellow
}

$owner = $nameCheck.Owner
$repo = $nameCheck.Repo
$repoData = $eligibility.RepoData
$defaultBranch = $repoData.default_branch

Write-Host "Discovering repository state (read-only)..." -ForegroundColor DarkGray

$overview = Get-RepositoryOverview -RepoData $repoData
$actionsState = Get-ActionsPermissionsState -Owner $owner -Repo $repo
$languages = @(Get-RepositoryLanguages -Owner $owner -Repo $repo)
$codeQL = Get-CodeQLState -Owner $owner -Repo $repo
$vulnAlerts = Get-VulnerabilityAlertsState -Owner $owner -Repo $repo
$rulesetsState = Get-AllRulesets -Owner $owner -Repo $repo
# @() immediately after every collection-returning call, always -- an
# empty result collapses to $null across a function-return boundary in
# this PowerShell version (confirmed empirically, not assumed), and a
# bare $null piped into a later Where-Object/ForEach-Object can throw
# under Set-StrictMode when the scriptblock dereferences a property on
# it. Normalizing here once means every use below can assume a real,
# possibly-empty array.
$branches = @(Get-AllBranches -Owner $owner -Repo $repo)
$tagsReleases = Get-TagsAndReleases -Owner $owner -Repo $repo
$openPRs = @(Get-OpenPullRequestsByBase -Owner $owner -Repo $repo)

# CONTENT REFERENCE BRANCH (bug found during a real PRODUCTION migration,
# 2026-08-23): every read below that asks "what does the repository's
# CODE currently look like" (workflow files, package.json, release
# config, required-check evidence) must NOT default to
# $defaultBranch -- that is exactly the GitHub SETTING this tool exists
# to help correct, and during the legacy-drift window it is stale by
# definition (still pointing at 'develop' while real development,
# including a materially different package.json and an additional
# release job in ci.yml, has already moved to 'main'). Confirmed live
# against a real repository: reading from $defaultBranch reported "no
# release workflow found" and a nonexistent version mismatch for a repo
# whose main branch actually had a full, working semantic-release +
# npm-Trusted-Publishing release job. Resolve the CDA target branch
# itself (main, or legacy master) as the content reference whenever it
# exists, falling back to $defaultBranch only if neither does -- same
# resolution Section 3's branch-comparison fix already uses, kept
# separate here because it is needed much earlier, before branch
# analysis runs.
$branchNamesEarly = @($branches | ForEach-Object { $_.Name })
$contentRef = if ($branchNamesEarly -contains 'main') { 'main' } elseif ($branchNamesEarly -contains 'master') { 'master' } else { $defaultBranch }

$workflows = @(Get-WorkflowsInventory -Owner $owner -Repo $repo -Ref $contentRef)
$contentRefCheckRuns = @(Get-CheckRunsForRef -Owner $owner -Repo $repo -Ref $contentRef)
$secretsMeta = Get-SecretsMetadata -Owner $owner -Repo $repo
$variablesMeta = Get-VariablesMetadata -Owner $owner -Repo $repo
$environmentsMeta = Get-EnvironmentsMetadata -Owner $owner -Repo $repo
$pagesConfig = Get-PagesConfig -Owner $owner -Repo $repo
$packageJson = Get-PackageJsonInfo -Owner $owner -Repo $repo -Ref $contentRef
$packageJsonSha = Get-FileSha -Owner $owner -Repo $repo -Path 'package.json' -Ref $contentRef
$releaseConfig = Get-ReleaseConfigText -Owner $owner -Repo $repo -Ref $contentRef
$releaseConfigSha = if ($releaseConfig) { Get-FileSha -Owner $owner -Repo $repo -Path $releaseConfig.File -Ref $contentRef } else { $null }
# Dependabot's own version-updates feature only ever reads
# .github/dependabot.yml from the repository's REAL GitHub default
# branch -- unlike the reads above, using $defaultBranch here is
# deliberate and correct, not the bug being fixed.
$dependabotText = Get-DependabotConfigText -Owner $owner -Repo $repo
$docSnapshot = Get-DocFileSnapshot -Owner $owner -Repo $repo
$npmVersion = if ($packageJson -and $packageJson.name) { Get-NpmRegistryVersion -PackageName $packageJson.name } else { $null }

# Initialized here (moved ahead of its previous position in "Analyzing
# branches") because the baseline-hygiene evidence block immediately
# below also appends to it -- see "Analyzing branches" further down for
# the develop-branch blockers this same list continues to collect.
$blockers = New-Object System.Collections.Generic.List[string]

# --- Baseline hygiene evidence: GitHub Pages / orphan environments ---
# (CDA repository baseline v1, "Repository hygiene" -- see
# docs/standards/cda-repository-baseline-v1.md, MUST rules for orphan
# workflows/environments/Pages configuration, and the named
# archi-semantic-core counter-example. Fresh discovery every run --
# never reused across assessments. Presence alone is never a defect
# (baseline section 3); only PROVEN orphan status is -- see
# Classification.psm1's Get-PagesHygieneClassification /
# Get-EnvironmentHygieneClassification for the strict evidence bar.)
Write-Host "Discovering baseline hygiene evidence (Pages / environments)..." -ForegroundColor DarkGray

$pagesBuilds = if ($pagesConfig.Configured) { Get-PagesBuilds -Owner $owner -Repo $repo } else { $null }
$pagesLiveUrlCheck = if ($pagesConfig.Configured -and $pagesConfig.HtmlUrl) { Test-PagesLiveUrl -Url $pagesConfig.HtmlUrl } else { $null }
$workflowsDeployingPages = @($workflows | Where-Object { $_.PSObject.Properties['ReferencesPagesDeployment'] -and $_.ReferencesPagesDeployment })
$workflowsMentioningPages = @($workflows | Where-Object { $_.Text -match '(?i)\bpages\b' })
$pagesEvidenceAvailable = [bool]($pagesConfig.Available -and (-not $pagesConfig.Configured -or ($pagesBuilds -and $pagesBuilds.Available)))
$pagesHygieneRow = Get-PagesHygieneClassification `
    -EvidenceAvailable $pagesEvidenceAvailable `
    -Configured ([bool]$pagesConfig.Configured) `
    -WorkflowDeploysPages ($workflowsDeployingPages.Count -gt 0) `
    -WorkflowReferencesPages ($workflowsMentioningPages.Count -gt 0) `
    -HasActiveOrRecentBuild $(if ($pagesBuilds -and $pagesBuilds.Available) { "$($pagesBuilds.MostRecentStatus)" -eq 'built' -and $pagesBuilds.BuildCount -gt 0 } else { $null }) `
    -HasAnyBuildHistory $(if ($pagesBuilds -and $pagesBuilds.Available) { $pagesBuilds.BuildCount -gt 0 } else { $null }) `
    -HasCustomDomain $(if ($pagesConfig.Configured) { -not [string]::IsNullOrEmpty($pagesConfig.CustomDomain) } else { $null }) `
    -LiveUrlServing $(if ($pagesLiveUrlCheck -and $pagesLiveUrlCheck.Available) { [bool]$pagesLiveUrlCheck.Reachable } else { $null }) `
    -DocReferencesPages ($docSnapshot.PagesReferences.Count -gt 0)
if ($pagesHygieneRow.Classification -in @('REMOVE_CANDIDATE', 'REVIEW_REQUIRED')) {
    $blockers.Add("GitHub Pages configuration: $($pagesHygieneRow.Rationale)") | Out-Null
}

$githubPagesEnvName = 'github-pages'
$environmentsList0 = @($environmentsMeta.Environments)
$githubPagesEnvExists = [bool]($environmentsMeta.Available -and @($environmentsList0 | Where-Object { "$($_.Name)" -eq $githubPagesEnvName }).Count -gt 0)
$envHygieneRow = $null
if ($environmentsMeta.Available -and -not $githubPagesEnvExists) {
    $envHygieneRow = Get-EnvironmentHygieneClassification -EnvironmentName $githubPagesEnvName -EvidenceAvailable $true -Exists $false
}
elseif (-not $environmentsMeta.Available) {
    # Existence itself could not be determined (the /environments list
    # call failed) -- Exists=$true here is a deliberate "assume it might
    # exist" choice, not a guess that it does: combined with
    # EvidenceAvailable=$false it routes to UNKNOWN regardless of the
    # environment's real state, which is the only safe answer when we
    # cannot even confirm presence/absence. Claiming Exists=$false instead
    # would wrongly reach COMPLIANT on a read failure.
    $envHygieneRow = Get-EnvironmentHygieneClassification -EnvironmentName $githubPagesEnvName -EvidenceAvailable $false -Exists $true
}
else {
    $envDetail = Get-EnvironmentDetail -Owner $owner -Repo $repo -EnvironmentName $githubPagesEnvName
    $envDeployments = Get-EnvironmentDeployments -Owner $owner -Repo $repo -EnvironmentName $githubPagesEnvName
    $envSecretsMeta = Get-EnvironmentSecretsMetadata -Owner $owner -Repo $repo -EnvironmentName $githubPagesEnvName
    $envVariablesMeta = Get-EnvironmentVariablesMetadata -Owner $owner -Repo $repo -EnvironmentName $githubPagesEnvName
    $envReferencingWorkflows = @($workflows | Where-Object { $_.Text -match "environment:\s*(\r?\n\s*name:\s*)?$([regex]::Escape($githubPagesEnvName))" })
    $envEvidenceAvailable = [bool]($envDetail.Available -and $envDeployments.Available -and $envSecretsMeta.Available -and $envVariablesMeta.Available)
    $envHasOperationalProtection = if ($envDetail.Available) { [bool]([int]$envDetail.WaitTimerSeconds -gt 0 -or [int]$envDetail.RequiredReviewersCount -gt 0 -or [bool]$envDetail.HasBranchPolicy) } else { $null }
    $envHasSecretsOrVariables = if ($envSecretsMeta.Available -and $envVariablesMeta.Available) { [bool](@($envSecretsMeta.Secrets).Count -gt 0 -or @($envVariablesMeta.Variables).Count -gt 0) } else { $null }
    $envHasAnyDeploymentHistory = if ($envDeployments.Available) { [bool]($envDeployments.DeploymentCount -gt 0) } else { $null }
    $envHasActiveOrRecentDeployment = if ($envDeployments.Available) { [Nullable[bool]]$envDeployments.MostRecentActive } else { $null }
    $envHygieneRow = Get-EnvironmentHygieneClassification `
        -EnvironmentName $githubPagesEnvName `
        -EvidenceAvailable $envEvidenceAvailable `
        -Exists $true `
        -WorkflowReferencesEnvironment ($envReferencingWorkflows.Count -gt 0) `
        -HasActiveOrRecentDeployment $envHasActiveOrRecentDeployment `
        -HasAnyDeploymentHistory $envHasAnyDeploymentHistory `
        -HasOperationalProtectionRule $envHasOperationalProtection `
        -HasSecretsOrVariables $envHasSecretsOrVariables
}
if ($envHygieneRow.Classification -in @('REMOVE_CANDIDATE', 'REVIEW_REQUIRED')) {
    $blockers.Add("GitHub Environment '$githubPagesEnvName': $($envHygieneRow.Rationale)") | Out-Null
}

Write-Host "Analyzing branches..." -ForegroundColor DarkGray

$branchNames = $branchNamesEarly
$hasDevelop = ($branchNames -contains 'develop')
$mainDevelopComparison = $null
$developDeletionRow = $null
$developRetirementEvidence = $null
$installedGitVersion = $null

if ($hasDevelop) {
    # BUG FIX (found during a real production migration, 2026-08-23):
    # this used to compare -Base $defaultBranch -Head 'develop'. When the
    # repository's CURRENT default branch is literally 'develop' (the
    # single most common legacy-drift scenario this tool exists to
    # detect and migrate away from), that degenerates into comparing
    # develop against itself -- always "identical, ahead_by=0,
    # behind_by=0" no matter what the real 'main' branch actually
    # contains. Confirmed against a real repository where main had
    # genuinely diverged (45 commits, including real semantic-release
    # commits) while this comparison still reported "identical". develop
    # must always be compared against the CDA target's actual permanent
    # branch, resolved the same way $contentRef was above (main, or
    # legacy master) -- never against "whatever GitHub currently calls
    # default", which is exactly the setting this tool is trying to
    # correct. Unlike $contentRef (which always resolves to SOMETHING,
    # best-effort), this deliberately becomes $null -- and therefore
    # UNKNOWN, never a guess -- when $contentRef itself could only fall
    # back to 'develop' (no main/master exists at all).
    $compareBaseBranch = if ($contentRef -ne 'develop') { $contentRef } else { $null }

    $developRefWorkflows = @($workflows | Where-Object { $_.ReferencesDevelop } | ForEach-Object { $_.File })
    $dependabotTargetsDevelop = [bool]($dependabotText -and $dependabotText -match 'target-branch:\s*develop')
    $openPRsToDevelop = @($openPRs | Where-Object { $_.Base -eq 'develop' })
    $docsRefDevelop = @($docSnapshot.DevelopReferences)

    if (-not $compareBaseBranch) {
        $blockers.Add("develop exists but no 'main' or 'master' branch was found to compare it against -- develop's deletion safety cannot be established.") | Out-Null
        $developDeletionRow = New-CapabilityRow -Capability 'Branch: delete develop' -Current 'comparison unavailable' -Target 'deleted (main-only)' -Classification UNKNOWN -Rationale "No 'main' or 'master' branch exists to compare develop against."
    }
    else {
        $mainDevelopComparison = Get-BranchComparison -Owner $owner -Repo $repo -Base $compareBaseBranch -Head 'develop'
        if (-not $mainDevelopComparison.Available) {
            $blockers.Add("Could not compare '$compareBaseBranch' and 'develop' via the GitHub compare API (ErrorKind: $($mainDevelopComparison.ErrorKind)) -- develop's deletion safety cannot be established.") | Out-Null
            $developDeletionRow = New-CapabilityRow -Capability 'Branch: delete develop' -Current 'comparison unavailable' -Target 'deleted (main-only)' -Classification UNKNOWN -Rationale "Could not establish ahead/behind status between $compareBaseBranch and develop."
        }
        else {
            $hasUniqueCommits = ([int]$mainDevelopComparison.AheadBy -gt 0)
            # GRAPH divergence vs UNIQUE CONTENT divergence (brief section
            # 2/3): only spend the extra API calls computing tree/content
            # evidence when there IS graph divergence to explain. A
            # commit subject like "merge: sync ..." is never trusted
            # alone -- Get-BranchRetirementEvidence derives everything
            # from tree SHAs and live ancestry checks.
            if ($hasUniqueCommits) {
                $developRetirementEvidence = Get-BranchRetirementEvidence -Owner $owner -Repo $repo -Branch 'develop' -TargetBranch $compareBaseBranch
                $installedGitVersion = Get-InstalledGitVersion
            }
            $semanticEquivalenceProven = if ($hasUniqueCommits -and $developRetirementEvidence -and $developRetirementEvidence.Available) { [bool]$developRetirementEvidence.SemanticEquivalenceProven } else { $null }
            $developDeletionRow = Get-DevelopDeletionClassification `
                -HasCommitsNotInMain $hasUniqueCommits `
                -HasOpenPRsTargetingDevelop ($openPRsToDevelop.Count -gt 0) `
                -WorkflowsReferenceDevelop ($developRefWorkflows.Count -gt 0) `
                -DependabotTargetsDevelop $dependabotTargetsDevelop `
                -DocsReferenceDevelop ($docsRefDevelop.Count -gt 0) `
                -SemanticEquivalenceProven $semanticEquivalenceProven `
                -BranchExclusiveCommitCount $(if ($developRetirementEvidence) { [int]$developRetirementEvidence.BranchExclusiveCommitCount } else { 0 })
            if ($developDeletionRow.Classification -eq 'BLOCKED') {
                $blockers.Add("develop contains $($mainDevelopComparison.AheadBy) commit(s) not reachable from $compareBaseBranch, and semantic-equivalence evidence does not prove they are free of unique content.") | Out-Null
            }
        }
    }
}

$branchAnalysis = [PSCustomObject]@{
    AllBranchNames              = $branchNames
    PermanentBranchNames        = @($branchNames | Where-Object { $_ -in @('main', 'master', 'develop') })
    EffectiveDevelopmentBranch  = if ($hasDevelop) { 'develop (permanent branch pattern present -- see Branch analysis for evidence)' } else { $defaultBranch }
    HasDevelop                  = $hasDevelop
    MainDevelopComparison       = $mainDevelopComparison
    OpenPRsTargetingDevelop     = if ($hasDevelop) { @($openPRs | Where-Object { $_.Base -eq 'develop' }) } else { @() }
    WorkflowsReferencingDevelop = if ($hasDevelop) { @($workflows | Where-Object { $_.ReferencesDevelop } | ForEach-Object { $_.File }) } else { @() }
    DependabotTargetsDevelop    = if ($hasDevelop) { [bool]($dependabotText -and $dependabotText -match 'target-branch:\s*develop') } else { $false }
    DocsReferencingDevelop      = @($docSnapshot.DevelopReferences)
    RetirementEvidence          = $developRetirementEvidence
    InstalledGitVersion         = $installedGitVersion
}

Write-Host "Classifying capabilities..." -ForegroundColor DarkGray

$rows = New-Object System.Collections.Generic.List[object]

# --- Repository settings ---
$rows.Add((Get-StructuralCapabilityClassification -Capability 'Default branch' -Applicable $true -Current $overview.DefaultBranch -Target $targetProfile.repositorySettings.defaultBranch -ReviewRationale 'Changing the default branch affects PR defaults, workflow triggers, and every contributor''s local checkout; never a mechanical change.')) | Out-Null
$rows.Add((Get-BooleanToggleClassification -Capability 'Delete branch on merge' -Applicable $true -Current $overview.DeleteBranchOnMerge -TargetOn ([bool]$targetProfile.repositorySettings.deleteBranchOnMerge))) | Out-Null
$rows.Add((Get-StructuralCapabilityClassification -Capability 'Allow squash merge' -Applicable $true -Current $overview.AllowSquashMerge -Target ([bool]$targetProfile.repositorySettings.allowSquashMerge) -ReviewRationale 'Merge-method availability affects contributor workflow and commit-history shape.')) | Out-Null
$rows.Add((Get-StructuralCapabilityClassification -Capability 'Allow merge commit' -Applicable $true -Current $overview.AllowMergeCommit -Target ([bool]$targetProfile.repositorySettings.allowMergeCommit) -ReviewRationale 'Disabling an in-use merge method blocks any open PR relying on it until merged another way.')) | Out-Null
$rows.Add((Get-StructuralCapabilityClassification -Capability 'Allow rebase merge' -Applicable $true -Current $overview.AllowRebaseMerge -Target ([bool]$targetProfile.repositorySettings.allowRebaseMerge) -ReviewRationale 'Disabling an in-use merge method blocks any open PR relying on it until merged another way.')) | Out-Null
$rows.Add((Get-BooleanToggleClassification -Capability 'Allow auto-merge' -Applicable $true -Current $overview.AllowAutoMerge -TargetOn ([bool]$targetProfile.repositorySettings.allowAutoMerge))) | Out-Null

# --- Actions ---
$rows.Add((Get-StructuralCapabilityClassification -Capability 'Actions enabled' -Applicable $actionsState.Available -Current $actionsState.Enabled -Target ([bool]$targetProfile.actions.enabled))) | Out-Null
$rows.Add((Get-StructuralCapabilityClassification -Capability 'Allowed actions policy' -Applicable $actionsState.Available -Current $actionsState.AllowedActionsPolicy -Target $targetProfile.actions.allowedActionsPolicy -ReviewRationale 'Restricting the allowed-actions policy can break an existing workflow that references an action outside the new allow-list; must be checked against the actual workflow inventory before changing (see CI / GitHub Actions section).')) | Out-Null

$allUnpinned = @($workflows | ForEach-Object { $_.UnpinnedActions } | Where-Object { $_ })
if (-not $actionsState.ShaPinningAvailable) {
    $rows.Add((New-CapabilityRow -Capability 'SHA pinning required' -Current 'n/a' -Target ([bool]$targetProfile.actions.shaPinningRequired) -Classification NOT_AVAILABLE -Rationale 'Not exposed by the API for this repository/plan.')) | Out-Null
}
elseif ($actionsState.ShaPinningRequired -eq [bool]$targetProfile.actions.shaPinningRequired) {
    $rows.Add((New-CapabilityRow -Capability 'SHA pinning required' -Current $actionsState.ShaPinningRequired -Target ([bool]$targetProfile.actions.shaPinningRequired) -Classification COMPLIANT -Rationale 'Already matches the CDA target.')) | Out-Null
}
elseif ($allUnpinned.Count -eq 0) {
    $rows.Add((New-CapabilityRow -Capability 'SHA pinning required' -Current $actionsState.ShaPinningRequired -Target $true -Classification SAFE_CHANGE -Rationale 'Every action reference discovered across all workflow files is already pinned to a full commit SHA, so enforcing the setting would not break anything already present. (Does not account for workflow files this scan could not read.)')) | Out-Null
}
else {
    $rows.Add((New-CapabilityRow -Capability 'SHA pinning required' -Current $actionsState.ShaPinningRequired -Target $true -Classification REVIEW_REQUIRED -Rationale "At least one unpinned action reference was found ($($allUnpinned.Count) across scanned workflows: $(($allUnpinned | Select-Object -Unique) -join ', ')). Enforcing SHA pinning before those are fixed would break CI on the next run.")) | Out-Null
}

$rows.Add((Get-StructuralCapabilityClassification -Capability 'Default workflow permissions' -Applicable ($null -ne $actionsState.DefaultWorkflowPerms) -Current $actionsState.DefaultWorkflowPerms -Target $targetProfile.actions.defaultWorkflowPermissions -ReviewRationale 'Tightening from write to read can silently break a workflow step that relied on the elevated default without declaring its own permissions: block. Verify every workflow that needs write already declares it explicitly (see CI / GitHub Actions section) before changing this.')) | Out-Null

# --- Security ---
$rows.Add((Get-BooleanToggleClassification -Capability 'Secret scanning' -Applicable ($null -ne $overview.SecretScanning) -Current $(if ($overview.SecretScanning) { $overview.SecretScanning -eq 'enabled' } else { $null }) -TargetOn ($targetProfile.security.secretScanning -eq 'enabled'))) | Out-Null
$rows.Add((Get-BooleanToggleClassification -Capability 'Secret scanning push protection' -Applicable ($null -ne $overview.SecretScanningPush) -Current $(if ($overview.SecretScanningPush) { $overview.SecretScanningPush -eq 'enabled' } else { $null }) -TargetOn ($targetProfile.security.secretScanningPushProtection -eq 'enabled'))) | Out-Null
$rows.Add((Get-BooleanToggleClassification -Capability 'Dependabot security updates' -Applicable ($null -ne $overview.DependabotSecUpdates) -Current $(if ($overview.DependabotSecUpdates) { $overview.DependabotSecUpdates -eq 'enabled' } else { $null }) -TargetOn ($targetProfile.security.dependabotSecurityUpdates -eq 'enabled'))) | Out-Null
$rows.Add((Get-BooleanToggleClassification -Capability 'Dependabot vulnerability alerts' -Applicable $vulnAlerts.Applicable -Current $vulnAlerts.Enabled -TargetOn ([bool]$targetProfile.security.vulnerabilityAlerts))) | Out-Null

$codeQLApplicableLangs = @($targetProfile.security.codeQLDefaultSetup.applicableLanguages)
$codeQLApplicable = [bool](@($languages) | Where-Object { $_ -in $codeQLApplicableLangs })
if (-not $codeQLApplicable) {
    $rows.Add((New-CapabilityRow -Capability 'CodeQL default setup' -Current 'n/a' -Target 'configured' -Classification NOT_AVAILABLE -Rationale 'Repository contains no JavaScript/TypeScript.')) | Out-Null
}
else {
    $rows.Add((Get-BooleanToggleClassification -Capability 'CodeQL default setup' -Applicable $codeQL.DefaultSetupAvailable -Current $(if ($codeQL.DefaultSetupState) { $codeQL.DefaultSetupState -eq 'configured' } else { $null }) -TargetOn $true)) | Out-Null
}

# --- Rulesets (handles "no other ruleset assumed to be Protect main" + multiples) ---
$targetRuleset = $targetProfile.ruleset
foreach ($r in (New-RulesetCapabilityRows -RulesetsState $rulesetsState -TargetRuleset $targetRuleset)) { $rows.Add($r) | Out-Null }

# --- Branch: develop ---
if ($null -ne $developDeletionRow) { $rows.Add($developDeletionRow) | Out-Null }

# --- Secrets (metadata only, classified by name pattern + usage) ---
$releaseModel = Get-ReleaseModelSummary -Workflows $workflows -ReleaseConfig $releaseConfig -SecretsMeta $secretsMeta
if ($secretsMeta.Available) {
    foreach ($s in $secretsMeta.Secrets) {
        $referencedBy = @($workflows | Where-Object { $_.Text -match [regex]::Escape($s.Name) } | ForEach-Object { $_.File })
        $rows.Add((Get-SecretClassification -SecretName $s.Name -ReferencedByWorkflows $referencedBy -ReleaseWorkflowUsesSentinelPattern $releaseModel.UsesSentinelPattern)) | Out-Null
    }
}
else {
    $rows.Add((New-CapabilityRow -Capability 'Secrets (list)' -Current 'unavailable' -Target 'n/a' -Classification UNKNOWN -Rationale "Could not list repository secrets (ErrorKind: $($secretsMeta.ErrorKind)).")) | Out-Null
}

# --- Release-architecture migration checklist (repository FILE changes;
# Apply v1 can never execute these -- see RequiresManualChange) ---
foreach ($r in (New-ReleaseMigrationRows -ReleaseModel $releaseModel -DependabotTargetsDevelop $branchAnalysis.DependabotTargetsDevelop)) { $rows.Add($r) | Out-Null }

# --- Baseline hygiene: GitHub Pages / github-pages environment (CDA
# repository baseline v1, "Repository hygiene" -- distinct from the
# npm-library PROFILE rows above; see AdoptionPlan.psm1's
# Get-FullCdaComplianceResult for how the two categories combine) ---
$rows.Add($pagesHygieneRow) | Out-Null
$rows.Add($envHygieneRow) | Out-Null

# --- Additional blockers (section 15) ---
if ($rulesetsState.Available) {
    $named = @($rulesetsState.Rulesets | Where-Object { (Get-RulesetName $_) -eq $targetRuleset.name -and -not ($_.PSObject.Properties['FetchFailed'] -and $_.FetchFailed) })
    if ($named.Count -eq 1) {
        $rsc = $named[0].rules | Where-Object { $_.type -eq 'required_status_checks' } | Select-Object -First 1
        if ($rsc) {
            foreach ($ctx in @($rsc.parameters.required_status_checks | ForEach-Object { $_.context })) {
                # BUG FIX (found during live sandbox integration testing,
                # 2026-08-23): a required check's context is a JOB/check
                # name (e.g. "ci-required"), not a WORKFLOW name (e.g.
                # "CI") -- comparing against Get-RecentWorkflowRuns'
                # `.Name` (the workflow's own name) can never match a
                # correctly-configured matrix-independent summary job,
                # producing a false "not observed" blocker even when the
                # check genuinely just succeeded. Get-CheckRunsForRef
                # reads the actual named check runs on $contentRef's tip
                # commit instead (the CDA target branch, not necessarily
                # GitHub's current default -- see $contentRef's own
                # comment above) -- the same mechanism repository-
                # provisioner's own evidence check already uses.
                $matchingCheckRuns = @($contentRefCheckRuns | Where-Object { $_.Name -eq $ctx })
                if ($matchingCheckRuns.Count -eq 0) {
                    $blockers.Add("Ruleset 'Protect main' requires status check '$ctx', which was not observed among the named check runs on '$contentRef''s tip commit -- it may reference a job/workflow that no longer exists.") | Out-Null
                }
                elseif (-not (@($matchingCheckRuns | Where-Object { $_.Conclusion -eq 'success' }).Count -gt 0)) {
                    $blockers.Add("Ruleset 'Protect main' requires status check '$ctx', which ran on '$contentRef''s tip commit but did not conclude successfully.") | Out-Null
                }
            }
        }
    }
}
if ($releaseModel.UsesSentinelPattern -and -not $releaseModel.UsesIdTokenOidc) {
    $blockers.Add('Release workflow appears to use a legacy sentinel/bypass credential and does not show evidence of OIDC (id-token: write); the npm publishing mechanism should be confirmed manually before any release-architecture migration is planned.') | Out-Null
}
$environmentsList = @($environmentsMeta.Environments)
if ($environmentsMeta.Available -and $environmentsList.Count -gt 0) {
    $blockers.Add("$($environmentsList.Count) GitHub Environment(s) exist ($((@($environmentsList | ForEach-Object { $_.Name })) -join ', ')) -- confirm none would be affected before changing ruleset or Actions settings.") | Out-Null
}

# .ToArray(), not @($rows): wrapping a System.Collections.Generic.List[T]
# in @() throws "argument types don't match" under Set-StrictMode in this
# environment -- confirmed empirically in isolation, not assumed.
# .ToArray() is the unambiguous way to get a plain array back from it.
$capabilityRows = $rows.ToArray()
$plan = New-AdoptionPlan -CapabilityRows $capabilityRows
$approvalBoundary = Get-ApprovalBoundary -CapabilityRows $capabilityRows

# --- State fingerprint (brief section 13): what Apply's preflight will
# re-read and compare against before ever mutating anything. Deliberately
# built only from data already fetched above -- no extra API calls beyond
# the two file-SHA lookups already made for package.json/release config.
$branchShaByName = @{}
foreach ($b in $branches) { $branchShaByName[$b.Name] = $b.Sha }
$rulesetFingerprints = @()
if ($rulesetsState.Available) {
    foreach ($rs in $rulesetsState.Rulesets) {
        if ($rs.PSObject.Properties['FetchFailed'] -and $rs.FetchFailed) { continue }
        $rulesetFingerprints += [PSCustomObject]@{
            Id        = $rs.id
            Name      = Get-RulesetName $rs
            UpdatedAt = if ($rs.PSObject.Properties['updated_at']) { $rs.updated_at } else { $null }
        }
    }
}
$workflowShas = @($workflows | ForEach-Object { [PSCustomObject]@{ File = $_.File; Sha = $_.Sha } })

$stateFingerprint = [PSCustomObject]@{
    CapturedAt        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    DefaultBranch     = $defaultBranch
    DefaultBranchSha  = $(if ($branchShaByName.ContainsKey($defaultBranch)) { $branchShaByName[$defaultBranch] } else { $null })
    MainSha           = $(if ($branchShaByName.ContainsKey('main')) { $branchShaByName['main'] } else { $null })
    DevelopSha        = $(if ($branchShaByName.ContainsKey('develop')) { $branchShaByName['develop'] } else { $null })
    Rulesets          = $rulesetFingerprints
    WorkflowShas      = $workflowShas
    ReleaseConfigFile = if ($releaseConfig) { $releaseConfig.File } else { $null }
    ReleaseConfigSha  = $releaseConfigSha
    PackageJsonSha    = $packageJsonSha
    ActionsPermissions = [PSCustomObject]@{
        Enabled              = $actionsState.Enabled
        AllowedActionsPolicy = $actionsState.AllowedActionsPolicy
        ShaPinningRequired   = $actionsState.ShaPinningRequired
    }
    DevelopRetirementEvidence = if ($developRetirementEvidence -and $developRetirementEvidence.Available) {
        [PSCustomObject]@{
            BranchHeadSha         = $developRetirementEvidence.BranchHeadSha
            TargetHeadSha         = $developRetirementEvidence.TargetHeadSha
            MergeBaseSha          = $developRetirementEvidence.MergeBaseSha
            BranchHeadTreeSha     = $developRetirementEvidence.BranchHeadTreeSha
            ContentUniqueToBranch = $developRetirementEvidence.ContentUniqueToBranch
            SemanticEquivalenceProven = $developRetirementEvidence.SemanticEquivalenceProven
        }
    } else { $null }
}

$assessment = [PSCustomObject]@{
    Repository         = $Repository
    ProfileName        = $targetProfile.profileName
    ProfileSourcePath  = (Resolve-Path -LiteralPath $ProfilePath).Path
    AssessmentDate     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    StateFingerprint   = $stateFingerprint
    Overview           = $overview
    IsFork             = $eligibility.IsFork
    BranchAnalysis     = $branchAnalysis
    ReleaseModel       = $releaseModel
    Workflows          = $workflows
    SecretsMeta        = $secretsMeta
    VariablesMeta      = $variablesMeta
    EnvironmentsMeta   = $environmentsMeta
    PagesConfig        = $pagesConfig
    PagesBuilds        = $pagesBuilds
    PagesLiveUrlCheck  = $pagesLiveUrlCheck
    PagesHygiene       = $pagesHygieneRow
    GithubPagesEnvironmentHygiene = $envHygieneRow
    PackageName        = if ($packageJson) { $packageJson.name } else { $null }
    PackageJsonVersion = if ($packageJson) { $packageJson.version } else { $null }
    NpmRegistryVersion = $npmVersion
    TagsAndReleases    = $tagsReleases
    CapabilityRows     = $capabilityRows
    Blockers           = $blockers.ToArray()
    Plan               = $plan
    ApprovalBoundary   = $approvalBoundary
}

$markdown = ConvertTo-AdoptionMarkdownReport -Assessment $assessment
Write-Host ""
Write-Host $markdown

if ($OutputPath) {
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($OutputPath, $markdown, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Markdown report written to: $OutputPath" -ForegroundColor Green
}
if ($JsonOutputPath) {
    $json = ConvertTo-AdoptionJsonReport -Assessment $assessment
    $dir = Split-Path -Parent $JsonOutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($JsonOutputPath, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "JSON report written to: $JsonOutputPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "Mutations performed: NONE" -ForegroundColor Green
exit 0
