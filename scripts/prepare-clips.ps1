param(
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$Ffmpeg,
    [Parameter(Mandatory = $true)][string]$Ffprobe,
    [string]$Tag = 'clips-v1'
)
$ErrorActionPreference = 'Stop'
$inputRoot = [IO.Path]::GetFullPath($InputDirectory)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if ($inputRoot -eq $outputRoot) { throw 'Never overwrite original clips.' }
foreach ($directory in @($inputRoot,$outputRoot)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container) -or
        ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Explicit existing non-redirected directories are required.'
    }
}
if (Get-ChildItem -LiteralPath $outputRoot -File) { throw 'Use an empty output directory.' }
$clips = @(Get-ChildItem -LiteralPath $inputRoot -File -Filter '*.mp4' | Sort-Object Name)
if ($clips.Count -eq 0) { throw 'No MP4 clips found.' }
$assets = [ordered]@{}
foreach ($clip in $clips) {
    if ($clip.Length -ge 2GB -or ($clip.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid input clip.' }
    $sourceHash = (Get-FileHash -LiteralPath $clip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $id = 'clip_' + $sourceHash.Substring(0,16)
    if ($assets.Contains($id)) { throw 'Duplicate clip source.' }
    $fileName = $id + '.mp4'
    $outputPath = Join-Path $outputRoot $fileName
    # Container relocation only: retain all original video/audio streams and packets.
    & $Ffmpeg -hide_banner -loglevel error -nostdin -n -i $clip.FullName -map 0 -c copy -movflags +faststart $outputPath
    if ($LASTEXITCODE -ne 0) { throw ('Lossless remux failed: ' + $clip.Name) }
    $sourceStreams = @(& $Ffmpeg -hide_banner -loglevel error -nostdin -i $clip.FullName -map 0 -c copy -f streamhash -hash sha256 -)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot hash original compressed streams.' }
    $outputStreams = @(& $Ffmpeg -hide_banner -loglevel error -nostdin -i $outputPath -map 0 -c copy -f streamhash -hash sha256 -)
    if ($LASTEXITCODE -ne 0 -or ($sourceStreams -join "`n") -ne ($outputStreams -join "`n")) {
        throw ('Compressed video/audio payload changed: ' + $clip.Name)
    }
    $info = & $Ffprobe -v error -show_entries 'format=duration,size:stream=codec_type,codec_name,width,height,r_frame_rate,nb_frames' -of json $outputPath | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect prepared clip.' }
    $videos = @($info.streams | Where-Object {$_.codec_type -eq 'video'})
    $audio = @($info.streams | Where-Object {$_.codec_type -eq 'audio'})
    if ($videos.Count -ne 1 -or $videos[0].codec_name -ne 'h264' -or $audio.Count -eq 0 -or
        @($audio | Where-Object {$_.codec_name -ne 'aac'}).Count -gt 0) { throw 'Expected H.264 video with AAC audio.' }
    $video = $videos[0]
    $rate = $video.r_frame_rate.Split('/')
    $fps = [double]$rate[0] / [double]$rate[1]
    $duration = [double]::Parse($info.format.duration,[Globalization.CultureInfo]::InvariantCulture)
    if ($duration -le 0 -or $duration -gt 3600 -or $fps -le 0 -or $fps -gt 240) { throw 'Invalid clip timing.' }
    & $Ffmpeg -hide_banner -loglevel error -xerror -nostdin -i $outputPath -map 0:v:0 -map '0:a?' -f null NUL
    if ($LASTEXITCODE -ne 0) { throw ('Full video/audio decode failed: ' + $clip.Name) }
    $file = Get-Item -LiteralPath $outputPath
    $hash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $assets[$id] = [ordered]@{
        type='video'; role='clip'; name=$clip.Name; container='mp4'; codec='h264'
        width=[int]$video.width; height=[int]$video.height; framesPerSecond=$fps
        hasAudio=$true; audioTrackCount=$audio.Count; loop=$false
        durationSeconds=$duration; sizeBytes=$file.Length
        sourceSha256=$sourceHash; streamSha256=$sourceStreams
        parts=@([ordered]@{
            url='https://github.com/plakezz/SkySlop-Media/releases/download/'+$Tag+'/'+$fileName
            sizeBytes=$file.Length; sha256=$hash; startSeconds=0; durationSeconds=$duration
            frameCount=[long]$video.nb_frames
        })
    }
    Write-Host ('Prepared unchanged streams: ' + $clip.Name)
}
$assets | ConvertTo-Json -Depth 8
