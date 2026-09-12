param(
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$Ffmpeg,
    [Parameter(Mandatory = $true)][string]$Ffprobe,
    [ValidateSet('h264_amf', 'libx264')][string]$Encoder = 'libx264'
)

$ErrorActionPreference = 'Stop'
$workRoot = [System.IO.Path]::GetFullPath($WorkDirectory)
if (-not (Test-Path -LiteralPath $workRoot -PathType Container)) {
    throw 'The explicitly supplied work directory must already exist.'
}
if ((Get-Item -LiteralPath $workRoot).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw 'A redirected work directory is not allowed.'
}
$sourceVideo = Join-Path $workRoot 'source\subway-source.mp4'
$outputRoot = Join-Path $workRoot 'output'
$progressPath = Join-Path $outputRoot 'encode-progress.log'
if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
    throw 'Create the output directory before running this script.'
}
if (Get-ChildItem -LiteralPath $outputRoot -Filter 'subway-base-v1-part-*.mp4') {
    throw 'Existing output parts must not be overwritten. Use a fresh work directory.'
}

# Downloading is a separate step. Never read a growing .part file for the full encode.
$downloadDeadline = (Get-Date).AddHours(4)
while (-not (Test-Path -LiteralPath $sourceVideo -PathType Leaf)) {
    if ((Get-Date) -ge $downloadDeadline) { throw 'Source download did not finish within four hours.' }
    Write-Output ('Waiting for complete source download: ' + (Get-Date -Format 'HH:mm:ss'))
    Start-Sleep -Seconds 30
}

$sourceInfo = & $Ffprobe -v error -show_entries 'format=duration:stream=codec_type,width,height' -of json $sourceVideo | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect complete source video.' }
$sourceDuration = [double]::Parse($sourceInfo.format.duration, [System.Globalization.CultureInfo]::InvariantCulture)
if ([math]::Abs($sourceDuration - 42775.008175) -gt 1) {
    throw 'Source duration is not the expected full Subway Surfers compilation.'
}

$encodeArguments = @(
    '-hide_banner', '-loglevel', 'warning', '-nostdin', '-n',
    '-i', $sourceVideo, '-map', '0:v:0', '-an',
    '-vf', 'scale=-2:480:flags=lanczos,fps=30,format=yuv420p',
    '-c:v', $Encoder, '-threads', '4', '-filter_threads', '4',
    '-profile:v', 'main', '-level:v', '3.1',
    '-g', '60', '-force_key_frames', 'expr:gte(t,n_forced*3600)',
    '-maxrate', '1000k', '-bufsize', '2000k'
)
if ($Encoder -eq 'h264_amf') {
    $encodeArguments += @('-quality', 'quality', '-rc', 'vbr_peak', '-b:v', '750k', '-vbaq', '1')
} else {
    $encodeArguments += @('-preset', 'medium', '-crf', '28', '-keyint_min', '60', '-sc_threshold', '0')
}
$encodeArguments += @(
    '-progress', $progressPath, '-stats_period', '15', '-nostats',
    '-f', 'segment', '-segment_time', '3600', '-segment_format', 'mp4',
    '-segment_format_options', 'movflags=+faststart', '-reset_timestamps', '1',
    (Join-Path $outputRoot 'subway-base-v1-part-%03d.mp4')
)
Write-Output ('Encoding all ' + $sourceDuration + ' seconds without audio; encoder=' + $Encoder)
& $Ffmpeg @encodeArguments
if ($LASTEXITCODE -ne 0) { throw 'Video encode failed. Nothing has been published or deleted.' }

$parts = @(Get-ChildItem -LiteralPath $outputRoot -Filter 'subway-base-v1-part-*.mp4' | Sort-Object Name)
if ($parts.Count -ne [math]::Ceiling($sourceDuration / 3600)) {
    throw 'Unexpected number of video parts.'
}
$totalDuration = 0.0
$totalBytes = [long]0
$resultParts = @()
foreach ($part in $parts) {
    if ($part.Length -ge 2GB -or $part.Length -lt 1MB) { throw ('Invalid Release asset size: ' + $part.Name) }
    $partInfo = & $Ffprobe -v error -show_entries 'format=duration,size:stream=codec_type,codec_name,width,height,pix_fmt,r_frame_rate,nb_frames' -of json $part.FullName | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw ('Cannot inspect ' + $part.Name) }
    if (@($partInfo.streams).Count -ne 1) { throw 'Each part must contain only one video stream and no audio.' }
    $video = $partInfo.streams[0]
    if ($video.codec_type -ne 'video' -or $video.codec_name -ne 'h264' -or $video.width -ne 854 -or $video.height -ne 480 -or $video.pix_fmt -ne 'yuv420p' -or $video.r_frame_rate -ne '30/1') {
        throw ('Unexpected video properties: ' + $part.Name)
    }
    $duration = [double]::Parse($partInfo.format.duration, [System.Globalization.CultureInfo]::InvariantCulture)
    if ($duration -le 0 -or $duration -gt 3602) { throw 'Invalid part duration.' }
    # Verify decoding at both ends, not merely the presence of an MP4 header.
    & $Ffmpeg -hide_banner -loglevel error -xerror -nostdin -i $part.FullName -t 1 -map 0:v:0 -an -f null NUL
    if ($LASTEXITCODE -ne 0) { throw ('Beginning cannot be decoded: ' + $part.Name) }
    $tailStart = [math]::Max(0, $duration - 1).ToString('F6', [System.Globalization.CultureInfo]::InvariantCulture)
    & $Ffmpeg -hide_banner -loglevel error -xerror -nostdin -ss $tailStart -i $part.FullName -t 1 -map 0:v:0 -an -f null NUL
    if ($LASTEXITCODE -ne 0) { throw ('End cannot be decoded: ' + $part.Name) }
    $hash = (Get-FileHash -LiteralPath $part.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $resultParts += [ordered]@{
        fileName = $part.Name
        sizeBytes = $part.Length
        sha256 = $hash
        startSeconds = [math]::Round($totalDuration, 6)
        durationSeconds = $duration
        frameCount = [long]$video.nb_frames
    }
    $totalDuration += $duration
    $totalBytes += $part.Length
}
if ([math]::Abs($totalDuration - $sourceDuration) -gt 1) {
    throw 'Video parts do not cover the entire source duration.'
}
[ordered]@{
    sourceUrl = 'https://www.youtube.com/watch?v=pQBQ2rYgmlU'
    sourceDurationSeconds = $sourceDuration
    durationSeconds = [math]::Round($totalDuration, 6)
    sizeBytes = $totalBytes
    codec = 'h264'
    width = 854
    height = 480
    framesPerSecond = 30
    hasAudio = $false
    parts = $resultParts
} | ConvertTo-Json -Depth 6

# Publication and cleanup are deliberately separate, after remote SHA-256 verification.
