#Requires -Version 5.1
<#
    MutationGitHub.psm1

    The ONLY module in this repository that can send a mutating HTTP
    request to the GitHub API. Every function that calls `gh api` here uses
    POST, PUT, PATCH, or DELETE -- never GET (see ReadOnlyGitHub.psm1 for
    that). This file is deliberately kept small and separate. It must never
    be imported by any assess/discovery code path (see
    docs/safety-model.md, "Read-only/mutation isolation") -- only by
    orchestration code that has already decided a mutation is safe to
    perform (provisioner's Orchestration.psm1, adopter's Apply.psm1), and
    only after any relevant -DryRun / approval gate has already passed.

    Callers are responsible for deciding WHEN it is safe to call
    Invoke-MutationGitHub. Nothing in this module decides that for them.
#>

Set-StrictMode -Version Latest

function Invoke-MutationGitHub {
    <#
        .SYNOPSIS
        Sends one mutating (POST/PUT/PATCH/DELETE) request to the GitHub
        API via `gh api` and returns a structured result. GET is
        deliberately not in -Method's ValidateSet: a caller that only needs
        to read state must use ReadOnlyGitHub.psm1's Invoke-ReadOnlyGitHub
        instead, so every call through this module is visibly, structurally
        a mutation attempt.

        .PARAMETER Path
        API path, e.g. "repos/OWNER/REPO/branches/some-branch".

        .PARAMETER Method
        One of POST, PUT, PATCH, DELETE. Mandatory -- there is no default,
        so a caller cannot forget to say what kind of mutation this is.

        .PARAMETER BodyObject
        Optional hashtable/PSCustomObject serialized to JSON and sent via
        `gh api --input <tempfile>`. Never log or persist this object if it
        may contain a secret value; this module does not inspect its
        contents.

        .OUTPUTS
        PSCustomObject with StatusCode, Success, Data, ErrorKind, RawBody --
        the same shape ReadOnlyGitHub.psm1's Invoke-ReadOnlyGitHub uses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,
        [object]$BodyObject
    )

    $ghArgs = @('api', $Path, '-i', '-X', $Method)

    $tempInputFile = $null
    if ($null -ne $BodyObject) {
        $tempInputFile = [System.IO.Path]::GetTempFileName()
        $jsonText = $BodyObject | ConvertTo-Json -Depth 20
        # UTF-8 without BOM via .NET directly -- Set-Content's -Encoding
        # utf8NoBOM name does not exist on Windows PowerShell 5.1, and a BOM
        # in the payload can trip up strict JSON parsers on the receiving
        # end.
        [System.IO.File]::WriteAllText($tempInputFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
        $ghArgs += @('--input', $tempInputFile)
    }

    # Same EAP dance as ReadOnlyGitHub.psm1: under $ErrorActionPreference =
    # 'Stop', any stderr line from `gh` (including its routine "gh: ...
    # (HTTP nnn)" summary on an ordinary 4xx) becomes a terminating
    # NativeCommandError. Force 'Continue' for the duration of this one
    # native call so gh's stderr is just text we parse, not an exception.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & gh @ghArgs 2>&1 | Out-String
    }
    finally {
        $ErrorActionPreference = $previousEap
        if ($tempInputFile -and (Test-Path -LiteralPath $tempInputFile)) {
            Remove-Item -LiteralPath $tempInputFile -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $raw -or $raw.Trim().Length -eq 0) {
        return [PSCustomObject]@{ StatusCode = 0; Success = $false; Data = $null; ErrorKind = 'TransportError'; RawBody = '' }
    }

    $statusMatch = [regex]::Match($raw, '^HTTP\S*\s+(\d{3})', 'Multiline')
    if (-not $statusMatch.Success) {
        return [PSCustomObject]@{ StatusCode = 0; Success = $false; Data = $null; ErrorKind = 'TransportError'; RawBody = $raw.Trim() }
    }
    $statusCode = [int]$statusMatch.Groups[1].Value

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

Export-ModuleMember -Function Invoke-MutationGitHub
