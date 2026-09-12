# SkySlop Media

Versioned media assets consumed by the SkySlop Minecraft mod.

Large audio and video files belong in GitHub Release assets, not in the Git repository.
`manifest.json` is the stable machine-readable index used by the mod. Each published
entry should use an immutable, versioned release URL and include its byte size and
SHA-256 checksum.

Only upload media that may legally be redistributed.

## Video publishing

The Subway Surfers base is the complete compilation at
`https://www.youtube.com/watch?v=pQBQ2rYgmlU` (42,775 seconds), processed with the
user's permission. The publishing target is silent H.264 MP4, 854 x 480 at 30 fps,
split into consecutive one-hour parts. Each part is independently seekable, has
its MP4 index at the beginning, and stays below GitHub's 2 GiB asset limit.

1. Download only the video track into a work directory on a drive with enough
   free space. Keep downloads, tools, previews, and encoded files outside Git.
2. Run `scripts/prepare-subway.ps1` with explicit work-directory, FFmpeg, and
   FFprobe paths. `-Encoder h264_amf` can use a compatible AMD GPU for publishing;
   `libx264` is the default software fallback. Playback does not require an AMD GPU.
3. Upload the resulting parts to a new, versioned draft Release, without replacing
   any existing assets. Build the manifest from the script's validated metadata.
   `scripts/upload-subway-parts.ps1` can upload and verify already closed parts
   while the remaining parts are still being encoded; it never publishes the draft.
4. Run `scripts/verify-release.ps1`. Every remote asset must be uploaded and match
   the local byte size and SHA-256 reported by GitHub.
5. Publish the Release, run `node scripts/verify-streaming.mjs` to check public
   byte-range access without downloading the videos, and publish the updated
   manifest. Only then remove the explicitly identified local media work directory.

For this first `subway-base-v1` publication, `scripts/build-subway-manifest.ps1`
can derive the complete index without writing files. The task-specific
`scripts/finish-subway-publication.ps1` waits for the twelve draft uploads, validates
local decoding and remote hashes, edits the manifest using apply_patch, publishes
the Release, checks public partial requests and actual playback/seek, then commits
and pushes only the manifest. With explicit `-CleanupWorkDirectory`, it removes
only the validated D: media work directory after publication is verified. It
stops and retains local videos on errors or concurrent worktree changes. Run it
only from a clean, committed media worktree; it does not build the Minecraft mod.

The manifest's video asset contains `type`, `role`, `container`, `codec`, `width`,
`height`, `framesPerSecond`, `hasAudio`, `loop`, `durationSeconds`, `sizeBytes`, and
ordered `parts`. Each part contains its immutable `url`, `sizeBytes`, `sha256`,
`startSeconds`, `durationSeconds`, and `frameCount`. These are publishing metadata;
the Minecraft player is implemented separately in SkySlop.

Do not publish signed temporary YouTube stream URLs, cookies, API credentials, or
native tooling in the manifest or Release. Replacements get a new versioned URL.

## Playback requirements

Playback streams directly from the hosted Release assets. It must not download a
complete video before starting or persist video files on the player's disk. Use
HTTP byte-range requests with a bounded compressed-data buffer and a small queue
of decoded frames; never buffer an entire one-hour part in memory.

The faststart MP4 index allows playback to begin before the file has arrived and
allows seeking using partial requests. Keep the stable manifest URL rather than
caching GitHub's expiring, signed redirect URLs. Re-resolve redirects when needed.
Temporary clips pause the base playlist and retain its part index and timestamp,
then resume it with a seek. Internet access is required throughout playback;
streaming still transfers the bytes being watched (roughly 350 MB per hour at
the publishing target bitrate).

The manifest's whole-file SHA-256 verifies publication integrity. Do not require
players to download a whole part just to check that hash before streaming.
