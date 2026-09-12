param(
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$Ffmpeg,
    [Parameter(Mandatory = $true)][string]$Ffprobe,
    [string]$Repository = 'plakezz/SkySlop-Media',
    [string]$Tag = 'subway-base-v1'
)

$ErrorActionPreference = 'Stop'
$workRoot = [System.IO.Path]::GetFullPath($WorkDirectory)
if (-not (Test-Path -LiteralPath $workRoot -PathType Container)) { throw 'Work directory must exist.' }
if ((Get-Item -LiteralPath $workRoot).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw 'Redirected work directories are not allowed.'
}
$outputRoot = Join-Path $workRoot 'output'
$deadline = (Get-Date).AddHours(4)
$releaseList = gh api ('repos/' + $Repository + '/releases?per_page=100') | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Releases.' }
# A draft can have a planned tag without an actual Git tag. Retrieve it by ID.
$draftMatches = @($releaseList | Where-Object { $_.tag_name -eq $Tag -and $_.draft })
if ($draftMatches.Count -ne 1) { throw 'Exactly one matching draft Release is required.' }
$draft = $draftMatches[0]
$releaseEndpoint = 'repos/' + $Repository + '/releases/' + $draft.id

for ($index = 0; $index -lt 12; $index++) {
    $fileName = 'subway-base-v1-part-{0:D3}.mp4' -f $index
    $partPath = Join-Path $outputRoot $fileName
    # A part is ready only after the encoder has closed it, including faststart relocation.
    while ($true) {
        if ((Get-Date) -ge $deadline) { throw ('Timed out waiting for ' + $fileName) }
        $partClosed = $false
        if (Test-Path -LiteralPath $partPath -PathType Leaf) {
            $probeHandle = $null
            try {
                $probeHandle = [System.IO.File]::Open($partPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                $partClosed = $true
            } catch [System.IO.IOException] {
                $partClosed = $false
            } finally {
                if ($probeHandle) { $probeHandle.Dispose() }
            }
        }
        $encoderMovedOn = $false
        if ($index -lt 11) {
            $nextFile = Join-Path $outputRoot ('subway-base-v1-part-{0:D3}.mp4' -f ($index + 1))
            $encoderMovedOn = Test-Path -LiteralPath $nextFile -PathType Leaf
        } else {
            $progressFile = Join-Path $outputRoot 'encode-progress.log'
            if (Test-Path -LiteralPath $progressFile -PathType Leaf) {
                $encoderMovedOn = @(Get-Content -LiteralPath $progressFile -Tail 15 | Where-Object { $_ -eq 'progress=end' }).Count -gt 0
            }
        }
        if ($partClosed -and $encoderMovedOn) { break }
        Start-Sleep -Seconds 20
    }

    $part = Get-Item -LiteralPath $partPath
    if ($part.Length -lt 1MB -or $part.Length -ge 2GB) { throw ('Invalid asset size: ' + $fileName) }
    $info = & $Ffprobe -v error -show_entries 'format=duration:stream=codec_type,codec_name,width,height,pix_fmt,r_frame_rate,nb_frames' -of json $partPath | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw ('Cannot inspect ' + $fileName) }
    if (@($info.streams).Count -ne 1) { throw 'A part must contain only one video stream and no audio.' }
    $video = $info.streams[0]
    if ($video.codec_type -ne 'video' -or $video.codec_name -ne 'h264' -or $video.width -ne 854 -or $video.height -ne 480 -or $video.pix_fmt -ne 'yuv420p' -or $video.r_frame_rate -ne '30/1') {
        throw ('Invalid video properties: ' + $fileName)
    }
    $duration = [double]::Parse($info.format.duration, [System.Globalization.CultureInfo]::InvariantCulture)
    if ($duration -le 0 -or $duration -gt 3602 -or ($index -lt 11 -and [math]::Abs($duration - 3600) -gt 0.1)) {
        throw ('Incomplete or invalid video part: ' + $fileName)
    }
    & $Ffmpeg -hide_banner -loglevel error -xerror -nostdin -i $partPath -t 1 -map 0:v:0 -an -f null NUL
    if ($LASTEXITCODE -ne 0) { throw ('Cannot decode start of ' + $fileName) }
    $tailStart = [math]::Max(0, $duration - 1).ToString('F6', [System.Globalization.CultureInfo]::InvariantCulture)
    & $Ffmpeg -hide_banner -loglevel error -xerror -nostdin -ss $tailStart -i $partPath -t 1 -map 0:v:0 -an -f null NUL
    if ($LASTEXITCODE -ne 0) { throw ('Cannot decode end of ' + $fileName) }
    $hash = (Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $existingRelease = gh api $releaseEndpoint | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $existingRelease.draft) { throw 'Release must remain a draft while uploading.' }
    $existing = @($existingRelease.assets | Where-Object { $_.name -eq $fileName })
    if ($existing.Count -gt 1) { throw 'Ambiguous existing asset.' }
    if ($existing.Count -eq 1) {
        if ($existing[0].state -ne 'uploaded' -or $existing[0].size -ne $part.Length -or $existing[0].digest -ne ('sha256:' + $hash)) {
            throw ('Existing immutable asset differs: ' + $fileName)
        }
    } else {
        Write-Output ('Uploading ' + $fileName + ' (' + $part.Length + ' bytes)')
        gh release upload $Tag $partPath --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw ('Upload failed: ' + $fileName) }
    }
    $afterUpload = gh api $releaseEndpoint | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify uploaded asset.' }
    $remote = @($afterUpload.assets | Where-Object { $_.name -eq $fileName })
    if ($remote.Count -ne 1 -or $remote[0].state -ne 'uploaded' -or $remote[0].size -ne $part.Length -or $remote[0].digest -ne ('sha256:' + $hash)) {
        throw ('Remote size or SHA-256 mismatch: ' + $fileName)
    }
    Write-Output ('Verified uploaded ' + $fileName + ': sha256=' + $hash)
}
Write-Output 'All 12 parts uploaded and verified. Release is still a draft; no local files have been deleted.'
