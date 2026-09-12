param(
    [string]$Manifest = (Join-Path $PSScriptRoot '..\manifest.json'),
    [string]$Repository = 'plakezz/SkySlop-Media'
)

$ErrorActionPreference = 'Stop'
$index = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($index.schemaVersion -ne 1 -or $index.revision -lt 1) {
    throw 'A populated version-1 manifest is required.'
}
$assetProperties = @($index.assets.PSObject.Properties)
if ($assetProperties.Count -eq 0) { throw 'The manifest contains no assets.' }
$releaseCache = @{}
$releaseList = gh api ('repos/' + $Repository + '/releases?per_page=100') | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Releases.' }
$checkedParts = 0
foreach ($assetProperty in $assetProperties) {
    $asset = $assetProperty.Value
    if ($asset.type -ne 'video' -or $asset.container -ne 'mp4' -or $asset.codec -ne 'h264') {
        throw 'Unknown media format.'
    }
    $parts = @($asset.parts)
    if ($parts.Count -eq 0) { throw 'A video must have at least one part.' }
    $totalBytes = [long]0
    $totalDuration = 0.0
    foreach ($part in $parts) {
        if ($part.sha256 -notmatch '^[0-9a-f]{64}$' -or $part.sizeBytes -le 0 -or $part.sizeBytes -ge 2GB) {
            throw 'Invalid local part size or SHA-256.'
        }
        $uri = [Uri]$part.url
        $expectedPrefix = '/' + $Repository + '/releases/download/'
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or -not $uri.AbsolutePath.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
            throw 'Part URL must be an immutable asset URL in the specified GitHub repository.'
        }
        $releasePath = $uri.AbsolutePath.Substring($expectedPrefix.Length).Split('/')
        if ($releasePath.Count -ne 2) { throw 'Invalid Release asset URL.' }
        $tag = [Uri]::UnescapeDataString($releasePath[0])
        $fileName = [Uri]::UnescapeDataString($releasePath[1])
        if (-not $releaseCache.ContainsKey($tag)) {
            $releaseMatches = @($releaseList | Where-Object { $_.tag_name -eq $tag })
            if ($releaseMatches.Count -ne 1) { throw ('Missing or ambiguous Release: ' + $tag) }
            $release = gh api ('repos/' + $Repository + '/releases/' + $releaseMatches[0].id) | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw ('Cannot inspect Release ' + $tag) }
            $releaseCache[$tag] = $release
        }
        $remoteParts = @($releaseCache[$tag].assets | Where-Object { $_.name -eq $fileName })
        if ($remoteParts.Count -ne 1) { throw ('Missing or ambiguous uploaded asset: ' + $fileName) }
        $remote = $remoteParts[0]
        if ($remote.state -ne 'uploaded' -or $remote.size -ne $part.sizeBytes -or $remote.digest -ne ('sha256:' + $part.sha256)) {
            throw ('Remote upload size/state/SHA-256 does not match: ' + $fileName)
        }
        if ([math]::Abs($part.startSeconds - $totalDuration) -gt 0.001 -or $part.durationSeconds -le 0) {
            throw 'The playlist has a gap or an invalid part duration.'
        }
        $totalBytes += $part.sizeBytes
        $totalDuration += $part.durationSeconds
        $checkedParts++
        Write-Output ('Verified remote SHA-256 and size: ' + $fileName)
    }
    if ($totalBytes -ne $asset.sizeBytes -or [math]::Abs($totalDuration - $asset.durationSeconds) -gt 0.001) {
        throw 'Playlist totals do not match the asset.'
    }
}
Write-Output ('Verified all ' + $checkedParts + ' video parts. This script does not delete anything.')
