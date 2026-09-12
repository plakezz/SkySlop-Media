import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const original = await readFile(new URL('./verify-streaming.mjs', import.meta.url), 'utf8');
const manifest = {
    schemaVersion: 1,
    revision: 1,
    assets: { test: { parts: [{
        url: 'https://github.com/plakezz/SkySlop-Media/releases/download/test/part.mp4',
        sizeBytes: 128,
    }] } },
};
// Inject test metadata and responses: no network access and no generated files.
const source = original.replace(
    "import { readFile } from 'node:fs/promises';",
    `const readFile = async () => ${JSON.stringify(JSON.stringify(manifest))};`,
);
const savedFetch = globalThis.fetch;
const savedArgument = process.argv[2];
process.argv[2] = 'mock';

async function run(caseName, fetchMock) {
    globalThis.fetch = fetchMock;
    await import(`data:text/javascript,${encodeURIComponent(source)}#${caseName}`);
}

try {
    let requests = 0;
    await run('valid-ranges', async (url, options) => {
        requests++;
        const matches = /bytes=(\d+)-(\d+)/.exec(options.headers.Range);
        assert.ok(matches);
        assert.equal(options.headers['Accept-Encoding'], 'identity');
        const start = Number(matches[1]);
        const end = Number(matches[2]);
        const bytes = new Uint8Array(end - start + 1);
        if (start === 0) bytes.set(new TextEncoder().encode('ftyp'), 4);
        return new Response(bytes, { status: 206, headers: {
            'content-range': `bytes ${start}-${end}/128`,
            'content-length': String(bytes.length),
        } });
    });
    assert.equal(requests, 2);

    let readerRequested = false;
    await assert.rejects(run('ignored-range', async () => ({
        status: 200,
        headers: new Headers({ 'content-length': '128' }),
        body: { getReader() { readerRequested = true; throw new Error('Whole-file read forbidden.'); } },
    })), /Partial fetch failed/);
    assert.equal(readerRequested, false);

    await assert.rejects(run('wrong-total-size', async () => new Response(new Uint8Array(32), {
        status: 206, headers: { 'content-range': 'bytes 0-31/129', 'content-length': '32' },
    })), /Partial fetch failed/);

    await assert.rejects(run('not-mp4', async () => new Response(new Uint8Array(32), {
        status: 206, headers: { 'content-range': 'bytes 0-31/128', 'content-length': '32' },
    })), /not an MP4/);

    await assert.rejects(run('truncated-range', async () => new Response(new Uint8Array(16), {
        status: 206, headers: { 'content-range': 'bytes 0-31/128', 'content-length': '32' },
    })), /ended early/);

    await assert.rejects(run('oversized-range', async () => new Response(new Uint8Array(64), {
        status: 206, headers: { 'content-range': 'bytes 0-31/128', 'content-length': '32' },
    })), /Oversized partial/);

    console.log('PASS: startup and seek; ignored Range, wrong size, invalid MP4, truncation and oversized responses rejected.');
} finally {
    globalThis.fetch = savedFetch;
    if (savedArgument === undefined) delete process.argv[2];
    else process.argv[2] = savedArgument;
}
