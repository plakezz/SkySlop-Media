param(
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$Ffmpeg,
    [Parameter(Mandatory = $true)][string]$Ffprobe
)

$ErrorActionPreference = 'Stop'
$workRoot = [System.IO.Path]::GetFullPath($WorkDirectory)
if (-not (Test-Path -LiteralPath $workRoot -PathType Container) -or
    ((Get-Item -LiteralPath $workRoot).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'An existing, non-redirected work directory is required.'
}
$sourcePath = Join-Path $workRoot 'source\subway-source.mp4'
$source = & $Ffprobe -v error -show_entries 'format=duration' -of json $sourcePath | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the completed source.' }
$sourceDuration = [double]::Parse($source.format.duration, [Globalization.CultureInfo]::InvariantCulture)
if ([math]::Abs($sourceDuration - 42775.008175) -gt 1) { throw 'Unexpected source duration.' }
$outputRoot = Join-Path $workRoot 'output'
$parts = @(Get-ChildItem -LiteralPath $outputRoot -Filter 'subway-base-v1-part-*.mp4' | Sort-Object Name)
if ($parts.Count -ne 12) { throw 'All twelve video parts are required.' }
$totalDuration = 0.0
$totalBytes = [long]0
$playlist = @()
for ($index = 0; $index -lt 12; $index++) {
    $part = $parts[$index]
    $expectedName = 'subway-base-v1-part-{0:D3}.mp4' -f $index
    if ($part.Name -ne $expectedName -or $part.Length -lt 1MB -or $part.Length -ge 2GB -or
        ($part.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw 'Invalid video part name, size, or redirection.'
    }
    $handle = [IO.File]::Open($part.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $handle.Dispose()
    $info = & $Ffprobe -v error -show_entries 'format=duration:stream=codec_type,codec_name,width,height,pix_fmt,r_frame_rate,nb_frames' -of json $part.FullName | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or @($info.streams).Count -ne 1) { throw 'A part must contain exactly one video stream.' }
    $video = $info.streams[0]
    if ($video.codec_type -ne 'video' -or $video.codec_name -ne 'h264' -or $video.width -ne 854 -or
        $video.height -ne 480 -or $video.pix_fmt -ne 'yuv420p' -or $video.r_frame_rate -ne '30/1') {
        throw ('Invalid video properties: ' + $part.Name)
    }
    $duration = [double]::Parse($info.format.duration, [Globalization.CultureInfo]::InvariantCulture)
    $frames = [long]$video.nb_frames
    if ($duration -le 0 -or $duration -gt 3602 -or $frames -le 0 -or
        [math]::Abs($frames - ($duration * 30)) -gt 1 -or
        ($index -lt 11 -and [math]::Abs($duration - 3600) -gt 0.1)) {
        throw ('Incomplete video part: ' + $part.Name)
    }
    & $Ffmpeg -hide_banner -loglevel error -xerror -nostdin -i $part.FullName -t 1 -map 0:v:0 -an -f null NUL
    if ($LASTEXITCODE -ne 0) { throw ('Cannot decode beginning: ' + $part.Name) }
    $tailStart = [math]::Max(0, $duration - 1).ToString('F6', [Globalization.CultureInfo]::InvariantCulture)
    & $Ffmpeg -hide_banner -loglevel error -xerror -nostdin -ss $tailStart -i $part.FullName -t 1 -map 0:v:0 -an -f null NUL
    if ($LASTEXITCODE -ne 0) { throw ('Cannot decode end: ' + $part.Name) }
    $hash = (Get-FileHash -LiteralPath $part.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $playlist += [ordered]@{
        url = 'https://github.com/plakezz/SkySlop-Media/releases/download/subway-base-v1/' + $part.Name
        sizeBytes = $part.Length
        sha256 = $hash
        startSeconds = [math]::Round($totalDuration, 6)
        durationSeconds = $duration
        frameCount = $frames
    }
    $totalBytes += $part.Length
    $totalDuration += $duration
}
if ([math]::Abs($totalDuration - $sourceDuration) -gt 1) { throw 'Parts do not cover the complete source.' }
[ordered]@{
    schemaVersion = 1
    revision = 1
    assets = [ordered]@{
        subway_surfers_base = [ordered]@{
            type = 'video'
            role = 'base'
            container = 'mp4'
            codec = 'h264'
            width = 854
            height = 480
            framesPerSecond = 30
            hasAudio = $false
            loop = $true
            sourceUrl = 'https://www.youtube.com/watch?v=pQBQ2rYgmlU'
            durationSeconds = [math]::Round($totalDuration, 6)
            sizeBytes = $totalBytes
            parts = $playlist
        }
    }
} | ConvertTo-Json -Depth 8
