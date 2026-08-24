#Requires -Version 5.1
<#
    MergeReproducibility.psm1

    Distinguishes "this merge commit's tree has never existed as a commit
    tree on the target branch" (a GRAPH/HISTORY fact) from "this merge
    commit contains content nobody else can reach" (a CONTENT fact). A
    merge commit's tree is very often a NEW tree -- 3-way-merging two
    already-reachable trees mechanically produces a third, distinct tree
    SHA -- without introducing a single byte of content that isn't
    already fully explained by its two parents.

    This module answers that question the only way it can be answered
    honestly: by literally asking Git to redo the merge (read-only, via
    `git merge-tree --write-tree`, which computes and writes a candidate
    tree object without touching the working directory, the index, or
    any ref -- see `git help merge-tree`) and comparing the result,
    byte-for-byte via tree SHA, against what was actually recorded.

    SAFETY / SCOPE, read this before changing anything here:
    - This is the ONLY module in repository-adopter that shells out to a
      real `git` process against a local, read-only MIRROR clone of the
      target repository. It NEVER runs `git push`, `git commit` on any
      branch, or any command that could reach back out to GitHub and
      change something there. The mirror exists purely so the two
      parent commits' objects are available locally for `git merge-tree`
      to read.
    - The mirror is fetched via `gh repo clone` / `git fetch` only (both
      read-only with respect to the remote) into a dedicated cache
      directory, reused across calls, never written back to origin.
    - `git merge-tree --write-tree` itself is documented upstream as
      side-effect-free for the working tree/index -- it can still write
      loose objects into the mirror's OWN local `.git/objects` (a normal,
      harmless consequence of asking Git to compute something), which is
      never pushed anywhere.
    - Every result that isn't a clean, unambiguous exact-match or
      exact-mismatch is reported as UNKNOWN, never guessed as either
      "reproducible" or "not reproducible" (brief section 4).
#>

Set-StrictMode -Version Latest

function Invoke-NativeCommandSafely {
    <#
        Same EAP dance used throughout this tool's other native-process
        callers (ReadOnlyGitHub.psm1, MutationGitHub.psm1): under
        $ErrorActionPreference = 'Stop' (as run-tests.ps1 and every entry
        script set globally), any stderr line from a native command --
        including `git`'s routine, EXPECTED "fatal: ..." on a plain
        nonzero exit (e.g. probing whether an object exists) -- becomes a
        terminating NativeCommandError instead of just being text this
        function wants to inspect itself. Force 'Continue' for the
        duration of this one native call so a nonzero exit is just data,
        never an exception.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [scriptblock]$ScriptBlock)
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return & $ScriptBlock }
    finally { $ErrorActionPreference = $previousEap }
}

function Get-InstalledGitVersion {
    [CmdletBinding()]
    param()
    try {
        $out = Invoke-NativeCommandSafely { & git --version 2>&1 }
        if ($LASTEXITCODE -eq 0 -and $out) { return "$out".Trim() }
        return $null
    }
    catch { return $null }
}

function Initialize-LocalRepoMirror {
    <#
        Ensures a read-only local mirror of $Owner/$Repo exists under
        $CacheRoot, fetching it fresh via `gh repo clone` if absent, or
        updating it via `git fetch --all` (read-only) if already present.
        Returns the local path, or $null if it could not be established
        (network/auth failure, etc. -- caller must treat that as UNKNOWN,
        never as proof of anything).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Owner, [Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$CacheRoot)

    $repoPath = Join-Path $CacheRoot "$Owner-$Repo-readonly-mirror"
    if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) {
        if (-not (Test-Path -LiteralPath $CacheRoot)) { New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null }
        if (Test-Path -LiteralPath $repoPath) { Remove-Item -LiteralPath $repoPath -Recurse -Force -ErrorAction SilentlyContinue }
        $prevDir = Get-Location
        try {
            Set-Location -LiteralPath $CacheRoot
            Invoke-NativeCommandSafely { & gh repo clone "$Owner/$Repo" "$Owner-$Repo-readonly-mirror" 2>&1 } | Out-Null
            $cloneExit = $LASTEXITCODE
        }
        finally { Set-Location -LiteralPath $prevDir }
        if ($cloneExit -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) { return $null }
    }
    else {
        Invoke-NativeCommandSafely { & git -C $repoPath fetch --all --quiet 2>&1 } | Out-Null
        # A stale/broken fetch is not fatal here -- objects already
        # present locally (e.g. from a previous successful fetch) may
        # still be sufficient. Only a completely missing mirror is fatal.
    }
    return $repoPath
}

function Test-GitMergeReproducible {
    <#
        Runs `git merge-tree --write-tree --no-messages <Parent1Sha>
        <Parent2Sha>` in the given local mirror and compares the
        resulting tree SHA against $RecordedTreeSha. Read-only: writes at
        most a loose tree object into the mirror's own local object
        database, never touches the working directory/index, never
        pushes anywhere.

        Returns Reproducible = $true (exact match, clean merge) / $false
        (ran cleanly but produced a DIFFERENT tree, or Git itself
        reported a conflict -- either way, real evidence something
        beyond a mechanical combination of the parents happened) / $null
        UNKNOWN (the command could not be run at all -- objects missing,
        git error unrelated to the merge itself). $null is never treated
        as $false by any caller.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$RepoPath, [Parameter(Mandatory)] [string]$Parent1Sha, [Parameter(Mandatory)] [string]$Parent2Sha, [Parameter(Mandatory)] [string]$RecordedTreeSha)

    # Confirm both parent objects are actually present locally before
    # attempting the merge -- a missing object must be UNKNOWN, not a
    # false "conflict".
    Invoke-NativeCommandSafely { & git -C $RepoPath cat-file -e "$Parent1Sha^{commit}" 2>&1 } | Out-Null
    $p1Present = ($LASTEXITCODE -eq 0)
    Invoke-NativeCommandSafely { & git -C $RepoPath cat-file -e "$Parent2Sha^{commit}" 2>&1 } | Out-Null
    $p2Present = ($LASTEXITCODE -eq 0)
    if (-not $p1Present -or -not $p2Present) {
        return [PSCustomObject]@{ Reproducible = $null; ReproducedTreeSha = $null; ExitCode = $null; ConflictDetected = $null; Detail = 'one or both parent commit objects are not present in the local mirror' }
    }

    $rawOutput = Invoke-NativeCommandSafely { & git -C $RepoPath merge-tree --write-tree --no-messages $Parent1Sha $Parent2Sha 2>&1 }
    $exitCode = $LASTEXITCODE

    # On a clean merge (exit 0), stdout is exactly the resulting tree
    # OID (one line). On a conflicted merge (exit 1), Git still exits
    # non-fatally and (without --no-messages this would print conflict
    # markers/paths; with --no-messages, the first output line is still
    # the OID of a tree that DOES contain conflict markers baked into
    # file content) -- so exit code, not output shape, is what
    # distinguishes "clean" from "had to invent a resolution".
    $rawLines = @($rawOutput | ForEach-Object { "$_" })
    $reproducedTreeSha = if ($rawLines.Count -gt 0) { $rawLines[0].Trim() } else { $null }

    if ($exitCode -gt 1 -or -not $reproducedTreeSha -or $reproducedTreeSha.Length -ne 40) {
        # Anything other than a clean (0) or conflicted-but-completed (1)
        # exit, or output that doesn't even look like a tree SHA, is an
        # environment/tooling failure -- UNKNOWN, not evidence.
        return [PSCustomObject]@{ Reproducible = $null; ReproducedTreeSha = $null; ExitCode = $exitCode; ConflictDetected = $null; Detail = "git merge-tree did not produce a usable result (exit=$exitCode)" }
    }

    if ($exitCode -eq 1) {
        # Git itself could not auto-merge cleanly -- strong evidence the
        # ORIGINAL merge commit required manual conflict resolution, i.e.
        # real authored content. Still reported as a concrete, explained
        # $false rather than folded into the same bucket as environment
        # failures.
        return [PSCustomObject]@{ Reproducible = $false; ReproducedTreeSha = $reproducedTreeSha; ExitCode = $exitCode; ConflictDetected = $true; Detail = 'git merge-tree reported a conflict reproducing this merge -- the original merge likely required manual resolution' }
    }

    $exactMatch = ($reproducedTreeSha -eq $RecordedTreeSha)
    return [PSCustomObject]@{
        Reproducible      = $exactMatch
        ReproducedTreeSha = $reproducedTreeSha
        ExitCode          = $exitCode
        ConflictDetected  = $false
        Detail            = if ($exactMatch) { 'clean merge, tree matches exactly' } else { 'clean merge, but resulting tree differs from the recorded merge commit -- something beyond a mechanical combination of the parents was applied' }
    }
}

function Get-MergeIntroducedBlobPaths {
    <#
        Lightweight supporting evidence (brief section 5), used only to
        help EXPLAIN a reproduction mismatch, never to auto-decide
        anything on its own. For each path that differs between the
        recorded merge tree and EACH parent, reports whether the
        resulting blob at that path exists (by content SHA) in at least
        one parent's tree at any path. A blob absent from both parents
        entirely is flagged as merge-introduced (its bytes exist nowhere
        else in the two histories being combined).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$RepoPath, [Parameter(Mandatory)] [string]$RecordedTreeSha, [Parameter(Mandatory)] [string]$Parent1Sha, [Parameter(Mandatory)] [string]$Parent2Sha)

    $recordedBlobs = @(Invoke-NativeCommandSafely { & git -C $RepoPath ls-tree -r $RecordedTreeSha 2>&1 } | ForEach-Object {
            $parts = "$_" -split '\s+', 4
            if ($parts.Count -eq 4) { [PSCustomObject]@{ Path = $parts[3]; BlobSha = $parts[2] } }
        })
    if ($LASTEXITCODE -ne 0 -or $recordedBlobs.Count -eq 0) { return [PSCustomObject]@{ Available = $false; MergeIntroducedPaths = @() } }

    $parentBlobShas = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in @($Parent1Sha, $Parent2Sha)) {
        $lines = Invoke-NativeCommandSafely { & git -C $RepoPath ls-tree -r $p 2>&1 }
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $lines) {
                $parts = "$line" -split '\s+', 4
                if ($parts.Count -eq 4) { [void]$parentBlobShas.Add($parts[2]) }
            }
        }
    }

    $introduced = @($recordedBlobs | Where-Object { -not $parentBlobShas.Contains($_.BlobSha) } | ForEach-Object { $_.Path })
    return [PSCustomObject]@{ Available = $true; MergeIntroducedPaths = $introduced }
}

Export-ModuleMember -Function Get-InstalledGitVersion, Initialize-LocalRepoMirror, Test-GitMergeReproducible, Get-MergeIntroducedBlobPaths
