#!/usr/bin/env node
/**
 * scoova-upload-flutter-symbols — upload Flutter Dart obfuscation symbols
 * to Scoova Monitor so obfuscated release crash traces de-obfuscate.
 *
 * When you build a release with obfuscation:
 *   flutter build apk    --obfuscate --split-debug-info=build/symbols
 *   flutter build appbundle --obfuscate --split-debug-info=build/symbols
 *   flutter build ipa    --obfuscate --split-debug-info=build/symbols
 *
 * Flutter writes one `*.symbols` file per ABI into the --split-debug-info
 * directory (app.android-arm64.symbols, app.ios-arm64.symbols, …). Without
 * those files, Dart stack traces from release crashes are unreadable.
 *
 * This CLI:
 *   1. Walks --dir for `*.symbols` files
 *   2. ZIPs them into one archive (via the system `zip` binary)
 *   3. POSTs it to /v1/upload/mapping with mappingType=flutter
 *
 * The server keeps the symbols and de-obfuscates incoming crash traces
 * for that app version, picking the ABI that matches the crashing device.
 *
 * Usage:
 *   node scoova-upload-flutter-symbols.js \
 *     --api-key sm_xxx \
 *     --version 1.4.0 \
 *     --build 42 \
 *     --dir build/symbols
 *
 * Run it right after `flutter build` in your release script or CI.
 * No external dependencies — Node stdlib + the system `zip` binary.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const child_process = require('child_process');
const https = require('https');
const http = require('http');
const url = require('url');

const args = parseArgs(process.argv.slice(2));

if (!args['api-key'] || !args.version || !args.dir) {
    usage();
    process.exit(1);
}

const endpoint = args.endpoint || 'https://monitor.scoo-va.info';
const buildNumber = String(args.build || '');

main().catch(err => {
    console.error('FAILED:', err.message || err);
    process.exit(2);
});

async function main() {
    const dir = path.resolve(args.dir);
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
        throw new Error(`directory not found: ${dir} — pass the --split-debug-info path`);
    }
    const symbols = walkForSymbols(dir);
    if (symbols.length === 0) {
        console.error(`no *.symbols files found under ${dir}`);
        console.error('Did you build with --obfuscate --split-debug-info=<dir>?');
        process.exit(1);
    }
    console.log(`Found ${symbols.length} symbol file(s):`);
    symbols.forEach(s => console.log(`  · ${path.basename(s)}`));
    console.log(`Uploading to ${endpoint} for v${args.version} build ${buildNumber || '(none)'}`);

    const tmpZip = path.join(os.tmpdir(), `scoova-flutter-symbols-${Date.now()}.zip`);
    try {
        // -j flattens paths so the archive is a flat set of *.symbols files.
        child_process.execFileSync('zip', ['-j', '-q', tmpZip, ...symbols], {
            stdio: ['ignore', 'ignore', 'inherit'],
        });
        const sizeMB = (fs.statSync(tmpZip).size / 1024 / 1024).toFixed(2);
        await upload(tmpZip);
        console.log(`\n✓ Uploaded ${symbols.length} symbol file(s) (${sizeMB} MB).`);
    } finally {
        try { fs.unlinkSync(tmpZip); } catch (_) {}
    }
}

function upload(zipPath) {
    return new Promise((resolve, reject) => {
        const data = fs.readFileSync(zipPath);
        const target = url.parse(endpoint + '/v1/upload/mapping');
        const lib = target.protocol === 'https:' ? https : http;

        const boundary = '----scoova' + Math.random().toString(36).slice(2);
        const parts = [];
        const field = (k, v) => parts.push(Buffer.from(
            `--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`,
        ));
        field('appVersion', args.version);
        field('buildNumber', buildNumber);
        field('platform', 'flutter');
        field('mappingType', 'flutter');
        parts.push(Buffer.from(
            `--${boundary}\r\nContent-Disposition: form-data; name="mapping"; filename="flutter-symbols.zip"\r\n` +
            `Content-Type: application/zip\r\n\r\n`,
        ));
        parts.push(data);
        parts.push(Buffer.from(`\r\n--${boundary}--\r\n`));
        const body = Buffer.concat(parts);

        const req = lib.request({
            hostname: target.hostname,
            port: target.port,
            path: target.path,
            method: 'POST',
            headers: {
                'X-API-Key': args['api-key'],
                'Content-Type': `multipart/form-data; boundary=${boundary}`,
                'Content-Length': body.length,
            },
            timeout: 180_000,
        }, res => {
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => {
                const status = res.statusCode || 0;
                const text = Buffer.concat(chunks).toString('utf8');
                if (status >= 200 && status < 300) return resolve();
                reject(new Error(`HTTP ${status}: ${text.slice(0, 200)}`));
            });
        });
        req.on('error', reject);
        req.on('timeout', () => req.destroy(new Error('upload timed out')));
        req.write(body);
        req.end();
    });
}

function walkForSymbols(dir) {
    const out = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            out.push(...walkForSymbols(p));
        } else if (entry.name.endsWith('.symbols')) {
            out.push(p);
        }
    }
    return out;
}

function parseArgs(argv) {
    const out = {};
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith('--')) {
            const k = a.slice(2);
            const v = (argv[i + 1] && !argv[i + 1].startsWith('--')) ? argv[++i] : 'true';
            out[k] = v;
        }
    }
    return out;
}

function usage() {
    console.error(`scoova-upload-flutter-symbols — upload Flutter obfuscation symbols to Scoova Monitor

Usage:
  node scoova-upload-flutter-symbols.js --api-key <KEY> --version <V> [--build <BUILD>] --dir <DIR> [--endpoint <URL>]

Required:
  --api-key   Scoova Monitor API key for the Flutter platform
  --version   App version, e.g. "1.4.0"
  --dir       The --split-debug-info directory (holds the *.symbols files)

Optional:
  --build     Build number
  --endpoint  Override the Scoova endpoint (default: https://monitor.scoo-va.info)

Build with obfuscation, then upload:
  flutter build appbundle --obfuscate --split-debug-info=build/symbols
  node scoova-upload-flutter-symbols.js --api-key sm_xxx --version 1.4.0 --dir build/symbols
`);
}
