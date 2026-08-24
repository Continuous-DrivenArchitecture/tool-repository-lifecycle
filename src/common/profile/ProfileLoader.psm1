#Requires -Version 5.1
<#
    ProfileLoader.psm1

    Single, shared way to load a CDA repository profile JSON file (see
    profiles/npm-library.json, profiles/repository-baseline.json, and
    docs/profiles.md). Both the provisioner and adopter commands
    previously duplicated the same three-line "resolve default path ->
    Test-Path -> Get-Content -Raw | ConvertFrom-Json" block; this is that
    block, once, with one consistent error shape.

    Also implements profile COMPOSITION: a profile's `extends` field may
    name another profile file (by base filename, no extension) in the
    same directory, whose fields are inherited as defaults. This is what
    lets profiles/npm-library.json stay a small overlay (just its own
    genuinely npm/JS-specific additions) on top of
    profiles/repository-baseline.json (the executable projection of CDA
    Repository Baseline v1 alone) instead of duplicating the whole
    baseline inline -- see docs/profiles.md, "Baseline vs profile".

    Performs no validation beyond "is this well-formed JSON" -- schema
    validation against schemas/repository-profile.schema.json is a
    separate, explicit step (see tests/run-tests.ps1, "Schema validation",
    and docs/artifact-model.md).
#>

Set-StrictMode -Version Latest

function Get-CdaProfile {
    <#
        .OUTPUTS
        PSCustomObject with Success, Profile (parsed JSON or $null),
        SourcePath (resolved absolute path), Error (string or $null).

        Loads exactly the ONE named file -- does not resolve `extends`.
        Use Get-EffectiveCdaProfile for the composed, effective profile a
        provisioner/adopter command should actually converge toward.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Success = $false; Profile = $null; SourcePath = $Path; Error = "Profile not found: $Path" }
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    try {
        $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Profile = $null; SourcePath = $resolved; Error = "Failed to parse profile '$Path': $($_.Exception.Message)" }
    }

    return [PSCustomObject]@{ Success = $true; Profile = $parsed; SourcePath = $resolved; Error = $null }
}

function Merge-CdaProfileObject {
    <#
        Pure function, no file I/O: recursively merges $Child onto $Base.
        For each property on $Base not present on $Child, the base value
        is kept. For each property present on BOTH as a PSCustomObject,
        the merge recurses (so a child overlay can override e.g. just
        security.codeQLDefaultSetup without restating the whole
        `security` object). Any other property present on $Child
        (scalar, array, or a type mismatch with $Base) is taken from
        $Child WHOLESALE -- arrays are never merged element-wise, since
        that would make "the child clears a list back to empty" and "the
        child forgot to specify it" indistinguishable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Base, [Parameter(Mandatory)] $Child)

    $result = [ordered]@{}
    foreach ($prop in $Base.PSObject.Properties) {
        $result[$prop.Name] = $prop.Value
    }
    foreach ($prop in $Child.PSObject.Properties) {
        $baseHasIt = $result.Contains($prop.Name)
        $bothObjects = $baseHasIt -and ($result[$prop.Name] -is [PSCustomObject]) -and ($prop.Value -is [PSCustomObject])
        if ($bothObjects) {
            $result[$prop.Name] = Merge-CdaProfileObject -Base $result[$prop.Name] -Child $prop.Value
        }
        else {
            $result[$prop.Name] = $prop.Value
        }
    }
    return [PSCustomObject]$result
}

function Get-EffectiveCdaProfile {
    <#
        .SYNOPSIS
        Loads $Path and, if its `extends` field names another profile
        file (by base filename, no extension, resolved relative to the
        SAME directory as $Path -- never an arbitrary path, and never the
        old documentation-only style of naming a standard like
        "cda-repository-baseline-v1" that does not resolve to a file),
        recursively loads and merges that base profile underneath it.

        A profile with no `extends`, or whose `extends` value does not
        resolve to a real sibling file, is returned as-is (Extended =
        $false) -- this is not an error: profiles/repository-baseline.json
        itself has no `extends` (it implements the baseline directly, it
        does not extend anything), and this function must never guess or
        silently fail to compose a profile that DOES intend to extend one.

        .OUTPUTS
        PSCustomObject with Success, Profile (the EFFECTIVE, merged
        profile), SourcePath, Extended (bool), BaseProfileName
        (string or $null), Error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    $own = Get-CdaProfile -Path $Path
    if (-not $own.Success) {
        return [PSCustomObject]@{ Success = $false; Profile = $null; SourcePath = $Path; Extended = $false; BaseProfileName = $null; Error = $own.Error }
    }

    $extendsValue = if ($own.Profile.PSObject.Properties['extends']) { "$($own.Profile.extends)" } else { $null }
    if ([string]::IsNullOrEmpty($extendsValue)) {
        return [PSCustomObject]@{ Success = $true; Profile = $own.Profile; SourcePath = $own.SourcePath; Extended = $false; BaseProfileName = $null; Error = $null }
    }

    $ownDir = Split-Path -Parent $own.SourcePath
    $baseCandidatePath = Join-Path $ownDir "$extendsValue.json"
    if (-not (Test-Path -LiteralPath $baseCandidatePath)) {
        # `extends` names something that isn't a resolvable sibling file
        # (e.g. a bare standard name, documentation-only, from before
        # this composition mechanism existed). Never guessed at, never an
        # error -- the profile is returned as-is.
        return [PSCustomObject]@{ Success = $true; Profile = $own.Profile; SourcePath = $own.SourcePath; Extended = $false; BaseProfileName = $null; Error = $null }
    }

    $base = Get-EffectiveCdaProfile -Path $baseCandidatePath
    if (-not $base.Success) {
        return [PSCustomObject]@{ Success = $false; Profile = $null; SourcePath = $own.SourcePath; Extended = $false; BaseProfileName = $extendsValue; Error = "Failed to resolve base profile '$extendsValue' for '$Path': $($base.Error)" }
    }

    $effective = Merge-CdaProfileObject -Base $base.Profile -Child $own.Profile
    return [PSCustomObject]@{ Success = $true; Profile = $effective; SourcePath = $own.SourcePath; Extended = $true; BaseProfileName = $extendsValue; Error = $null }
}

Export-ModuleMember -Function Get-CdaProfile, Merge-CdaProfileObject, Get-EffectiveCdaProfile
