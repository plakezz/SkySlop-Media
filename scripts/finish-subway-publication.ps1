param(
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$Ffmpeg,
    [Parameter(Mandatory = $true)][string]$Ffprobe,
    [Parameter(Mandatory = $true)][string]$ApplyPatchExecutable,
    [switch]$CleanupWorkDirectory
)

$ErrorActionPreference = 'Stop'
$repository = 'plakezz/SkySlop-Media'
$tag = 'subway-base-v1'
$releaseId = 387586449
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [IO.Path]::GetFullPath($WorkDirectory)
if ($workRoot -notmatch '^D:\\SkySlop-Media-Work-\d{8}-\d{6}-\d{3}$' -or
    -not (Test-Path -LiteralPath $workRoot -PathType Container) -or
    ((Get-Item -LiteralPath $workRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Only an explicitly identified, non-redirected D: media work directory is allowed.'
}
foreach ($toolPath in @($Ffmpeg, $Ffprobe, $ApplyPatchExecutable)) {
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) { throw 'A required native executable is missing.' }
}
Set-Location -LiteralPath $repoRoot
if ((git branch --show-current) -ne 'main' -or $LASTEXITCODE -ne 0) { throw 'Publication requires the main branch.' }
if ((git remote get-url origin) -ne 'https://github.com/plakezz/SkySlop-Media.git' -or $LASTEXITCODE -ne 0) {
    throw 'Unexpected Git remote.'
}
$baselineCommit = git rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or (git status --porcelain)) { throw 'The media worktree must be clean before starting.' }
$manifestPath = Join-Path $repoRoot 'manifest.json'
$baselineManifest = Get-Content -LiteralPath $manifestPath -Raw
$initial = $baselineManifest | ConvertFrom-Json
if ($initial.revision -ne 0 -or @($initial.assets.PSObject.Properties).Count -ne 0) {
    throw 'This first-publication helper must not overwrite an existing media manifest.'
}
$deadline = (Get-Date).AddHours(4)
$progressPath = Join-Path $workRoot 'output\encode-progress.log'
Write-Output 'Waiting for the complete encode and all verified draft uploads.'
while ($true) {
    if ((Get-Date) -ge $deadline) { throw 'Timed out. Draft and local media have been retained.' }
    $encodeFinished = $false
    if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
        $encodeFinished = @(Get-Content -LiteralPath $progressPath -Tail 15 | Where-Object { $_ -eq 'progress=end' }).Count -gt 0
    }
    if ($encodeFinished) {
        $release = gh api ('repos/' + $repository + '/releases/' + $releaseId) | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the draft. Local media retained.' }
        if ($release.tag_name -ne $tag -or -not $release.draft) { throw 'Unexpected or already-published Release; stopping without cleanup.' }
        if (@($release.assets).Count -eq 12 -and @($release.assets | Where-Object { $_.state -ne 'uploaded' -or $_.digest -notmatch '^sha256:[0-9a-f]{64}$' }).Count -eq 0) {
            break
        }
    }
    Start-Sleep -Seconds 30
}
Write-Output 'Building the manifest from validated full-duration local videos.'
$manifestText = & (Join-Path $PSScriptRoot 'build-subway-manifest.ps1') -WorkDirectory $workRoot -Ffmpeg $Ffmpeg -Ffprobe $Ffprobe
if (-not $?) { throw 'Cannot construct the validated manifest.' }
$manifestText = ($manifestText -join "`n") + "`n"
$manifest = $manifestText | ConvertFrom-Json
# Do not overwrite edits made while the video was processing.
if ((git rev-parse HEAD) -ne $baselineCommit -or (git status --porcelain) -or
    (Get-Content -LiteralPath $manifestPath -Raw) -ne $baselineManifest) {
    throw 'The media worktree changed during processing; draft and local files retained for review.'
}
$patchLines = @('*** Begin Patch', '*** Update File: manifest.json', '@@')
$patchLines += @($baselineManifest.TrimEnd([char[]]"`r`n").Split("`n") | ForEach-Object { '-' + $_.TrimEnd("`r") })
$patchLines += @($manifestText.TrimEnd("`n").Split("`n") | ForEach-Object { '+' + $_ })
$patchLines += '*** End Patch'
$patch = $patchLines -join "`n"
# Windows command-line quoting preserves JSON quotes and multiline patch text.
function ConvertTo-NativeArgument([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
$processInfo = New-Object Diagnostics.ProcessStartInfo
$processInfo.FileName = $ApplyPatchExecutable
$processInfo.Arguments = '--codex-run-as-apply-patch ' + (ConvertTo-NativeArgument $patch)
$processInfo.WorkingDirectory = $repoRoot
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true
$patchProcess = [Diagnostics.Process]::Start($processInfo)
$patchProcess.WaitForExit()
if ($patchProcess.ExitCode -ne 0) { throw 'Manifest patch failed; no publication or cleanup occurred.' }
$patchProcess.Dispose()
& (Join-Path $PSScriptRoot 'verify-release.ps1')
if (-not $?) { throw 'Remote SHA-256 verification failed; local media retained.' }
Write-Output 'All twelve remote hashes match. Publishing the media Release.'
gh release edit $tag --repo $repository --draft=false
if ($LASTEXITCODE -ne 0) { throw 'Release publication failed; local media retained.' }
node (Join-Path $PSScriptRoot 'verify-streaming.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Public streaming verification failed; local media retained.' }
# Check actual remote decoding and seeking, without saving any downloaded video.
foreach ($probe in @(
    @{ url = $manifest.assets.subway_surfers_base.parts[0].url; time = '0' },
    @{ url = $manifest.assets.subway_surfers_base.parts[0].url; time = '1800' },
    @{ url = $manifest.assets.subway_surfers_base.parts[11].url; time = '3000' }
)) {
    & $Ffmpeg -hide_banner -loglevel error -xerror -nostdin -rw_timeout 30000000 -ss $probe.time -i $probe.url -t 1 -map 0:v:0 -an -f null NUL
    if ($LASTEXITCODE -ne 0) { throw 'Hosted playback/seek failed; local media retained.' }
}
if ((git rev-parse HEAD) -ne $baselineCommit -or
    ((git status --porcelain) -join "`n") -ne ' M manifest.json' -or
    ((Get-Content -LiteralPath $manifestPath -Raw).Replace("`r`n", "`n")) -ne $manifestText) {
    throw 'Unexpected concurrent edits before committing; no cleanup.'
}
git add -- manifest.json
if ($LASTEXITCODE -ne 0) { throw 'Cannot stage the manifest.' }
git commit -m 'Publish silent Subway Surfers base streaming playlist' --only -- manifest.json
if ($LASTEXITCODE -ne 0) { throw 'Cannot commit the manifest.' }
git push origin main
if ($LASTEXITCODE -ne 0) { throw 'Cannot push the manifest. Local media retained.' }
$publishedCommit = git rev-parse HEAD
$remoteManifest = gh api ('repos/' + $repository + '/contents/manifest.json?ref=' + $publishedCommit) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $remoteManifest.encoding -ne 'base64') { throw 'Cannot verify the published manifest.' }
$remoteText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($remoteManifest.content)).Replace("`r`n", "`n")
if ($remoteText -ne $manifestText) { throw 'The published manifest differs; local media retained.' }
$publicRelease = gh api ('repos/' + $repository + '/releases/' + $releaseId) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $publicRelease.draft -or $publicRelease.tag_name -ne $tag) {
    throw 'Release is not publicly published; local files retained.'
}
& (Join-Path $PSScriptRoot 'verify-release.ps1')
if (-not $?) { throw 'Final remote verification failed; no cleanup.' }
Write-Output ('Published complete silent video: ' + $manifest.assets.subway_surfers_base.sizeBytes + ' bytes, ' + $manifest.assets.subway_surfers_base.durationSeconds + ' seconds.')
if ($CleanupWorkDirectory) {
    # Re-resolve and revalidate the exact target immediately before deleting.
    $target = Get-Item -LiteralPath $workRoot
    if ($target.FullName -ne $workRoot -or $target.FullName -notmatch '^D:\\SkySlop-Media-Work-\d{8}-\d{6}-\d{3}$' -or
        ($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        @(Get-ChildItem -LiteralPath $workRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
        throw 'Cleanup target validation failed; published media is safe and local files retained.'
    }
    $busyDeadline = (Get-Date).AddMinutes(2)
    while (@(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($workRoot)
    }).Count -gt 0) {
        if ((Get-Date) -ge $busyDeadline) { throw 'Work directory still in use; no cleanup.' }
        Start-Sleep -Seconds 10
    }
    Remove-Item -LiteralPath $workRoot -Recurse -Force
    if (Test-Path -LiteralPath $workRoot) { throw 'Cleanup incomplete.' }
    Write-Output ('Removed only the verified local media work directory: ' + $workRoot)
}
Write-Output ('Complete: https://github.com/' + $repository + '/releases/tag/' + $tag)
