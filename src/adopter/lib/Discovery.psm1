#Requires -Version 5.1
<#
    Discovery.psm1

    Read-only state gathering for an EXISTING repository. Every function
    here calls Invoke-ReadOnlyGitHub (GET-only) or shells out to a
    read-only local command (git ls-remote, npm view). Nothing in this
    file writes anywhere -- not to GitHub, not to a local checkout, not to
    npm. No function accepts a value to write; every parameter is an
    identifier (Owner/Repo/branch name/etc.), never content.
#>

Set-StrictMode -Version Latest

# Read-only-only, by construction: this module (and everything that
# imports it) may only ever pull in ReadOnlyGitHub.psm1 -- never
# MutationGitHub.psm1. tests/run-tests.ps1's read-only boundary check
# scans this file's own source text to enforce that structurally, not
# just by convention. Test-RepositoryFormat/Test-RepositoryEligibility,
# Get-RepositoryOverview/Get-RepositoryLanguages/Get-ActionsPermissionsState/
# Get-VulnerabilityAlertsState/Get-CodeQLState/Get-AllRulesets used to be
# defined locally in this file; they are now shared with the provisioner
# lifecycle path via src/common (see docs/architecture.md, "Common core")
# -- every call site below is unchanged, since the shared versions keep
# the exact same names and return shapes.
Import-Module (Join-Path $PSScriptRoot '..\..\common\github\ReadOnlyGitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\common\github\RepositoryDiscovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\common\repository\Validation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MergeReproducibility.psm1') -Force

function Get-AllBranches {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $branches = @(Get-ReadOnlyGitHubPaged -Path "repos/$Owner/$Repo/branches")
    return @($branches | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Sha = $_.commit.sha; Protected = [bool]$_.protected } })
}

function Get-BranchComparison {
    <#
        Uses GitHub's compare API (read-only) to establish real ahead/
        behind counts and ancestry between two branches -- never assumed,
        never inferred from names.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Base, [Parameter(Mandatory)] [string]$Head)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/compare/$Base...$Head"
    if (-not $result.Success) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $result.ErrorKind; AheadBy = $null; BehindBy = $null; Status = $null; MergeBaseCommit = $null }
    }
    return [PSCustomObject]@{
        Available       = $true
        ErrorKind       = $null
        AheadBy         = $result.Data.ahead_by
        BehindBy        = $result.Data.behind_by
        Status          = $result.Data.status # "identical" | "ahead" | "behind" | "diverged"
        MergeBaseCommit = $result.Data.merge_base_commit.sha
    }
}

function Test-CommitReachableFromRef {
    <#
        Read-only ancestry check: is $Sha an ancestor of (reachable from)
        $Ref? Uses the compare API the same way the rest of this module
        already does (never git-clones, never assumes). compare(base=Ref,
        head=Sha).ahead_by == 0 means $Sha contributes nothing $Ref does
        not already have -- i.e. $Sha is on $Ref's own history.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Ref, [Parameter(Mandatory)] [string]$Sha)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/compare/$Ref...$Sha"
    if (-not $result.Success) { return $null }
    return ([int]$result.Data.ahead_by -eq 0)
}

function Get-BranchRetirementEvidence {
    <#
        Distinguishes GRAPH divergence (the branch has commits main
        cannot reach, by commit-graph topology alone) from UNIQUE CONTENT
        divergence (any of those commits actually introduces a tree state
        not already represented in the target branch's own history).
        Commit subjects like "merge: sync ..." are never trusted alone --
        every conclusion here is derived from tree SHAs and ancestry
        checks against live GitHub state (brief section 2/3: "content/tree
        evidence is authoritative").

        Capped at 50 branch-exclusive commits: beyond that this function
        refuses to guess (Available=$false) rather than issue dozens of
        extra API calls for a branch that is not a small, nearly-merged
        integration branch in the first place.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Branch, [Parameter(Mandatory)] [string]$TargetBranch)

    $notAvailable = [PSCustomObject]@{
        Available = $false; Branch = $Branch; TargetBranch = $TargetBranch
        BranchHeadSha = $null; TargetHeadSha = $null; MergeBaseSha = $null
        BranchExclusiveCommitCount = $null; TargetExclusiveCommitCount = $null
        BranchHeadTreeSha = $null; TargetHeadTreeSha = $null; MergeBaseTreeSha = $null
        ExclusiveCommitEvidence = @(); ContentUniqueToBranch = $null
        SemanticEquivalenceProven = $false; RetirementEvidenceLevel = 'INSUFFICIENT'; RetirementEligible = $false
        Reason = $null
    }

    $branchRef = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/branches/$Branch"
    if (-not $branchRef.Success) { $notAvailable.Reason = "could not read branch $Branch"; return $notAvailable }
    $branchHeadSha = "$($branchRef.Data.commit.sha)"
    $targetRef = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/branches/$TargetBranch"
    if (-not $targetRef.Success) { $notAvailable.Reason = "could not read branch $TargetBranch"; return $notAvailable }
    $targetHeadSha = "$($targetRef.Data.commit.sha)"

    $cmp = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/compare/$TargetBranch...$Branch"
    if (-not $cmp.Success) { $notAvailable.Reason = "could not compare $TargetBranch...$Branch"; return $notAvailable }
    $mergeBaseSha = "$($cmp.Data.merge_base_commit.sha)"

    $exclusiveCommits = @($cmp.Data.commits)
    if ($exclusiveCommits.Count -gt 50) { $notAvailable.Reason = "$($exclusiveCommits.Count) branch-exclusive commits exceeds the 50-commit cap for deep tree analysis"; return $notAvailable }

    $branchHeadCommit = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/git/commits/$branchHeadSha"
    $targetHeadCommit = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/git/commits/$targetHeadSha"
    $mergeBaseCommit = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/git/commits/$mergeBaseSha"
    if (-not $branchHeadCommit.Success -or -not $targetHeadCommit.Success -or -not $mergeBaseCommit.Success) {
        $notAvailable.Reason = 'could not read one or more commit objects for tree comparison'
        return $notAvailable
    }
    $branchHeadTreeSha = "$($branchHeadCommit.Data.tree.sha)"
    $targetHeadTreeSha = "$($targetHeadCommit.Data.tree.sha)"
    $mergeBaseTreeSha = "$($mergeBaseCommit.Data.tree.sha)"

    # Fetch each exclusive commit's parent tree + live reachability-from-
    # target once per unique parent SHA (cached), then hand everything
    # already-fetched to the PURE evidence-computation function below --
    # kept as a separate function specifically so it can be unit-tested
    # without any GitHub API mocking (brief section 6).
    $parentInfoCache = @{}
    $rawCommits = @()
    $needsMirror = $false
    foreach ($commit in $exclusiveCommits) {
        $parents = @($commit.parents | ForEach-Object { "$($_.sha)" })
        if ($parents.Count -gt 1) { $needsMirror = $true }
        $parentInfo = @()
        foreach ($p in $parents) {
            if (-not $parentInfoCache.ContainsKey($p)) {
                $reachable = Test-CommitReachableFromRef -Owner $Owner -Repo $Repo -Ref $TargetBranch -Sha $p
                $pCommit = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/git/commits/$p"
                $pTree = if ($pCommit.Success) { "$($pCommit.Data.tree.sha)" } else { $null }
                $parentInfoCache[$p] = [PSCustomObject]@{ Sha = $p; TreeSha = $pTree; ReachableFromTarget = $reachable }
            }
            $parentInfo += $parentInfoCache[$p]
        }
        $rawCommits += [PSCustomObject]@{
            Sha        = "$($commit.sha)"
            Subject    = ("$($commit.commit.message)" -split "`n" | Select-Object -First 1)
            TreeSha    = "$($commit.commit.tree.sha)"
            ParentInfo = $parentInfo
        }
    }

    # Merge-reproducibility evidence (brief: "MERGE REPRODUCIBILITY
    # EVIDENCE") -- distinguishes "this tree never existed as a commit
    # on target" (a graph/history fact, already captured above) from
    # "this tree contains content nobody else can reach" (a content
    # fact). Only attempted for two-parent exclusive commits -- cheap
    # relative to the 50-commit cap already enforced above, and skipped
    # entirely (no mirror ever created) when there are none, so a branch
    # with only non-merge exclusive commits never pays this cost.
    if ($needsMirror) {
        $mirrorPath = Initialize-LocalRepoMirror -Owner $Owner -Repo $Repo -CacheRoot (Join-Path ([System.IO.Path]::GetTempPath()) 'repository-adopter-mirrors')
        foreach ($rc in $rawCommits) {
            if (@($rc.ParentInfo).Count -eq 2 -and $mirrorPath) {
                $p1 = $rc.ParentInfo[0].Sha
                $p2 = $rc.ParentInfo[1].Sha
                $repro = Test-GitMergeReproducible -RepoPath $mirrorPath -Parent1Sha $p1 -Parent2Sha $p2 -RecordedTreeSha $rc.TreeSha
                $rc | Add-Member -NotePropertyName MergeReproducibility -NotePropertyValue $repro -Force
            }
        }
    }

    $semantics = Test-BranchRetirementSemantics -BranchHeadTreeSha $branchHeadTreeSha -TargetHeadTreeSha $targetHeadTreeSha -MergeBaseTreeSha $mergeBaseTreeSha -ExclusiveCommits $rawCommits

    return [PSCustomObject]@{
        Available                  = $true
        Branch                     = $Branch
        TargetBranch               = $TargetBranch
        BranchHeadSha              = $branchHeadSha
        TargetHeadSha              = $targetHeadSha
        MergeBaseSha               = $mergeBaseSha
        BranchExclusiveCommitCount = $exclusiveCommits.Count
        TargetExclusiveCommitCount = [int]$cmp.Data.behind_by
        BranchHeadTreeSha          = $branchHeadTreeSha
        TargetHeadTreeSha          = $targetHeadTreeSha
        MergeBaseTreeSha           = $mergeBaseTreeSha
        ExclusiveCommitEvidence    = $semantics.ExclusiveCommitEvidence
        ContentUniqueToBranch      = $semantics.ContentUniqueToBranch
        SemanticEquivalenceProven  = $semantics.SemanticEquivalenceProven
        RetirementEvidenceLevel    = $semantics.RetirementEvidenceLevel
        RetirementEligible         = $semantics.SemanticEquivalenceProven
        Reason                     = $null
    }
}

function Test-BranchRetirementSemantics {
    <#
        PURE evidence-computation core of Get-BranchRetirementEvidence --
        no API calls, no side effects. Takes already-fetched tree SHAs
        and per-exclusive-commit parent info (Sha/TreeSha/
        ReachableFromTarget, one entry per parent) and decides, from tree
        content alone, whether each exclusive commit introduces content
        unique to the branch, and whether the branch as a whole is
        semantically equivalent to something already reachable from the
        target branch's own history. Deliberately separated from the I/O
        wrapper so this can be unit-tested directly (brief section 6)
        without mocking GitHub API calls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BranchHeadTreeSha,
        [Parameter(Mandatory)] [string]$TargetHeadTreeSha,
        [Parameter(Mandatory)] [string]$MergeBaseTreeSha,
        [AllowNull()] [AllowEmptyCollection()] [array]$ExclusiveCommits = @()
    )
    $ExclusiveCommits = @($ExclusiveCommits)

    # Trees reachable from target's own history, seeded with target HEAD
    # and the merge-base (both are, by definition, on target's ancestry),
    # grown with every exclusive commit's parent tree that is itself
    # proven reachable. Built in a full first pass so evaluation order
    # among exclusive commits never matters.
    $reachableTreeShas = New-Object 'System.Collections.Generic.HashSet[string]'
    [void]$reachableTreeShas.Add("$TargetHeadTreeSha")
    [void]$reachableTreeShas.Add("$MergeBaseTreeSha")
    foreach ($commit in $ExclusiveCommits) {
        foreach ($p in @($commit.ParentInfo)) {
            if ($p.ReachableFromTarget -eq $true -and $p.TreeSha) { [void]$reachableTreeShas.Add("$($p.TreeSha)") }
        }
    }

    # MERGE REPRODUCIBILITY EVIDENCE: a merge commit's tree has never
    # existed as a commit tree on target (a GRAPH fact, captured by
    # $treeMatchesReachable above) is NOT the same claim as "this merge
    # contains content nobody else can reach" (a CONTENT fact). A clean
    # 3-way merge of two independently-reachable trees mechanically
    # produces a third, genuinely new tree SHA without introducing a
    # single byte the two parents didn't already have between them. The
    # decision tree below is evaluated in this exact order, per exclusive
    # commit, and never guesses past what was actually proven:
    #   1. tree trivially matches something reachable -> proven, done.
    #   2. not a two-parent merge -> a new tree here IS authored content.
    #   3. a two-parent merge but not BOTH parents reachable from target
    #      -> conservative: at least one side is itself unexplained.
    #   4. both parents reachable, but no reproduction attempt was
    #      supplied (no MergeReproducibility info attached by the I/O
    #      wrapper, e.g. the local mirror could not be established) ->
    #      INSUFFICIENT, never silently treated as proven OR as unique.
    #   5. reproduction attempted and exact match -> proven, no unique
    #      authored content (MERGE_HISTORY_REPRODUCIBLE).
    #   6. reproduction attempted and mismatched/conflicted -> real
    #      evidence of manual resolution -> unique authored content.
    #   7. reproduction attempted but itself inconclusive (Reproducible
    #      is $null, e.g. parent objects missing from the mirror) ->
    #      INSUFFICIENT, never guessed either way.
    $exclusiveEvidence = @()
    foreach ($commit in $ExclusiveCommits) {
        $treeMatchesReachable = $reachableTreeShas.Contains("$($commit.TreeSha)")
        $parentInfoArr = @($commit.ParentInfo)
        $isMerge = ($parentInfoArr.Count -gt 1)
        $bothParentsReachable = $isMerge -and (@($parentInfoArr | Where-Object { $_.ReachableFromTarget -eq $true }).Count -eq $parentInfoArr.Count)
        $mergeRepro = if ($commit.PSObject.Properties['MergeReproducibility']) { $commit.MergeReproducibility } else { $null }

        $uniqueAuthoredContent = $null
        $evidenceLevel = 'INSUFFICIENT'
        $manualResolutionDetected = $false

        if ($treeMatchesReachable) {
            $uniqueAuthoredContent = $false
            $evidenceLevel = 'CURRENT_STATE_EQUIVALENT'
        }
        elseif (-not $isMerge) {
            $uniqueAuthoredContent = $true
            $evidenceLevel = 'UNIQUE_AUTHORED_CONTENT'
        }
        elseif (-not $bothParentsReachable) {
            $uniqueAuthoredContent = $true
            $evidenceLevel = 'UNIQUE_AUTHORED_CONTENT'
        }
        elseif ($null -eq $mergeRepro) {
            $uniqueAuthoredContent = $null
            $evidenceLevel = 'INSUFFICIENT'
        }
        elseif ($mergeRepro.Reproducible -eq $true) {
            $uniqueAuthoredContent = $false
            $evidenceLevel = 'MERGE_HISTORY_REPRODUCIBLE'
        }
        elseif ($mergeRepro.Reproducible -eq $false) {
            $uniqueAuthoredContent = $true
            $evidenceLevel = 'UNIQUE_AUTHORED_CONTENT'
            $manualResolutionDetected = $true
        }
        else {
            # $mergeRepro.Reproducible -eq $null: attempted, inconclusive.
            $uniqueAuthoredContent = $null
            $evidenceLevel = 'INSUFFICIENT'
        }

        $exclusiveEvidence += [PSCustomObject]@{
            Sha                                = $commit.Sha
            Subject                            = $commit.Subject
            Parents                            = @($parentInfoArr | ForEach-Object { $_.Sha })
            TreeSha                            = $commit.TreeSha
            ParentTreeShas                     = @($parentInfoArr | ForEach-Object { $_.TreeSha })
            IsMergeCommit                      = $isMerge
            ParentsReachableFromTarget          = $bothParentsReachable
            TreeMatchesReachableTargetHistory  = $treeMatchesReachable
            HistoricalTreeUnique               = (-not $treeMatchesReachable)
            RecordedTreeSha                    = $commit.TreeSha
            ReproducedMergeTreeSha             = if ($mergeRepro) { $mergeRepro.ReproducedTreeSha } else { $null }
            MergeTreeReproducible              = if ($mergeRepro) { $mergeRepro.Reproducible } else { $null }
            ManualMergeResolutionDetected      = $manualResolutionDetected
            UniqueAuthoredContent              = $uniqueAuthoredContent
            RetirementEvidenceLevel            = $evidenceLevel
            # Back-compat name (pre-dates merge-reproducibility): true
            # unless PROVEN false -- unknown/insufficient is never
            # silently treated as "not unique".
            IntroducesUniqueTreeState          = ($uniqueAuthoredContent -ne $false)
        }
    }

    $anyProvenUnique = (@($exclusiveEvidence | Where-Object { $_.UniqueAuthoredContent -eq $true }).Count -gt 0)
    $anyInsufficient = (@($exclusiveEvidence | Where-Object { $null -eq $_.UniqueAuthoredContent }).Count -gt 0)
    $contentUniqueToBranch = $anyProvenUnique
    # The branch tip is "represented in target history" either trivially
    # (its tree literally matches something reachable) OR because the
    # exclusive commit AT the branch tip was itself individually proven
    # explained above (CURRENT_STATE_EQUIVALENT or
    # MERGE_HISTORY_REPRODUCIBLE) -- a merge-reproducible tip's tree is a
    # genuinely new SHA by construction, so checking raw reachable-tree
    # membership alone would always fail it even when fully proven.
    $branchHeadTreeMatchesTarget = $reachableTreeShas.Contains("$BranchHeadTreeSha") -or
        (@($exclusiveEvidence | Where-Object { $_.TreeSha -eq "$BranchHeadTreeSha" -and $_.UniqueAuthoredContent -eq $false }).Count -gt 0)
    $semanticEquivalenceProven = (-not $anyProvenUnique) -and (-not $anyInsufficient) -and $branchHeadTreeMatchesTarget
    $overallLevel = if ($semanticEquivalenceProven) { 'FULL_RETIREMENT_EVIDENCE' } elseif ($anyProvenUnique) { 'UNIQUE_AUTHORED_CONTENT' } elseif ($anyInsufficient) { 'INSUFFICIENT' } else { 'CURRENT_STATE_EQUIVALENT' }

    return [PSCustomObject]@{
        ExclusiveCommitEvidence   = $exclusiveEvidence
        ContentUniqueToBranch     = $contentUniqueToBranch
        SemanticEquivalenceProven = $semanticEquivalenceProven
        RetirementEvidenceLevel   = $overallLevel
    }
}

function Get-TagsAndReleases {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $tags = @(Get-ReadOnlyGitHubPaged -Path "repos/$Owner/$Repo/tags")
    $releases = @(Get-ReadOnlyGitHubPaged -Path "repos/$Owner/$Repo/releases")
    return [PSCustomObject]@{
        Tags     = @($tags | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Sha = $_.commit.sha } })
        Releases = @($releases | ForEach-Object { [PSCustomObject]@{ TagName = $_.tag_name; Name = $_.name; Draft = [bool]$_.draft; Prerelease = [bool]$_.prerelease; PublishedAt = $_.published_at } })
    }
}

function Get-OpenPullRequestsByBase {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $prs = @(Get-ReadOnlyGitHubPaged -Path "repos/$Owner/$Repo/pulls?state=open")
    return @($prs | ForEach-Object { [PSCustomObject]@{ Number = $_.number; Title = $_.title; Base = $_.base.ref; Head = $_.head.ref } })
}

function Get-FileSha {
    <#
        Blob SHA of one file via the Contents API -- used only to build
        the state fingerprint an approved plan is checked against before
        Apply runs (see Approval.psm1 / Apply.psm1). $null if the file
        does not exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Path, [string]$Ref)

    $p = "repos/$Owner/$Repo/contents/$Path"
    if ($Ref) { $p += "?ref=$Ref" }
    $result = Invoke-ReadOnlyGitHub -Path $p
    if (-not $result.Success -or $null -eq $result.Data) { return $null }
    return $result.Data.sha
}

function Get-WorkflowFileText {
    <#
        Fetches one file's raw text via the Contents API. $null if absent.

        -Ref is OPTIONAL and, when omitted, resolves server-side to
        GitHub's own idea of the repository's default branch -- which is
        exactly the wrong thing to rely on for reading a repository's
        CURRENT/real content whenever that default branch setting itself
        is stale (a repo still defaulting to 'develop' while real
        development has moved to 'main' is exactly the legacy-drift
        pattern this tool exists to detect). Callers reading content that
        must reflect the true, current state of the repository (package
        .json, release config, workflow files for classification) MUST
        pass an explicit -Ref -- see assess-npm-library.ps1's $contentRef.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Path, [string]$Ref)

    $p = "repos/$Owner/$Repo/contents/$Path"
    if ($Ref) { $p += "?ref=$Ref" }
    $result = Invoke-ReadOnlyGitHub -Path $p
    if (-not $result.Success -or -not $result.Data -or -not $result.Data.content) { return $null }
    $bytes = [Convert]::FromBase64String(($result.Data.content -replace "`n", ''))
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-WorkflowsInventory {
    <#
        -Ref is OPTIONAL for backward compatibility, but callers doing
        real governance classification (SHA pinning, ci-required
        evidence, sentinel/NPM_TOKEN/semantic-release references, develop
        references) MUST pass one -- see the matching comment on
        Get-WorkflowFileText. Confirmed live that a repository's real,
        currently-executing ci.yml can differ materially (a whole
        additional release job, different lint/test steps) from the copy
        sitting on a stale default branch.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [string]$Ref)

    $listingPath = "repos/$Owner/$Repo/contents/.github/workflows"
    if ($Ref) { $listingPath += "?ref=$Ref" }
    $listing = Invoke-ReadOnlyGitHub -Path $listingPath
    if (-not $listing.Success -or $null -eq $listing.Data) { return @() }

    $inventory = @()
    foreach ($entry in @($listing.Data)) {
        if ($entry.type -ne 'file') { continue }
        if ($entry.name -notmatch '\.ya?ml$') { continue }
        $text = Get-WorkflowFileText -Owner $Owner -Repo $Repo -Path ".github/workflows/$($entry.name)" -Ref $Ref
        if ($null -eq $text) { continue }

        $referencesDevelop = [bool]($text -match '\bdevelop\b')
        $usesLines = [regex]::Matches($text, 'uses:\s*([^\s#]+)') | ForEach-Object { $_.Groups[1].Value.Trim() }
        $unpinned = @($usesLines | Where-Object { $_ -notmatch '@[0-9a-f]{40}$' -and -not ($_.StartsWith('./') -or $_.StartsWith('.\')) })
        $pinned = @($usesLines | Where-Object { $_ -match '@[0-9a-f]{40}$' })
        $triggersOn = [regex]::Match($text, '(?ms)^on:\s*(.+?)^\S', 'None')
        $hasPushMain = [bool]($text -match 'push:[\s\S]{0,200}?branches:[\s\S]{0,100}?\bmain\b')
        $hasPushDevelop = [bool]($text -match 'push:[\s\S]{0,200}?branches:[\s\S]{0,100}?\bdevelop\b')
        $hasPullRequest = [bool]($text -match '(?m)^\s*pull_request:')
        $hasSchedule = [bool]($text -match '(?m)^\s*schedule:')
        $hasWorkflowDispatch = [bool]($text -match '(?m)^\s*workflow_dispatch:')
        $nameMatch = [regex]::Match($text, '(?m)^name:\s*(.+)$')

        $inventory += [PSCustomObject]@{
            File                 = $entry.name
            Sha                  = $entry.sha
            Name                 = if ($nameMatch.Success) { $nameMatch.Groups[1].Value.Trim() } else { $entry.name }
            ReferencesDevelop    = $referencesDevelop
            ActionsUsed          = @($usesLines | Select-Object -Unique)
            UnpinnedActions      = @($unpinned | Select-Object -Unique)
            PinnedActions        = @($pinned | Select-Object -Unique)
            TriggersOnPushMain   = $hasPushMain
            TriggersOnPushDevelop = $hasPushDevelop
            TriggersOnPullRequest = $hasPullRequest
            TriggersOnSchedule   = $hasSchedule
            TriggersOnDispatch   = $hasWorkflowDispatch
            ReferencesPagesDeployment = [bool]($text -match 'actions/deploy-pages|actions/upload-pages-artifact|actions/configure-pages')
            ReferencesSentinel   = [bool]($text -match 'create-github-app-token|RELEASE_APP_ID|RELEASE_APP_PRIVATE_KEY|sentinel')
            ReferencesSemanticRelease = [bool]($text -match 'semantic-release')
            ReferencesNpmToken   = [bool]($text -match 'NPM_TOKEN')
            ReferencesIdToken    = [bool]($text -match 'id-token:\s*write')
            RawTextLength        = $text.Length
            Text                 = $text
        }
    }
    return $inventory
}

function Get-CheckRunsForRef {
    <#
        Named check runs (e.g. "ci-required", "lint", "test (20)") on one
        ref's tip commit -- the correct source of truth for "has this
        specific required check actually executed", since a required
        status check's context is a JOB/check name, not a WORKFLOW name.
        Comparing a check context against Get-RecentWorkflowRuns' `.Name`
        (the workflow's own name, e.g. "CI") is a category error: a
        matrix-independent summary job named "ci-required" living inside
        a workflow named "CI" would never match "CI" -- confirmed
        empirically against a real ruleset requiring "ci-required" that
        had genuinely just succeeded, not assumed. Mirrors
        repository-provisioner's own Test-RequiredCheckEvidence (same
        endpoint, same contract).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Ref)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/commits/$Ref/check-runs"
    if (-not $result.Success -or $null -eq $result.Data) { return @() }
    return @(@($result.Data.check_runs) | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Conclusion = $_.conclusion } })
}

function Get-RecentWorkflowRuns {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [int]$Count = 30)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/runs?per_page=$Count"
    if (-not $result.Success -or $null -eq $result.Data) { return @() }
    return @(@($result.Data.workflow_runs) | ForEach-Object {
            [PSCustomObject]@{
                Name       = $_.name
                Event      = $_.event
                Branch     = $_.head_branch
                Status     = $_.status
                Conclusion = $_.conclusion
                CreatedAt  = $_.created_at
            }
        })
}

function Get-SecretsMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/secrets"
    if (-not $result.Success -or $null -eq $result.Data) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $result.ErrorKind; Secrets = @() }
    }
    $secrets = @(@($result.Data.secrets) | ForEach-Object { [PSCustomObject]@{ Name = $_.name; CreatedAt = $_.created_at; UpdatedAt = $_.updated_at } })
    return [PSCustomObject]@{ Available = $true; ErrorKind = $null; Secrets = $secrets }
}

function Get-VariablesMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/variables"
    if (-not $result.Success -or $null -eq $result.Data) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $result.ErrorKind; Variables = @() }
    }
    $vars = @(@($result.Data.variables) | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Value = $null; UpdatedAt = $_.updated_at } })
    return [PSCustomObject]@{ Available = $true; ErrorKind = $null; Variables = $vars }
}

function Get-EnvironmentsMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/environments"
    if (-not $result.Success -or $null -eq $result.Data) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $result.ErrorKind; Environments = @() }
    }
    $envs = @(@($result.Data.environments) | ForEach-Object { [PSCustomObject]@{ Name = $_.name; ProtectionRuleCount = @($_.protection_rules).Count } })
    return [PSCustomObject]@{ Available = $true; ErrorKind = $null; Environments = $envs }
}

function Get-EnvironmentDetail {
    <#
        Single-environment detail, used for baseline-hygiene orphan
        evidence (brief Phase 7, section 3): protection rules are
        returned INLINE by GitHub on this endpoint (wait_timer /
        required_reviewers / branch_policy sub-objects), never as
        separate calls. Never reads a secret/variable VALUE -- see
        Get-EnvironmentSecretsMetadata / Get-EnvironmentVariablesMetadata
        below for names-only metadata.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$EnvironmentName)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/environments/$EnvironmentName"
    if (-not $result.Success) {
        $exists = ($result.ErrorKind -ne 'NotFound')
        return [PSCustomObject]@{ Available = ($result.ErrorKind -eq 'NotFound'); ErrorKind = $result.ErrorKind; Exists = $exists; Name = $EnvironmentName; WaitTimerSeconds = $null; RequiredReviewersCount = $null; HasBranchPolicy = $null; DeploymentBranchPolicy = $null; CreatedAt = $null; UpdatedAt = $null }
    }
    $rules = @($result.Data.protection_rules)
    $waitTimerRule = @($rules | Where-Object { $_.type -eq 'wait_timer' }) | Select-Object -First 1
    $reviewerRule = @($rules | Where-Object { $_.type -eq 'required_reviewers' }) | Select-Object -First 1
    $branchPolicyRule = @($rules | Where-Object { $_.type -eq 'branch_policy' })
    return [PSCustomObject]@{
        Available              = $true
        ErrorKind              = $null
        Exists                 = $true
        Name                   = "$($result.Data.name)"
        WaitTimerSeconds       = if ($waitTimerRule) { $waitTimerRule.wait_timer } else { $null }
        RequiredReviewersCount = if ($reviewerRule) { @($reviewerRule.reviewers).Count } else { 0 }
        HasBranchPolicy        = ($branchPolicyRule.Count -gt 0)
        DeploymentBranchPolicy = $result.Data.deployment_branch_policy
        CreatedAt              = $result.Data.created_at
        UpdatedAt              = $result.Data.updated_at
    }
}

function Get-EnvironmentDeployments {
    <#
        Deployment history for one named environment via the repository
        deployments API filtered by ?environment=. The most recent
        deployment's own status is fetched (one extra GET) to distinguish
        "a deployment exists, historically" from "a deployment is
        currently active/in-progress" -- the brief's own distinction
        (section 3) between deployment HISTORY and an ACTIVE deployment.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$EnvironmentName)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/deployments?environment=$EnvironmentName&per_page=100"
    if (-not $result.Success -or $null -eq $result.Data) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $result.ErrorKind; DeploymentCount = 0; MostRecentCreatedAt = $null; MostRecentSha = $null; MostRecentActive = $null }
    }
    $deployments = @($result.Data)
    $mostRecent = if ($deployments.Count -gt 0) { $deployments[0] } else { $null }
    $mostRecentActive = $null
    if ($mostRecent) {
        $statusResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/deployments/$($mostRecent.id)/statuses?per_page=1"
        if ($statusResult.Success -and $null -ne $statusResult.Data) {
            $latestStatus = @($statusResult.Data) | Select-Object -First 1
            if ($latestStatus) { $mostRecentActive = ("$($latestStatus.state)" -in @('success', 'in_progress', 'queued', 'pending')) }
        }
    }
    return [PSCustomObject]@{
        Available           = $true
        ErrorKind           = $null
        DeploymentCount     = $deployments.Count
        MostRecentCreatedAt = if ($mostRecent) { $mostRecent.created_at } else { $null }
        MostRecentSha       = if ($mostRecent) { $mostRecent.sha } else { $null }
        MostRecentActive    = $mostRecentActive
    }
}

function Get-EnvironmentSecretsMetadata {
    <# Names + UpdatedAt only -- see Get-SecretsMetadata's own contract above. Value is always $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$EnvironmentName)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/environments/$EnvironmentName/secrets"
    if (-not $result.Success -or $null -eq $result.Data) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $result.ErrorKind; Secrets = @() }
    }
    $secrets = @(@($result.Data.secrets) | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Value = $null; UpdatedAt = $_.updated_at } })
    return [PSCustomObject]@{ Available = $true; ErrorKind = $null; Secrets = $secrets }
}

function Get-EnvironmentVariablesMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$EnvironmentName)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/environments/$EnvironmentName/variables"
    if (-not $result.Success -or $null -eq $result.Data) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $result.ErrorKind; Variables = @() }
    }
    $vars = @(@($result.Data.variables) | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Value = $null; UpdatedAt = $_.updated_at } })
    return [PSCustomObject]@{ Available = $true; ErrorKind = $null; Variables = $vars }
}

function Get-PagesConfig {
    <#
        Enriched for baseline-hygiene orphan evidence (Phase 7). Three
        distinct outcomes, never conflated:
          - Configured=$true  : the /pages GET succeeded -- a real site.
          - Configured=$false : the GET returned 404 (ErrorKind
            'NotFound') -- GitHub's own signal that Pages is not
            configured. This is the only case that means "absent".
          - Available=$false  : the GET failed for any OTHER reason
            (403/5xx/transport) -- configured-vs-absent could NOT be
            determined. Never guessed as either; callers must treat this
            as UNKNOWN, never as evidence of orphan status.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/pages"
    if ($result.Success) {
        return [PSCustomObject]@{
            Available     = $true
            Configured    = $true
            ErrorKind     = $null
            BuildType     = $result.Data.build_type
            SourceBranch  = $result.Data.source.branch
            SourcePath    = $result.Data.source.path
            CustomDomain  = $result.Data.cname
            HttpsEnforced = $result.Data.https_enforced
            IsPublic      = $result.Data.public
            HtmlUrl       = $result.Data.html_url
            Status        = $result.Data.status
        }
    }
    if ($result.ErrorKind -eq 'NotFound') {
        return [PSCustomObject]@{ Available = $true; Configured = $false; ErrorKind = 'NotFound'; BuildType = $null; SourceBranch = $null; SourcePath = $null; CustomDomain = $null; HttpsEnforced = $null; IsPublic = $null; HtmlUrl = $null; Status = $null }
    }
    return [PSCustomObject]@{ Available = $false; Configured = $null; ErrorKind = $result.ErrorKind; BuildType = $null; SourceBranch = $null; SourcePath = $null; CustomDomain = $null; HttpsEnforced = $null; IsPublic = $null; HtmlUrl = $null; Status = $null }
}

function Get-PagesBuilds {
    <# Deployment/build history for a configured Pages site -- distinguishes "never built" from "built, but long ago" from "recently built". #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/pages/builds?per_page=100"
    if (-not $result.Success -or $null -eq $result.Data) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $result.ErrorKind; BuildCount = 0; MostRecentCreatedAt = $null; MostRecentStatus = $null }
    }
    $builds = @($result.Data)
    $mostRecent = if ($builds.Count -gt 0) { $builds[0] } else { $null }
    return [PSCustomObject]@{
        Available           = $true
        ErrorKind           = $null
        BuildCount          = $builds.Count
        MostRecentCreatedAt = if ($mostRecent) { $mostRecent.created_at } else { $null }
        MostRecentStatus    = if ($mostRecent) { $mostRecent.status } else { $null }
    }
}

function Test-PagesLiveUrl {
    <#
        Direct HTTP probe of a Pages site's own html_url. This is the
        ONLY function in this module that reaches an arbitrary external
        host rather than the GitHub API -- always a HEAD, never any
        state-changing verb, and only ever called with a URL GitHub
        itself reported for this repository's own Pages configuration.
        Never throws: a network failure, timeout, or non-2xx/3xx response
        is reported as data (Reachable=$false / $null), never as a
        crashing exception -- this is one orphan-evidence input among
        several, not something allowed to abort the whole assessment.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [PSCustomObject]@{ Available = $false; Reachable = $null; StatusCode = $null; Detail = 'no URL to probe' }
    }
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 15 -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
        $code = [int]$response.StatusCode
        return [PSCustomObject]@{ Available = $true; Reachable = ($code -ge 200 -and $code -lt 400); StatusCode = $code; Detail = "HTTP $code" }
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp -and $resp.StatusCode) {
            $code = [int]$resp.StatusCode
            return [PSCustomObject]@{ Available = $true; Reachable = ($code -ge 200 -and $code -lt 400); StatusCode = $code; Detail = "HTTP $code" }
        }
        return [PSCustomObject]@{ Available = $false; Reachable = $null; StatusCode = $null; Detail = "$($_.Exception.Message)" }
    }
}

function Get-PackageJsonInfo {
    <#
        BUG FIX (found during a real PRODUCTION migration, 2026-08-23):
        this used to read package.json via an IMPLICIT-default-branch
        Get-WorkflowFileText call FIRST, and only fell back to its own
        -Ref parameter if that first read failed -- meaning -Ref was
        silently ignored whenever package.json existed on GitHub's actual
        default branch, which is nearly always. For a repository whose
        default branch is stale (still 'develop' while real development,
        with a materially different package.json, has moved to 'main'),
        this returned completely wrong data -- confirmed live: a repo
        whose main branch had semantic-release fully configured and
        version 0.10.0 was reported as having no semantic-release setup
        and version 0.1.0, because this function silently read from
        develop regardless of the -Ref its caller passed. Now always
        honors its own explicit, mandatory -Ref.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Ref)

    $text = Get-WorkflowFileText -Owner $Owner -Repo $Repo -Path "package.json" -Ref $Ref
    if ($null -eq $text) { return $null }
    try { return $text | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Get-ReleaseConfigText {
    <#
        Same -Ref discipline as Get-PackageJsonInfo above, for the same
        reason: a release config file living only on 'main' (the CDA
        target branch) is invisible to this function if it silently reads
        from a stale default branch instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Ref)

    foreach ($candidate in @('.releaserc.json', '.releaserc', 'release.config.js', 'release.config.mjs')) {
        $text = Get-WorkflowFileText -Owner $Owner -Repo $Repo -Path $candidate -Ref $Ref
        if ($null -ne $text) { return [PSCustomObject]@{ File = $candidate; Text = $text } }
    }
    return $null
}

function Get-DependabotConfigText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    return Get-WorkflowFileText -Owner $Owner -Repo $Repo -Path ".github/dependabot.yml"
}

function Get-DocFileSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $files = [ordered]@{
        'CONTRIBUTING.md'                  = $null
        'SECURITY.md'                      = $null
        'CODEOWNERS'                       = $null
        '.github/CODEOWNERS'               = $null
        '.github/pull_request_template.md' = $null
        'PULL_REQUEST_TEMPLATE.md'         = $null
    }
    $present = [ordered]@{}
    $developReferences = @()
    $pagesReferences = @()
    foreach ($path in $files.Keys) {
        $text = Get-WorkflowFileText -Owner $Owner -Repo $Repo -Path $path
        if ($null -ne $text) {
            $present[$path] = $true
            if ($text -match '\bdevelop\b') { $developReferences += $path }
            if ($text -match '(?i)\bgithub\s*pages\b|\bgh-pages\b') { $pagesReferences += $path }
        }
    }
    return [PSCustomObject]@{ Present = $present.Keys; DevelopReferences = $developReferences; PagesReferences = $pagesReferences }
}

function Get-NpmRegistryVersion {
    <#
        Read-only shell-out to the public npm registry, not GitHub. $null
        if the package doesn't exist or `npm` isn't available -- never
        throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$PackageName)

    if (-not $PackageName) { return $null }
    try {
        $out = & npm view $PackageName version 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return "$out".Trim() }
        return $null
    }
    catch {
        return $null
    }
}

Export-ModuleMember -Function `
    Get-AllBranches, Get-BranchComparison, Get-BranchRetirementEvidence, Test-CommitReachableFromRef, Test-BranchRetirementSemantics, Get-TagsAndReleases, `
    Get-OpenPullRequestsByBase, Get-FileSha, Get-WorkflowFileText, Get-WorkflowsInventory, Get-RecentWorkflowRuns, Get-CheckRunsForRef, `
    Get-SecretsMetadata, Get-VariablesMetadata, Get-EnvironmentsMetadata, Get-EnvironmentDetail, Get-EnvironmentDeployments, Get-EnvironmentSecretsMetadata, Get-EnvironmentVariablesMetadata, `
    Get-PagesConfig, Get-PagesBuilds, Test-PagesLiveUrl, `
    Get-PackageJsonInfo, Get-ReleaseConfigText, Get-DependabotConfigText, Get-DocFileSnapshot, `
    Get-NpmRegistryVersion
