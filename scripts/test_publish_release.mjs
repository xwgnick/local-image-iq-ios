// Synthetic Node built-in tests only: temporary files + in-memory HTTP responses.
// Never use credentials, network, macOS tools, Git or a real GitHub repository.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { ASSET_PATHS, MAX_ASSET_BYTES, REPOSITORY, collectAssets, createClient,
  hashStream, main, parseArgs, readExpectedAppIdentity, validateAssetSize, validateEnvironment } from './publish_release.mjs';

const SHA = 'a'.repeat(40), MODEL = `siglip2-b16-224-v1-${'b'.repeat(64)}`;
const IPA = 'LocalImageIQ-iphoneos-unsigned.ipa';
const TAG = 'ci-12345-2';
const DRAFT_URL = `https://github.com/${REPOSITORY}/releases/tag/untagged-${'d'.repeat(40)}`;
const SECRET = 'SYNTHETIC_TOKEN_NOT_A_REAL_CREDENTIAL';
const SIGNED = 'https://release-assets.githubusercontent.com/synthetic/blob?signature=DO_NOT_LOG';
const digest = data => createHash('sha256').update(data).digest('hex');
const flags = (status = 'success', device = true, models = true) => ({ status, device, models });
const argv = f => ['--status', f.status, '--device', String(f.device), '--models', String(f.models)];
const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
const env = () => ({ GITHUB_TOKEN: SECRET, GITHUB_REPOSITORY: REPOSITORY, GITHUB_SHA: SHA,
  GITHUB_RUN_ID: '12345', GITHUB_RUN_ATTEMPT: '2', GITHUB_SERVER_URL: 'https://github.com' });

async function fixture(t, { appVersion = '0.4.0', appBuild = '11' } = {}) {
  const root = await mkdtemp(path.join(tmpdir(), 'imageiq-release-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const put = async (relative, data) => {
    const file = path.join(root, relative);
    await mkdir(path.dirname(file), { recursive: true }); await writeFile(file, data); return file;
  };
  const putJSON = (name, value) => put(ASSET_PATHS[name], `${JSON.stringify(value)}\n`);
  const project = `settings:\n  base:\n    MARKETING_VERSION: "${appVersion}"\n    CURRENT_PROJECT_VERSION: "${appBuild}"\n`;
  await put('project.yml', project);
  // Multiple createReadStream chunks without any large allocation or actual IPA.
  const ipa = Buffer.alloc(196_613, 0x61);
  await put(ASSET_PATHS[IPA], ipa);
  for (const name of ['UIReview.zip', 'TestResults.xcresult.zip', 'LocalImageIQ-Simulator.zip'])
    await put(ASSET_PATHS[name], `SYNTHETIC ZIP: ${name}`);
  const places = { schemaVersion: 1, generated: { file: 'Places.geojson', bytes: 17,
    featureCount: 1, sha256: 'c'.repeat(64) } };
  await putJSON('places-manifest.json', places);
  const placesBytes = await readFile(path.join(root, ASSET_PATHS['places-manifest.json']));
  const report = { platform: 'iphoneos', architectures: ['arm64'], configuration: 'Release', signed: false,
    installableWithoutResigning: false, deviceTested: false, appVersion, appBuild,
    bundleIdentifier: 'com.example.localimageiq', modelVersion: MODEL, modelDimension: 768,
    ipa: IPA, bytes: ipa.length, sha256: digest(ipa),
    places: { ...places.generated, manifestSHA256: digest(placesBytes) } };
  await putJSON('device-build.json', report);
  await put(ASSET_PATHS['SHA256SUMS.txt'], `${digest(ipa)}  ${IPA}\n`);
  await putJSON('parity-report.json', { schemaVersion: 2, modelVersion: MODEL, passed: true });
  await putJSON('provenance.json', { schemaVersion: 2, modelVersion: MODEL, training: false });
  const logs = [], environment = { ...env(), GITHUB_STEP_SUMMARY: path.join(root, 'summary.md'), GITHUB_OUTPUT: path.join(root, 'outputs.txt') };
  return { root, put, putJSON, project, report, ipa, logs, environment,
    run(mock, f = flags()) { return main({ root, argv: argv(f), env: environment, transport: mock.transport, log: line => logs.push(line) }); } };
}

function github(options = {}) {
  const requests = [], events = [], assets = new Map();
  let release = null, uploaded = 0, tagExists = !!options.tagCollision;
  const record = (url, init) => {
    const entry = { url, method: init.method ?? 'GET', headers: init.headers, redirect: init.redirect,
      body: typeof init.body === 'string' ? JSON.parse(init.body) : null };
    requests.push(entry); return entry;
  };
  const transport = async (url, init = {}) => {
    const entry = record(url, init), u = new URL(url), route = u.pathname.replace(`/repos/${REPOSITORY}`, '');
    if (u.hostname === 'release-assets.githubusercontent.com') {
      assert.equal(init.redirect, 'manual');
      assert.ok(!Object.keys(init.headers ?? {}).some(key => key.toLowerCase() === 'authorization'));
      const asset = assets.get(Number(u.searchParams.get('asset')));
      return options.secondRedirect ? new Response(null, { status: 302, headers: { location: SIGNED } })
        : new Response(options.downloadMismatch ? Buffer.from('CORRUPT') : asset.data);
    }
    assert.ok(['api.github.com', 'uploads.github.com'].includes(u.hostname), 'No unmocked host/network');
    assert.equal(init.redirect, 'manual'); assert.equal(init.headers.Authorization, `Bearer ${SECRET}`);
    if (u.hostname === 'uploads.github.com') {
      assert.equal(entry.method, 'POST'); assert.equal(init.duplex, 'half');
      const name = u.searchParams.get('name');
      assert.ok(name in ASSET_PATHS || name === 'delivery.json');
      assert.equal(init.headers['Content-Type'], name.endsWith('.json') ? 'application/json'
        : name.endsWith('.zip') ? 'application/zip' : 'application/octet-stream');
      assert.ok(!Buffer.isBuffer(init.body) && typeof init.body[Symbol.asyncIterator] === 'function');
      const chunks = [];
      for await (const chunk of init.body) chunks.push(chunk);
      const data = Buffer.concat(chunks); // Small synthetic mock fixtures only, never production assets.
      assert.equal(String(data.length), init.headers['Content-Length']);
      uploaded++; events.push(`upload:${name}`);
      if (options.throwUpload) throw new Error(`Bearer ${SECRET}; signed=${SIGNED}`);
      if (options.failUploadAt === uploaded) return json({ message: `${SECRET} ${SIGNED}` }, 502);
      assert.ok(![...assets.values()].some(item => item.name === name), 'Never overwrite an asset');
      const remote = { id: 900 + uploaded, name, size: data.length, state: 'uploaded', digest: `sha256:${digest(data)}`, data };
      assets.set(remote.id, remote);
      return json({ ...remote, data: undefined, digest: options.noDigest ? null : remote.digest }, 201);
    }
    if (route === '') return json({ full_name: options.repositoryName ?? REPOSITORY, private: options.public !== true });
    if (route.startsWith('/commits/')) return json({ sha: options.commitMismatch ? 'd'.repeat(40) : SHA });
    if (route.startsWith('/actions/runs/')) return json({ id: 12345, run_attempt: options.attemptMismatch ? 1 : 2,
      status: 'in_progress', conclusion: null, head_sha: options.runMismatch ? 'e'.repeat(40) : SHA,
      repository: { full_name: REPOSITORY } });
    if (route.startsWith('/git/ref/tags/')) return tagExists
      ? json({ object: { type: 'commit', sha: options.publishedTagMismatch ? 'f'.repeat(40) : SHA } }) : json({}, 404);
    if (route.startsWith('/releases/tags/')) return options.releaseCollision ? json({ id: 999, tag_name: TAG }) : json({}, 404);
    if (route === '/releases' && entry.method === 'GET') {
      if (options.draftCollision) return json([{ id: 998, tag_name: TAG, draft: true }]);
      return json(release ? [release] : []);
    }
    if (route === '/releases' && entry.method === 'POST') {
      assert.equal(release, null, 'Only one creation attempt');
      assert.equal(entry.body.draft, true); assert.equal(entry.body.prerelease, true);
      assert.equal(entry.body.make_latest, 'false'); assert.equal(entry.body.target_commitish, SHA);
      assert.equal(entry.body.tag_name, TAG);
      events.push('create-draft');
      release = { ...entry.body, id: 700, html_url: DRAFT_URL };
      if (options.onCreate) await options.onCreate();
      return json(release, 201);
    }
    const assetID = /^\/releases\/assets\/(\d+)$/.exec(route);
    if (assetID) {
      const asset = assets.get(Number(assetID[1])); assert.ok(asset);
      if (init.headers.Accept === 'application/octet-stream') {
        events.push(`download:${asset.name}`);
        if (options.directDownload) return new Response(options.downloadMismatch ? Buffer.from('CORRUPT') : asset.data);
        const location = `${SIGNED}&asset=${asset.id}`;
        return new Response(null, { status: 302, headers: { location: options.httpDownload ? location.replace('https:', 'http:') : location } });
      }
      events.push(`verify:${asset.name}`);
      return json({ ...asset, data: undefined, ...(options.assetMetadata ?? {}),
        digest: options.remoteMismatch ? `sha256:${'0'.repeat(64)}` : options.noDigest ? null : asset.digest });
    }
    if (route === '/releases/700') {
      if (entry.method === 'PATCH') {
        if (entry.body.draft === false) {
          events.push('publish'); tagExists = true;
          assert.equal(entry.body.make_latest, 'false'); assert.equal(entry.body.prerelease, true);
          Object.assign(release, entry.body);
          if (options.publicationResponseLost) throw new Error(`${SECRET} ${SIGNED}`);
        } else {
          events.push('retain-draft');
          if (options.redraftFails) throw new Error(SECRET);
          Object.assign(release, entry.body);
        }
      }
      return json(release);
    }
    assert.fail(`Unexpected mock route: ${entry.method} ${route}`);
  };
  return { transport, requests, events, assets, get release() { return release; } };
}

const noCreate = mock => assert.ok(!mock.events.includes('create-draft'));
const noPublish = mock => assert.ok(!mock.events.includes('publish'));
const noDelete = mock => assert.ok(mock.requests.every(r => r.method !== 'DELETE' && r.method !== 'PUT'));

test('strict CLI/environment; reject wrong repo, URL/ID injection and duplicate switches', () => {
  assert.deepEqual(parseArgs(argv(flags())), flags());
  assert.throws(() => parseArgs(['--status', 'success', '--device', 'true', '--device', 'false']));
  assert.throws(() => parseArgs(['--status', 'success', '--device', '1', '--models', 'true']));
  for (const change of [{ GITHUB_REPOSITORY: 'other/local-image-iq-ios' }, { GITHUB_SERVER_URL: 'https://github.com.evil.test' },
    { GITHUB_SHA: 'main' }, { GITHUB_RUN_ID: '1\nhttps://evil.test' }, { GITHUB_RUN_ATTEMPT: '02' }, { GITHUB_TOKEN: '' }])
    assert.throws(() => validateEnvironment({ ...env(), ...change }));
  assert.equal(validateEnvironment(env()).tag, TAG);
});

test('actual GitHub under-2-GiB bound, not an invented smaller limit', () => {
  assert.equal(validateAssetSize(1_414_801_289), 1_414_801_289);
  assert.equal(validateAssetSize(MAX_ASSET_BYTES - 1), MAX_ASSET_BYTES - 1);
  for (const bytes of [0, -1, MAX_ASSET_BYTES, MAX_ASSET_BYTES + 1, NaN, 0.5]) assert.throws(() => validateAssetSize(bytes));
});

test('stream hashing counts exact chunks and SHA256', async () => {
  const actual = await hashStream(Readable.from([Buffer.from('abc'), Buffer.from('def')]));
  assert.deepEqual(actual, { bytes: 6, sha256: digest('abcdef') });
});

test('project identity reads exact quoted keys with LF or CRLF, ignoring comments and similar keys', async t => {
  const f = await fixture(t);
  const project = f.project + '    # MARKETING_VERSION: "9.9.9"\n    # CURRENT_PROJECT_VERSION: "99"\n' +
    '    PREVIOUS_MARKETING_VERSION: "9.9.9"\n    MARKETING_VERSION_SUFFIX: "9.9.9"\n' +
    '    PREVIOUS_CURRENT_PROJECT_VERSION: "99"\n    CURRENT_PROJECT_VERSION_SUFFIX: "99"\n';
  for (const text of [project, project.replaceAll('\n', '\r\n')]) {
    await f.put('project.yml', text);
    assert.deepEqual(await readExpectedAppIdentity(f.root), { appVersion: '0.4.0', appBuild: '11' });
  }
});

test('missing, duplicate or unquoted project identity blocks device success before any requests', async t => {
  for (const [key, value] of [['MARKETING_VERSION', '0.4.0'], ['CURRENT_PROJECT_VERSION', '11']]) {
    for (const kind of ['missing', 'duplicate', 'unquoted', 'duplicate-unquoted']) {
      await t.test(`${key}: ${kind}`, async t => {
        const f = await fixture(t), mock = github();
        const line = `    ${key}: "${value}"\n`, unquoted = `    ${key}: ${value}\n`;
        const project = {
          missing: f.project.replace(line, ''), duplicate: f.project + line,
          unquoted: f.project.replace(line, unquoted), 'duplicate-unquoted': f.project + unquoted,
        }[kind];
        await f.put('project.yml', project);
        await assert.rejects(readExpectedAppIdentity(f.root), /project-identity/);
        const result = await f.run(mock);
        assert.equal(result.ok, false); assert.equal(result.boundary, 'local-evidence');
        assert.equal(mock.requests.length, 0); noCreate(mock);
      });
    }
  }
});

test('a new project version and build publish through the same production entry', async t => {
  const identity = { appVersion: '1.2.3', appBuild: '42' };
  const f = await fixture(t, identity), mock = github(), result = await f.run(mock);
  assert.equal(result.ok, true); assert.equal(result.release.state, 'published-prerelease');
  assert.equal(result.deviceReport.appVersion, identity.appVersion);
  assert.equal(result.deviceReport.appBuild, identity.appBuild);
});

test('a new project identity rejects a stale report version or build before any requests', async t => {
  for (const change of [{ appVersion: '0.4.0' }, { appBuild: '11' }]) {
    await t.test(Object.keys(change)[0], async t => {
      const f = await fixture(t, { appVersion: '1.2.3', appBuild: '42' }), mock = github();
      await f.putJSON('device-build.json', { ...f.report, ...change });
      const result = await f.run(mock);
      assert.equal(result.ok, false); assert.equal(result.boundary, 'local-evidence');
      assert.equal(mock.requests.length, 0); noCreate(mock);
    });
  }
});

test('device places featureCount must match the manifest even when every hash and byte count matches', async t => {
  const f = await fixture(t), mock = github();
  await f.putJSON('device-build.json', { ...f.report,
    places: { ...f.report.places, featureCount: f.report.places.featureCount + 1 } });
  const result = await f.run(mock);
  assert.equal(result.ok, false); assert.equal(result.boundary, 'local-evidence');
  assert.equal(mock.requests.length, 0); noCreate(mock);
});

test('exact allowlist ignores extra files and never selects an alternate IPA/path', async t => {
  const f = await fixture(t);
  await f.put('build/release-evidence/private-photo.jpg', 'MUST NOT UPLOAD');
  await f.put('build/device/other.ipa', 'MUST NOT UPLOAD');
  await f.put('build/release-evidence/secret.env', SECRET);
  const { assets } = await collectAssets(f.root, flags());
  assert.deepEqual(assets.map(a => a.name), ['UIReview.zip', 'TestResults.xcresult.zip', 'places-manifest.json',
    'parity-report.json', 'provenance.json', IPA, 'device-build.json', 'SHA256SUMS.txt']);
});

test('reject every missing success output before remote creation', async t => {
  for (const name of ['UIReview.zip', 'TestResults.xcresult.zip', 'places-manifest.json', 'parity-report.json',
    'provenance.json', IPA, 'device-build.json', 'SHA256SUMS.txt']) {
    await t.test(name, async t => {
      const f = await fixture(t), mock = github(); await rm(path.join(f.root, ASSET_PATHS[name]));
      const result = await f.run(mock); assert.equal(result.ok, false); noCreate(mock);
    });
  }
});

test('device identity, version/build, real IPA bytes/hash and checksum gate creation', async t => {
  for (const change of [{ platform: 'iphonesimulator' }, { architectures: ['x86_64'] }, { configuration: 'Debug' },
    { signed: true }, { appVersion: '0.3.4' }, { appBuild: '10' }, { bytes: 1 }, { sha256: '0'.repeat(64) },
    { ipa: '../../private.ipa' }, { modelVersion: `siglip2-b16-224-v1-${'d'.repeat(64)}` }]) {
    await t.test(Object.keys(change)[0], async t => {
      const f = await fixture(t), mock = github(); await f.putJSON('device-build.json', { ...f.report, ...change });
      assert.equal((await f.run(mock)).ok, false); noCreate(mock);
    });
  }
  await t.test('real IPA changed with original report', async t => {
    const f = await fixture(t), mock = github(); await f.put(ASSET_PATHS[IPA], Buffer.alloc(f.ipa.length, 0x62));
    assert.equal((await f.run(mock)).ok, false); noCreate(mock);
  });
  await t.test('wrong SHA256SUMS', async t => {
    const f = await fixture(t), mock = github(); await f.put(ASSET_PATHS['SHA256SUMS.txt'], `${'0'.repeat(64)}  ${IPA}\n`);
    assert.equal((await f.run(mock)).ok, false); noCreate(mock);
  });
});

test('wrong/private repository, target commit, run SHA and attempt are verified before creation', async t => {
  for (const options of [{ public: true }, { repositoryName: 'other/repo' }, { commitMismatch: true },
    { runMismatch: true }, { attemptMismatch: true }]) {
    await t.test(Object.keys(options)[0], async t => {
      const f = await fixture(t), mock = github(options);
      const result = await f.run(mock); assert.equal(result.ok, false); noCreate(mock);
    });
  }
  await t.test('wrong environment repo makes zero requests', async t => {
    const f = await fixture(t), mock = github(); f.environment.GITHUB_REPOSITORY = 'other/repo';
    assert.equal((await f.run(mock)).ok, false); assert.equal(mock.requests.length, 0);
  });
});

test('existing tags, releases and unpublished drafts are never overwritten or deleted', async t => {
  for (const options of [{ tagCollision: true }, { releaseCollision: true }, { draftCollision: true }]) {
    await t.test(Object.keys(options)[0], async t => {
      const f = await fixture(t), mock = github(options);
      assert.equal((await f.run(mock)).ok, false); noCreate(mock); noDelete(mock);
    });
  }
});

test('success: stream/verify ALL payload + manifest, then publish prerelease, never latest', async t => {
  const f = await fixture(t), mock = github(), result = await f.run(mock);
  assert.equal(result.ok, true); assert.equal(result.release.state, 'published-prerelease');
  assert.equal(mock.release.draft, false); assert.equal(result.deviceReport.appVersion, '0.4.0');
  assert.equal(result.deviceReport.appBuild, '11'); assert.equal(result.model.version, MODEL);
  assert.equal(result.places.featureCount, f.report.places.featureCount);
  assert.equal(result.assets.length, 9); noDelete(mock);
  const publish = mock.events.indexOf('publish');
  assert.ok(mock.events.indexOf('verify:delivery.json') < publish && publish > 0);
  assert.ok(mock.events.filter(e => e.startsWith('verify:')).length === 9);
  const deliveryAsset = [...mock.assets.values()].find(a => a.name === 'delivery.json');
  const delivery = JSON.parse(deliveryAsset.data.toString());
  assert.equal(delivery.release.url, DRAFT_URL);
  assert.equal(delivery.assets.length, 8); assert.ok(delivery.assets.every(a => a.name !== 'delivery.json'));
  for (const asset of result.assets) {
    const uploaded = mock.assets.get(asset.id);
    assert.equal(asset.sha256, digest(uploaded.data)); assert.equal(asset.bytes, uploaded.data.length);
  }
  const record = JSON.parse(await readFile(path.join(f.root, 'build/release-evidence/release-delivery.json'), 'utf8'));
  assert.equal(record.outcome, 'published-prerelease'); assert.equal(record.assets.length, 9);
  assert.match(await readFile(f.environment.GITHUB_OUTPUT, 'utf8'), /release_id=700/);
  assert.match(await readFile(f.environment.GITHUB_STEP_SUMMARY, 'utf8'), /SHA256=/);
});

test('failure: best available evidence only, never IPA/report/checksums/simulator or publish', async t => {
  const f = await fixture(t), mock = github();
  await rm(path.join(f.root, ASSET_PATHS['TestResults.xcresult.zip']));
  await f.put(ASSET_PATHS['parity-report.json'], '{ incomplete failure report');
  const result = await f.run(mock, flags('failure'));
  assert.equal(result.ok, true); assert.equal(result.outcome, 'failure-evidence-draft');
  assert.equal(result.release.state, 'draft'); assert.match(mock.release.name, /DRAFT.*FAILURE/);
  assert.equal(result.release.url, DRAFT_URL);
  assert.match(mock.release.body, /upstream-workflow/); noPublish(mock); noDelete(mock);
  assert.ok([...mock.assets.values()].every(a => ![IPA, 'device-build.json', 'SHA256SUMS.txt', 'LocalImageIQ-Simulator.zip'].includes(a.name)));
  assert.equal(result.deviceReport, null); assert.equal(result.model.exportParityPassed, null);
});

test('failure without evidence creates no empty release', async t => {
  const f = await fixture(t), mock = github(); await rm(path.join(f.root, 'build/release-evidence'), { recursive: true });
  await f.put(ASSET_PATHS['UIReview.zip'], ''); // An interrupted zero-byte ZIP is not usable evidence.
  const result = await f.run(mock, flags('failure'));
  assert.equal(result.ok, true); assert.equal(result.outcome, 'skipped-no-failure-evidence'); noCreate(mock);
});

test('simulator success requires its ZIP; model-free ignores even existing model/device files', async t => {
  const f = await fixture(t), mock = github();
  const result = await f.run(mock, flags('success', false, false));
  assert.equal(result.ok, true); assert.equal(result.model.version, null); assert.equal(result.deviceReport, null);
  assert.deepEqual([...mock.assets.values()].map(a => a.name), ['UIReview.zip', 'TestResults.xcresult.zip',
    'places-manifest.json', 'LocalImageIQ-Simulator.zip', 'delivery.json']);
  await rm(path.join(f.root, ASSET_PATHS['LocalImageIQ-Simulator.zip']));
  const missing = github(); assert.equal((await f.run(missing, flags('success', false, false))).ok, false); noCreate(missing);
});

test('partial upload failure retains created draft, does not retry/delete/publish or write final record', async t => {
  const f = await fixture(t), mock = github({ failUploadAt: 2 });
  const result = await f.run(mock); assert.equal(result.ok, false); assert.equal(result.release.id, 700);
  assert.equal(result.release.state, 'draft'); assert.equal(mock.assets.size, 1);
  assert.match(mock.release.name, /DRAFT.*FAILURE/); assert.match(mock.release.body, /upload-verify:TestResults.xcresult.zip/);
  assert.equal(mock.events.filter(e => e.startsWith('upload:')).length, 2); noPublish(mock); noDelete(mock);
  await assert.rejects(access(path.join(f.root, 'build/release-evidence/release-delivery.json')));
});

test('remote digest/state/size/ID mismatch never publishes', async t => {
  for (const options of [{ remoteMismatch: true }, { assetMetadata: { state: 'starter' } },
    { assetMetadata: { size: 1 } }, { assetMetadata: { id: 9876 } }]) {
    await t.test(JSON.stringify(options), async t => {
      const f = await fixture(t), mock = github(options);
      assert.equal((await f.run(mock)).ok, false); noPublish(mock); noDelete(mock); assert.equal(mock.release.draft, true);
    });
  }
});

test('absent remote digest streams HTTPS signed downloads without forwarding authorization', async t => {
  const f = await fixture(t), mock = github({ noDigest: true });
  const result = await f.run(mock); assert.equal(result.ok, true);
  assert.ok(result.assets.every(a => a.verification === 'streamed-download'));
  assert.equal(mock.events.filter(e => e.startsWith('download:')).length, 9);
  assert.ok(mock.requests.some(r => r.url.startsWith(SIGNED)));
  assert.ok(!f.logs.join('\n').includes('signature='));
});

test('direct streaming downloads work; corrupt/insecure/second-redirect downloads do not publish', async t => {
  for (const options of [{ directDownload: true }, { downloadMismatch: true }, { httpDownload: true }, { secondRedirect: true }]) {
    await t.test(Object.keys(options)[0], async t => {
      const f = await fixture(t), mock = github({ noDigest: true, ...options });
      const result = await f.run(mock);
      assert.equal(result.ok, !!options.directDownload);
      if (!options.directDownload) { noPublish(mock); assert.equal(mock.release.draft, true); }
    });
  }
});

test('same-size IPA mutation after preflight is detected while streaming upload', async t => {
  const f = await fixture(t), mock = github({ onCreate: () => f.put(ASSET_PATHS[IPA], Buffer.alloc(f.ipa.length, 0x62)) });
  const result = await f.run(mock); assert.equal(result.ok, false); assert.equal(result.boundary, `upload-verify:${IPA}`);
  noPublish(mock); noDelete(mock); assert.equal(mock.release.draft, true);
});

test('secret redaction: never echo transport exceptions, bodies, tokens or signed URLs', async t => {
  const f = await fixture(t), mock = github({ throwUpload: true });
  const result = await f.run(mock);
  const output = [JSON.stringify(result), ...f.logs, await readFile(f.environment.GITHUB_STEP_SUMMARY, 'utf8'),
    await readFile(f.environment.GITHUB_OUTPUT, 'utf8'), mock.release.body].join('\n');
  assert.equal(result.ok, false); assert.ok(!output.includes(SECRET)); assert.ok(!output.includes('signature='));
  assert.match(output, /upload-verify:UIReview.zip/); noPublish(mock);
});

test('authenticated redirects are refused and target host/path cannot be injected', async () => {
  let calls = 0;
  const client = createClient(SECRET, async () => { calls++; return new Response(null, { status: 302, headers: { location: SIGNED } }); });
  await assert.rejects(client.json('/releases')); assert.equal(calls, 1);
  await assert.rejects(client.json('/../../../other/repo/releases')); assert.equal(calls, 1);
});

test('ambiguous publication is re-drafted once; failed rollback is reported unknown, not claimed safe', async t => {
  for (const redraftFails of [false, true]) {
    await t.test(String(redraftFails), async t => {
      const f = await fixture(t), mock = github({ publicationResponseLost: true, redraftFails });
      const result = await f.run(mock); assert.equal(result.ok, false);
      assert.equal(result.release.state, redraftFails ? 'unknown' : 'draft');
      assert.equal(mock.events.filter(e => e === 'publish').length, 1);
      assert.equal(mock.events.filter(e => e === 'retain-draft').length, 1); noDelete(mock);
    });
  }
});

test('missing models or failed/mismatched public reports block success before creation', async t => {
  for (const [name, report] of [
    ['parity-report.json', { schemaVersion: 2, modelVersion: MODEL, passed: false }],
    ['provenance.json', { schemaVersion: 2, modelVersion: `siglip2-b16-224-v1-${'d'.repeat(64)}`, training: false }],
    ['places-manifest.json', { schemaVersion: 1, generated: { file: 'Places.geojson' } }],
  ]) {
    await t.test(name, async t => {
      const f = await fixture(t), mock = github(); await f.putJSON(name, report);
      assert.equal((await f.run(mock)).ok, false); noCreate(mock);
    });
  }
  await t.test('device requires models', async t => {
    const f = await fixture(t), mock = github();
    assert.equal((await f.run(mock, flags('success', true, false))).ok, false); noCreate(mock);
  });
});

test('manifest upload is also mandatory: last upload failure never publishes', async t => {
  const f = await fixture(t), mock = github({ failUploadAt: 9 });
  const result = await f.run(mock); assert.equal(result.ok, false); assert.equal(result.boundary, 'delivery-manifest');
  assert.equal(result.assets.length, 8); noPublish(mock); noDelete(mock);
  await assert.rejects(access(path.join(f.root, 'build/release-evidence/release-delivery.json')));
});

test('early HTTP rejection closes upload streams without consuming the entire input', async t => {
  const f = await fixture(t), { assets } = await collectAssets(f.root, flags());
  let body;
  const client = createClient(SECRET, async (url, init) => { body = init.body; return json({}, 502); });
  await assert.rejects(client.upload(700, assets.find(a => a.name === IPA)));
  assert.equal(body.destroyed, true);
});

test('privacy is checked again immediately before publication', async t => {
  const f = await fixture(t), options = {};
  options.onCreate = async () => { options.public = true; };
  const mock = github(options), result = await f.run(mock);
  assert.equal(result.ok, false); assert.equal(result.boundary, 'pre-publication-identity');
  noPublish(mock); assert.equal(mock.release.draft, true);
});

test('final tag must point at the exact commit; a wrong server result is re-drafted', async t => {
  const f = await fixture(t), mock = github({ publishedTagMismatch: true });
  const result = await f.run(mock);
  assert.equal(result.ok, false); assert.equal(result.release.state, 'draft');
  assert.equal(mock.release.draft, true); assert.equal(mock.events.filter(e => e === 'publish').length, 1);
  noDelete(mock);
});