#Requires -Version 5.1
<#
    Validation.psm1

    Repository identity/eligibility checks shared by both lifecycle paths.
    This is real, previously-duplicated logic: the provisioner and adopter
    tools this project formalizes each carried their own byte-for-byte-
    identical "owner/name" format check, and near-identical eligibility
    checks that differed only in how they treat forks (the provisioner
    refuses a fork outright unless -AllowFork; the adopter always allows
    one through but reports IsFork prominently, since assessing a fork is
    harmless and sometimes useful, while mutating one by accident is not).
    That one real difference is preserved as an explicit switch rather than
    forcing one behavior on both callers.

    Test-RepositoryEligibility imports ReadOnlyGitHub.psm1 -- one read-only
    GET to confirm the repository exists, is not archived, and (unless
    -RejectForks is absent) report whether it is a fork.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\github\ReadOnlyGitHub.psm1') -Force

function Test-RepositoryNameFormat {
    <# Pure function: validates "owner/name" shape. No network call. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Repository)

    if ($Repository -notmatch '^(?<owner>[A-Za-z0-9][A-Za-z0-9-]*)/(?<repo>[A-Za-z0-9._-]+)$') {
        return [PSCustomObject]@{ Valid = $false; Owner = $null; Repo = $null; Reason = "Repository must be in 'owner/name' form, got: '$Repository'" }
    }
    $m = [regex]::Match($Repository, '^(?<owner>[A-Za-z0-9][A-Za-z0-9-]*)/(?<repo>[A-Za-z0-9._-]+)$')
    return [PSCustomObject]@{ Valid = $true; Owner = $m.Groups['owner'].Value; Repo = $m.Groups['repo'].Value; Reason = $null }
}

function Test-ForkPolicy {
    <#
        Pure function, no network call: the one fork-handling decision
        Test-RepositoryEligibility applies once it already knows a
        repository is a fork. Extracted on its own specifically so it is
        directly unit-testable without mocking Invoke-ReadOnlyGitHub --
        Validation.psm1 nest-imports ReadOnlyGitHub.psm1 itself, which
        (per this codebase's own established, repeatedly-confirmed
        PowerShell 5.1 behavior) means a global-scope test override of
        Invoke-ReadOnlyGitHub cannot reach Test-RepositoryEligibility's
        internal call to it -- the same reason
        src/adopter/lib/Discovery.psm1's Get-BranchRetirementEvidence was
        split into an I/O wrapper plus a pure Test-BranchRetirementSemantics.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [bool]$IsFork, [switch]$RejectForks, [switch]$AllowFork)

    if ($RejectForks -and $IsFork -and -not $AllowFork) {
        return [PSCustomObject]@{ Eligible = $false; Reason = 'Repository is a fork. Pass -AllowFork to override explicitly.' }
    }
    return [PSCustomObject]@{ Eligible = $true; Reason = $null }
}

function Test-RepositoryEligibility {
    <#
        Network call (one GET). Rejects anything outside -RequiredOrg and
        any archived repository unconditionally. Fork handling is the one
        place provisioning and adoption legitimately differ -- see
        Test-ForkPolicy above for the actual decision:
          -RejectForks (provisioner default via -AllowFork:$false)  ->
             a fork is INELIGIBLE unless the caller explicitly overrides.
          without -RejectForks (adopter's default)  ->
             a fork is eligible; IsFork is threaded through so callers can
             report it prominently instead of silently treating it like
             any other repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Owner,
        [Parameter(Mandatory)] [string]$Repo,
        [string]$RequiredOrg = 'Continuous-DrivenArchitecture',
        [switch]$RejectForks,
        [switch]$AllowFork
    )

    if ($Owner -ne $RequiredOrg) {
        return [PSCustomObject]@{ Eligible = $false; Reason = "Owner '$Owner' is not '$RequiredOrg'. This tool refuses to act outside that organization."; RepoData = $null; IsFork = $false }
    }

    $result = Invoke-ReadOnlyGitHub -Path "repos/$Owner/$Repo"
    if (-not $result.Success) {
        $reason = switch ($result.ErrorKind) {
            'NotFound' { "Repository '$Owner/$Repo' does not exist (or is not visible to the authenticated account)." }
            'Forbidden' { "Access to '$Owner/$Repo' was denied (HTTP 403)." }
            default { "Could not read '$Owner/$Repo' (HTTP $($result.StatusCode))." }
        }
        return [PSCustomObject]@{ Eligible = $false; Reason = $reason; RepoData = $null; IsFork = $false }
    }

    $repoData = $result.Data
    if ($repoData.archived) {
        return [PSCustomObject]@{ Eligible = $false; Reason = "Repository '$Owner/$Repo' is archived."; RepoData = $repoData; IsFork = [bool]$repoData.fork }
    }

    $isFork = [bool]$repoData.fork
    $forkPolicy = Test-ForkPolicy -IsFork $isFork -RejectForks:$RejectForks -AllowFork:$AllowFork
    if (-not $forkPolicy.Eligible) {
        return [PSCustomObject]@{ Eligible = $false; Reason = ("Repository '$Owner/$Repo' is a fork. Pass -AllowFork to override explicitly."); RepoData = $repoData; IsFork = $isFork }
    }

    return [PSCustomObject]@{ Eligible = $true; Reason = $null; RepoData = $repoData; IsFork = $isFork }
}

Export-ModuleMember -Function Test-RepositoryNameFormat, Test-ForkPolicy, Test-RepositoryEligibility
