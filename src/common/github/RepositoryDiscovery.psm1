#Requires -Version 5.1
<#
    RepositoryDiscovery.psm1

    Read-only GitHub-side state SNAPSHOTS shared by both lifecycle paths --
    every function here is a GET (via ReadOnlyGitHub.psm1) or a pure
    transform of already-fetched data, never a mutation and never a
    decision about whether something is compliant. Provisioner and adopter
    each classify/compare these snapshots differently (see
    src/provisioner/lib/Orchestration.psm1's PlanItem model vs
    src/adopter/lib/Classification.psm1's 8-value taxonomy) -- that
    decision logic is deliberately NOT here, and never will be: this module
    stays a pure discovery layer so it can be shared without coupling the
    two lifecycle paths' differing philosophies together.

    This is genuinely deduplicated code: before this project, the
    provisioner and adopter each independently implemented near-identical
    reads of repos/{owner}/{repo}, .../languages, .../rulesets,
    .../actions/permissions*, .../vulnerability-alerts, and
    .../code-scanning/default-setup.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReadOnlyGitHub.psm1') -Force

function Get-RepositoryOverview {
    <#
        Pure transform (no network call) of an already-fetched
        repos/{owner}/{repo} response into a stable, strict-mode-safe
        shape. `security_and_analysis` is entirely ABSENT (not merely
        null) from the API response for at least one real repository
        confirmed empirically while building the source tooling this
        module formalizes -- dotting straight into a missing property
        throws under Set-StrictMode, so every read here goes through
        .PSObject.Properties first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $RepoData)

    $sa = $null
    if ($null -ne $RepoData.PSObject.Properties['security_and_analysis']) {
        $sa = $RepoData.security_and_analysis
    }
    $secretScanning = $null
    $secretScanningPush = $null
    $dependabotSecUpdates = $null
    if ($null -ne $sa) {
        if ($null -ne $sa.PSObject.Properties['secret_scanning']) { $secretScanning = $sa.secret_scanning.status }
        if ($null -ne $sa.PSObject.Properties['secret_scanning_push_protection']) { $secretScanningPush = $sa.secret_scanning_push_protection.status }
        if ($null -ne $sa.PSObject.Properties['dependabot_security_updates']) { $dependabotSecUpdates = $sa.dependabot_security_updates.status }
    }

    return [PSCustomObject]@{
        Visibility           = $RepoData.visibility
        DefaultBranch        = $RepoData.default_branch
        AllowSquashMerge     = [bool]$RepoData.allow_squash_merge
        AllowMergeCommit     = [bool]$RepoData.allow_merge_commit
        AllowRebaseMerge     = [bool]$RepoData.allow_rebase_merge
        AllowAutoMerge       = [bool]$RepoData.allow_auto_merge
        DeleteBranchOnMerge  = [bool]$RepoData.delete_branch_on_merge
        SecretScanning       = $secretScanning
        SecretScanningPush   = $secretScanningPush
        DependabotSecUpdates = $dependabotSecUpdates
        IsTemplate           = [bool]$RepoData.is_template
        HasPages             = [bool]$RepoData.has_pages
    }
}

function Get-RepositoryLanguages {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/languages"
    if (-not $result.Success -or $null -eq $result.Data) { return @() }
    # A brand-new repository (or one GitHub hasn't finished analyzing yet)
    # returns a bare `{}` body. Chaining straight to
    # .PSObject.Properties.Name on a zero-property PSCustomObject throws
    # under Set-StrictMode -- confirmed empirically, not assumed -- so the
    # property collection is materialized and counted first.
    $props = @($result.Data.PSObject.Properties)
    if ($props.Count -eq 0) { return @() }
    return @($props | ForEach-Object { $_.Name })
}

function Get-ActionsPermissionsState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $perm = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions"
    $wf = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions/workflow"

    $selected = $null
    if ($perm.Success -and $perm.Data.allowed_actions -eq 'selected') {
        $selResult = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/actions/permissions/selected-actions"
        if ($selResult.Success) { $selected = $selResult.Data }
    }

    return [PSCustomObject]@{
        Available            = $perm.Success
        Enabled              = if ($perm.Success) { [bool]$perm.Data.enabled } else { $null }
        AllowedActionsPolicy = if ($perm.Success) { $perm.Data.allowed_actions } else { $null }
        ShaPinningAvailable  = ($perm.Success -and $null -ne $perm.Data.PSObject.Properties['sha_pinning_required'])
        ShaPinningRequired   = if ($perm.Success -and $null -ne $perm.Data.PSObject.Properties['sha_pinning_required']) { [bool]$perm.Data.sha_pinning_required } else { $null }
        DefaultWorkflowPerms = if ($wf.Success) { $wf.Data.default_workflow_permissions } else { $null }
        CanApprovePrReviews  = if ($wf.Success) { [bool]$wf.Data.can_approve_pull_request_reviews } else { $null }
        SelectedActions      = $selected
    }
}

function Get-VulnerabilityAlertsState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/vulnerability-alerts"
    # 204 = enabled, 404 = disabled -- both are conclusive reads, not errors.
    $applicable = ($result.Success -or $result.ErrorKind -eq 'NotFound')
    return [PSCustomObject]@{ Applicable = $applicable; Enabled = $result.Success }
}

function Get-CodeQLState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $default = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/code-scanning/default-setup"
    $alerts = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/code-scanning/alerts"

    return [PSCustomObject]@{
        DefaultSetupAvailable = $default.Success
        DefaultSetupState     = if ($default.Success) { $default.Data.state } else { $null }
        AnyAnalysisFound      = ($alerts.Success -or $alerts.ErrorKind -eq 'NotFound') # NotFound here often means "no analysis", not "feature absent"
        AlertsErrorKind       = $alerts.ErrorKind
    }
}

function Get-AllRulesets {
    <#
        Lists every ruleset and fetches full detail for each. Deliberately
        general (unlike a "find the one ruleset named X" helper) -- both
        lifecycle paths need to know about a ruleset that ISN'T the one
        they're looking for (a differently-named or duplicate "Protect
        main" ruleset must never be silently ignored or guessed at; see
        docs/safety-model.md).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo)

    $list = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/rulesets"
    if (-not $list.Success) {
        return [PSCustomObject]@{ Available = $false; ErrorKind = $list.ErrorKind; Rulesets = @() }
    }
    $summaries = @($list.Data)
    $details = @()
    foreach ($s in $summaries) {
        $d = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo/rulesets/$($s.id)"
        if ($d.Success) { $details += $d.Data }
        else { $details += [PSCustomObject]@{ id = $s.id; name = $s.name; FetchFailed = $true; ErrorKind = $d.ErrorKind } }
    }
    return [PSCustomObject]@{ Available = $true; ErrorKind = $null; Rulesets = $details }
}

Export-ModuleMember -Function `
    Get-RepositoryOverview, Get-RepositoryLanguages, Get-ActionsPermissionsState, `
    Get-VulnerabilityAlertsState, Get-CodeQLState, Get-AllRulesets
