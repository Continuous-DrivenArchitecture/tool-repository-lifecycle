#Requires -Version 5.1
<#
    ReadOnlyGitHub.psm1

    The ONLY module in this repository allowed to talk to the GitHub API
    with a GET verb, and the ONLY shape of GitHub call any assessment /
    discovery code path may ever import. There is no -Method parameter
    anywhere in this file, no way to pass -X PATCH/PUT/POST/DELETE, and no
    function that accepts a request body. This is deliberate and is this
    project's core safety property (see docs/safety-model.md,
    "Read-only/mutation isolation") -- it must be obvious from the code
    structure alone, not just from the fact that nothing currently calls a
    mutating endpoint.

    src/common/github/MutationGitHub.psm1 is the ONLY module that can
    mutate. Code used to build an assessment (src/common/, src/adopter/lib/
    Discovery.psm1, Classification.psm1, Comparison.psm1, and
    commands/assess-npm-library.ps1 itself) must never import
    MutationGitHub.psm1 -- tests/run-tests.ps1 verifies this structurally
    (source-text scan), not just by convention.

    This module is shared by both lifecycle paths (NEW repository
    provisioning and EXISTING repository adoption) -- see
    docs/architecture.md. It carries no provisioner- or adopter-specific
    behavior of its own.
#>

Set-StrictMode -Version Latest

function Test-GhAuthenticated {
    <#
        Returns $true only if `gh auth status` succeeds. Does not throw --
        callers decide how to react (every command in this repository
        treats it as a hard prerequisite failure, exit code 2).
    #>
    [CmdletBinding()]
    param()

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & gh auth status *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previousEap
    }
}

function Invoke-ReadOnlyGitHub {
    <#
        .SYNOPSIS
        GET-only call to the GitHub API via `gh api`. Always classifies the
        real HTTP status code (via `-i`/--include) rather than guessing
        from exit codes or stderr text.

        .PARAMETER Path
        API path, e.g. "repos/OWNER/REPO". May include a query string.

        .OUTPUTS
        PSCustomObject with StatusCode, Success, Data, ErrorKind, RawBody:
          StatusCode  [int]    real HTTP status, 0 if the request never
                               reached the network (gh itself failed).
          Success     [bool]   200 <= StatusCode < 300
          Data        object   parsed JSON body, or $null if empty/unparseable
          ErrorKind   string   $null on success, else one of:
                               NotFound, Forbidden, Unprocessable,
                               ClientError, ServerError, TransportError
          RawBody     string   raw response body, for diagnostics
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    # Hardcoded, literal "GET" -- not a variable, not a parameter, not
    # derived from $Path. There is no code path in this module that can
    # turn this into anything else. tests/run-tests.ps1's read-only
    # boundary check asserts this literal string is the ONLY -X value this
    # file ever constructs.
    $ghArgs = @('api', $Path, '-i', '-X', 'GET')

    # `gh` writes its error summary ("gh: <message> (HTTP nnn)") to stderr
    # even for a routine, already-classified 4xx response. Under a caller's
    # $ErrorActionPreference = 'Stop', PowerShell turns EVERY stderr line
    # from a native command captured via 2>&1 into a terminating
    # NativeCommandError -- regardless of gh's actual exit code. Force
    # 'Continue' for the duration of this one native call so gh's stderr is
    # just text we parse, not an exception.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & gh @ghArgs 2>&1 | Out-String
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if (-not $raw -or $raw.Trim().Length -eq 0) {
        return [PSCustomObject]@{ StatusCode = 0; Success = $false; Data = $null; ErrorKind = 'TransportError'; RawBody = '' }
    }

    $statusMatch = [regex]::Match($raw, '^HTTP\S*\s+(\d{3})', 'Multiline')
    if (-not $statusMatch.Success) {
        return [PSCustomObject]@{ StatusCode = 0; Success = $false; Data = $null; ErrorKind = 'TransportError'; RawBody = $raw.Trim() }
    }
    $statusCode = [int]$statusMatch.Groups[1].Value

    # Body is everything after the first blank line following the header
    # block. `gh api -i` prints headers, a blank line, then the body.
    $lines = $raw -split "`r?`n"
    $blankIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim().Length -eq 0) { $blankIndex = $i; break }
    }
    $bodyText = if ($blankIndex -ge 0 -and $blankIndex + 1 -lt $lines.Count) {
        ($lines[($blankIndex + 1)..($lines.Count - 1)]) -join "`n"
    }
    else { '' }

    $data = $null
    if ($bodyText.Trim().Length -gt 0) {
        try { $data = $bodyText | ConvertFrom-Json -ErrorAction Stop } catch { $data = $null }
    }

    $success = ($statusCode -ge 200 -and $statusCode -lt 300)
    $errorKind = $null
    if (-not $success) {
        $errorKind = switch ($statusCode) {
            404 { 'NotFound' }
            403 { 'Forbidden' }
            422 { 'Unprocessable' }
            default {
                if ($statusCode -ge 500) { 'ServerError' } else { 'ClientError' }
            }
        }
    }

    return [PSCustomObject]@{ StatusCode = $statusCode; Success = $success; Data = $data; ErrorKind = $errorKind; RawBody = $bodyText }
}

function Get-ReadOnlyGitHubPaged {
    <#
        Follows a simple ?page= pagination loop for GET endpoints that
        return a top-level JSON array. Stops at the first empty page, the
        first short (less-than-a-full-page) page, or the first non-success
        response. Returns an array (possibly empty) -- never throws for a
        404.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [int]$PerPage = 100,
        [int]$MaxPages = 10
    )

    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $all = @()
    for ($page = 1; $page -le $MaxPages; $page++) {
        $result = Invoke-ReadOnlyGitHub -Path "$Path${separator}per_page=$PerPage&page=$page"
        if (-not $result.Success -or $null -eq $result.Data) { break }
        $items = @($result.Data)
        if ($items.Count -eq 0) { break }
        $all += $items
        if ($items.Count -lt $PerPage) { break }
    }
    return $all
}

Export-ModuleMember -Function Test-GhAuthenticated, Invoke-ReadOnlyGitHub, Get-ReadOnlyGitHubPaged
