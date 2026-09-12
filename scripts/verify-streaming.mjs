import { readFile } from 'node:fs/promises';

const manifestPath = process.argv[2] ?? new URL('../manifest.json', import.meta.url);
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
if (manifest.schemaVersion !== 1 || manifest.revision < 1) {
    throw new Error('A populated version-1 manifest is required.');
}
const parts = Object.values(manifest.assets).flatMap(asset => asset.parts ?? []);
if (parts.length === 0) throw new Error('The manifest contains no video parts.');

async function verifyRange(part, start, end, checkHeader) {
    const url = new URL(part.url);
    if (url.protocol !== 'https:' || url.hostname !== 'github.com' ||
        !url.pathname.startsWith('/plakezz/SkySlop-Media/releases/download/')) {
        throw new Error('Only immutable SkySlop-Media Release URLs are allowed.');
    }
    if (!Number.isSafeInteger(part.sizeBytes) || part.sizeBytes < 64) {
        throw new Error('Invalid part byte size.');
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30_000);
    let reader;
    try {
        const response = await fetch(url, {
            headers: { Range: `bytes=${start}-${end}`, 'Accept-Encoding': 'identity' },
            signal: controller.signal,
        });
        const expectedRange = `bytes ${start}-${end}/${part.sizeBytes}`;
        const byteCount = end - start + 1;
        // Never read a response that ignored Range and might contain a whole video.
        if (response.status !== 206 || response.headers.get('content-range') !== expectedRange ||
            response.headers.get('content-length') !== String(byteCount)) {
            throw new Error(`Partial fetch failed: HTTP ${response.status}, ${response.headers.get('content-range')}`);
        }
        reader = response.body.getReader();
        const bytes = new Uint8Array(byteCount);
        let received = 0;
        while (received < byteCount) {
            const chunk = await reader.read();
            if (chunk.done) throw new Error('Partial response ended early.');
            if (received + chunk.value.length > byteCount) throw new Error('Oversized partial response.');
            bytes.set(chunk.value, received);
            received += chunk.value.length;
        }
        if (checkHeader && String.fromCharCode(...bytes.slice(4, 8)) !== 'ftyp') {
            throw new Error('The beginning is not an MP4 file-type box.');
        }
        return received;
    } finally {
        if (reader) await reader.cancel().catch(() => {});
        controller.abort();
        clearTimeout(timeout);
    }
}

let verifiedBytes = 0;
for (const part of parts) {
    // Test both startup and a seek near EOF, transferring only 64 bytes per video.
    verifiedBytes += await verifyRange(part, 0, 31, true);
    verifiedBytes += await verifyRange(part, part.sizeBytes - 32, part.sizeBytes - 1, false);
    console.log(`Verified HTTP 206 at both ends: ${part.url.split('/').at(-1)}`);
}
console.log(`Verified ${parts.length} parts using ${verifiedBytes} video bytes; no video files were saved.`);
