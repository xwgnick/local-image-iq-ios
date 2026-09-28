// Node 22; no dependencies. Only this approved PRIVATE repository may receive assets.
// Workflow stages public reports/ZIPs in build/release-evidence; see ASSET_PATHS.
// Never retries, overwrites/deletes remote assets, follows authenticated redirects,
// shells out, signs an IPA, or claims native/device validation from export parity.
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { appendFile, lstat, mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPOSITORY = 'xwgnick/local-image-iq-ios';
export const MAX_ASSET_BYTES = 2 * 1024 ** 3; // GitHub requires each asset to be UNDER 2 GiB.
const API = `https://api.github.com/repos/${REPOSITORY}`;
const UPLOADS = `https://uploads.github.com/repos/${REPOSITORY}`;
const WEB = `https://github.com/${REPOSITORY}`;
const EVIDENCE = 'build/release-evidence';
const IPA = 'LocalImageIQ-iphoneos-unsigned.ipa';
const SIM = 'LocalImageIQ-Simulator.zip';
const HEX = /^[a-f0-9]{64}$/;
const MODEL = /^siglip2-b16-224-v1-[a-f0-9]{64}$/;
export const ASSET_PATHS = Object.freeze({
  'UIReview.zip': `${EVIDENCE}/UIReview.zip`,
  'TestResults.xcresult.zip': `${EVIDENCE}/TestResults.xcresult.zip`,
  'parity-report.json': `${EVIDENCE}/parity-report.json`,
  'provenance.json': `${EVIDENCE}/provenance.json`,
  'places-manifest.json': `${EVIDENCE}/places-manifest.json`,
  [IPA]: `build/device/${IPA}`,
  'device-build.json': 'build/device/device-build.json',
  'SHA256SUMS.txt': 'build/device/SHA256SUMS.txt',
  [SIM]: `build/${SIM}`,
});
const requireThat = (condition, code) => { if (!condition) throw new Error(code); };
const idOK = value => Number.isSafeInteger(value) && value > 0;
const contentType = name => name.endsWith('.zip') ? 'application/zip'
  : name.endsWith('.json') ? 'application/json' : 'application/octet-stream';

export function parseArgs(argv) {
  const values = {};
  requireThat(argv.length === 6, 'arguments');
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    requireThat(['--status', '--device', '--models'].includes(key) && !(key in values), 'arguments');
    values[key] = argv[i + 1];
  }
  requireThat(['success', 'failure'].includes(values['--status']) &&
    ['true', 'false'].includes(values['--device']) && ['true', 'false'].includes(values['--models']), 'arguments');
  return { status: values['--status'], device: values['--device'] === 'true', models: values['--models'] === 'true' };
}

export function validateEnvironment(env) {
  requireThat(env.GITHUB_REPOSITORY === REPOSITORY && env.GITHUB_SERVER_URL === 'https://github.com', 'repository');
  requireThat(/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? ''), 'commit');
  for (const key of ['GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'])
    requireThat(/^[1-9][0-9]*$/.test(env[key] ?? ''), 'run');
  requireThat(typeof env.GITHUB_TOKEN === 'string' && /^\S+$/.test(env.GITHUB_TOKEN), 'token');
  return { sha: env.GITHUB_SHA, id: env.GITHUB_RUN_ID, attempt: env.GITHUB_RUN_ATTEMPT,
    tag: `ci-${env.GITHUB_RUN_ID}-${env.GITHUB_RUN_ATTEMPT}`,
    url: `${WEB}/actions/runs/${env.GITHUB_RUN_ID}/attempts/${env.GITHUB_RUN_ATTEMPT}` };
}

export function validateAssetSize(bytes) {
  requireThat(Number.isSafeInteger(bytes) && bytes > 0 && bytes < MAX_ASSET_BYTES, 'asset-size');
  return bytes;
}

export async function hashStream(stream) {
  const hash = createHash('sha256');
  let bytes = 0;
  for await (const chunk of stream) { bytes += chunk.length; hash.update(chunk); }
  return { bytes, sha256: hash.digest('hex') };
}

export async function readExpectedAppIdentity(root) {
  const project = await readFile(path.join(root, 'project.yml'), 'utf8');
  const setting = key => {
    // The project uses quoted scalars. Count exact keys before parsing so a
    // duplicate cannot be hidden by giving its value a different format.
    const matches = [...project.matchAll(new RegExp(`^[ \\t]*${key}:[ \\t]*([^\\r\\n]*)\\r?$`, 'gm'))];
    requireThat(matches.length === 1, 'project-identity');
    const value = /^"([^"\r\n]+)"[ \t]*$/.exec(matches[0][1]);
    requireThat(value !== null, 'project-identity');
    return value[1];
  };
  return { appVersion: setting('MARKETING_VERSION'), appBuild: setting('CURRENT_PROJECT_VERSION') };
}

async function inspectFile(root, relative, required) {
  const file = path.join(root, relative);
  let info;
  try { info = await lstat(file); } catch (error) {
    if (error.code === 'ENOENT' && !required) return null;
    throw new Error('missing-file');
  }
  requireThat(info.isFile() && await realpath(file) === file, 'regular-file-only');
  if (!required && info.size === 0) return null; // No usable failure evidence yet.
  validateAssetSize(info.size);
  const fingerprint = await hashStream(createReadStream(file));
  requireThat(fingerprint.bytes === info.size, 'changed-file');
  return { name: path.basename(relative), file, ...fingerprint };
}

export async function collectAssets(root, flags) {
  root = await realpath(root);
  const success = flags.status === 'success';
  const names = ['UIReview.zip', 'TestResults.xcresult.zip', 'places-manifest.json'];
  if (flags.models) names.push('parity-report.json', 'provenance.json');
  if (success) names.push(...(flags.device ? [IPA, 'device-build.json', 'SHA256SUMS.txt'] : [SIM]));
  const assets = [];
  for (const name of names) {
    const asset = await inspectFile(root, ASSET_PATHS[name], success);
    if (asset) assets.push(asset);
  }
  const byName = name => assets.find(asset => asset.name === name);
  // Parse exactly the bytes previously fingerprinted; never use arbitrary report fields as paths.
  const json = async name => {
    const asset = byName(name), data = await readFile(asset.file);
    requireThat(data.length === asset.bytes && createHash('sha256').update(data).digest('hex') === asset.sha256, 'changed-report');
    return JSON.parse(data.toString('utf8'));
  };
  const metadata = { deviceReport: null, model: { requested: flags.models,
    reportsIncluded: ['parity-report.json', 'provenance.json'].filter(name => byName(name)),
    version: null, exportParityPassed: null }, places: null };
  // Failure evidence may include incomplete JSON; do not claim it passed any gate.
  if (!success) return { assets, metadata };
  requireThat(!flags.device || flags.models, 'device-requires-models');
  const places = await json('places-manifest.json');
  requireThat(places.schemaVersion === 1 && places.generated?.file === 'Places.geojson' &&
    HEX.test(places.generated.sha256) && idOK(places.generated.bytes) && idOK(places.generated.featureCount), 'places-report');
  metadata.places = { file: 'Places.geojson', bytes: places.generated.bytes, sha256: places.generated.sha256,
    featureCount: places.generated.featureCount, manifestSHA256: byName('places-manifest.json').sha256 };
  if (flags.models) {
    const parity = await json('parity-report.json'), provenance = await json('provenance.json');
    requireThat(parity.schemaVersion === 2 && parity.passed === true && MODEL.test(parity.modelVersion) &&
      provenance.schemaVersion === 2 && provenance.modelVersion === parity.modelVersion && provenance.training === false, 'model-reports');
    metadata.model.version = parity.modelVersion;
    metadata.model.exportParityPassed = true;
  }
  if (flags.device) {
    const report = await json('device-build.json'), ipa = byName(IPA);
    validateDeviceReport(report, ipa, metadata, await readExpectedAppIdentity(root));
    const sums = await readFile(byName('SHA256SUMS.txt').file, 'utf8');
    requireThat(sums.trim() === `${ipa.sha256}  ${IPA}`, 'checksum-report');
    // Deliberately not a copy of free-form diagnostic/nextStep strings.
    metadata.deviceReport = Object.fromEntries(['platform', 'architectures', 'configuration', 'signed',
      'installableWithoutResigning', 'deviceTested', 'appVersion', 'appBuild', 'bundleIdentifier',
      'modelVersion', 'modelDimension', 'ipa', 'bytes', 'sha256'].map(key => [key, report[key]]));
  }
  return { assets, metadata };
}

export function validateDeviceReport(report, ipa, metadata, expectedIdentity) {
  requireThat(report.platform === 'iphoneos' && JSON.stringify(report.architectures) === '["arm64"]' &&
    report.configuration === 'Release' && report.signed === false && report.installableWithoutResigning === false &&
    report.deviceTested === false && report.appVersion === expectedIdentity.appVersion && report.appBuild === expectedIdentity.appBuild &&
    report.bundleIdentifier === 'com.example.localimageiq' && report.modelDimension === 768 &&
    report.modelVersion === metadata.model.version && report.ipa === IPA &&
    report.bytes === ipa.bytes && report.sha256 === ipa.sha256 &&
    report.places?.sha256 === metadata.places.sha256 && report.places?.bytes === metadata.places.bytes &&
    report.places?.featureCount === metadata.places.featureCount &&
    report.places?.manifestSHA256 === metadata.places.manifestSHA256, 'device-identity');
}

async function discard(response) { try { await response.body?.cancel(); } catch { /* No body/error text is logged. */ } }

// Only API/upload requests carry credentials. URLs are constructed locally, never from API links.
export function createClient(token, transport = globalThis.fetch) {
  async function request(url, options = {}) {
    const target = new URL(url);
    requireThat(target.protocol === 'https:' && ['api.github.com', 'uploads.github.com'].includes(target.host) &&
      !target.username && !target.password && !target.hash &&
      (target.pathname === `/repos/${REPOSITORY}` || target.pathname.startsWith(`/repos/${REPOSITORY}/`)), 'request-target');
    return transport(url, { ...options, redirect: 'manual', headers: {
      Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'local-image-iq-private-ci', ...options.headers, Authorization: `Bearer ${token}`,
    } });
  }
  async function json(route, { method = 'GET', body, missing = false } = {}) {
    const response = await request(`${API}${route}`, { method,
      ...(body === undefined ? {} : { body: JSON.stringify(body), headers: { 'Content-Type': 'application/json' } }) });
    if (response.status === 404 && missing) { await discard(response); return null; }
    if (!response.ok) { await discard(response); throw new Error('api-response'); }
    try { return await response.json(); } finally { await discard(response); }
  }
  async function download(assetID) {
    let response = await request(`${API}/releases/assets/${assetID}`, { headers: { Accept: 'application/octet-stream' } });
    if (response.status === 302) {
      const location = response.headers.get('location');
      await discard(response);
      const target = new URL(location);
      // A GitHub-issued signed download URL is the sole non-API exception: HTTPS, no auth, no further redirects.
      requireThat(target.protocol === 'https:' && !target.username && !target.password && !target.hash, 'download-target');
      response = await transport(target.href, { redirect: 'manual', method: 'GET', headers: { 'Accept-Encoding': 'identity' } });
    }
    if (response.status !== 200 || !response.body) { await discard(response); throw new Error('download-response'); }
    try { return await hashStream(response.body); } finally { await discard(response); }
  }
  async function upload(releaseID, asset) {
    validateAssetSize(asset.bytes);
    const hash = createHash('sha256');
    let bytes = 0;
    const body = new Transform({ transform(chunk, encoding, callback) {
      bytes += chunk.length;
      if (bytes > asset.bytes) return callback(new Error('changed-upload'));
      hash.update(chunk); callback(null, chunk);
    } });
    const source = createReadStream(asset.file);
    const pumping = pipeline(source, body);
    pumping.catch(() => {}); // An early HTTP failure must not create an unhandled stream rejection.
    let response;
    try {
      response = await request(`${UPLOADS}/releases/${releaseID}/assets?name=${encodeURIComponent(asset.name)}`, {
        method: 'POST', body, duplex: 'half', headers: {
          'Content-Type': contentType(asset.name), 'Content-Length': String(asset.bytes),
        },
      });
      requireThat(response.status === 201, 'upload-response');
      const uploaded = await response.json();
      await pumping;
      requireThat(bytes === asset.bytes && hash.digest('hex') === asset.sha256, 'changed-upload');
      checkAsset(uploaded, asset);
      const remote = await json(`/releases/assets/${uploaded.id}`);
      checkAsset(remote, asset);
      requireThat(remote.id === uploaded.id, 'asset-id');
      const verification = remote.digest ? 'api-sha256' : 'streamed-download';
      if (!remote.digest) {
        const actual = await download(remote.id);
        requireThat(actual.bytes === asset.bytes && actual.sha256 === asset.sha256, 'download-hash');
      }
      return { name: asset.name, bytes: asset.bytes, sha256: asset.sha256, id: remote.id, state: 'uploaded', verification };
    } finally {
      source.destroy(); body.destroy(); await pumping.catch(() => {});
      if (response) await discard(response);
    }
  }
  return { json, upload };
}

function checkAsset(remote, asset) {
  requireThat(idOK(remote.id) && remote.state === 'uploaded' && remote.name === asset.name && remote.size === asset.bytes, 'asset-metadata');
  if (remote.digest != null && remote.digest !== '')
    requireThat(remote.digest === `sha256:${asset.sha256}`, 'asset-digest');
}

async function checkIdentity(client, run) {
  const repo = await client.json('');
  requireThat(repo.full_name === REPOSITORY && repo.private === true, 'private-repository');
  const commit = await client.json(`/commits/${run.sha}`);
  requireThat(commit.sha === run.sha, 'commit-identity');
  const actual = await client.json(`/actions/runs/${run.id}`);
  requireThat(String(actual.id) === run.id && String(actual.run_attempt) === run.attempt &&
    actual.head_sha === run.sha && actual.repository?.full_name === REPOSITORY, 'run-identity');
  // status=in_progress is normal; the runs API does not expose workflow_dispatch inputs.
}

async function checkCollisions(client, run, ownID = null) {
  requireThat(await client.json(`/git/ref/tags/${run.tag}`, { missing: true }) === null, 'tag-collision');
  const existing = await client.json(`/releases/tags/${run.tag}`, { missing: true });
  requireThat(existing === null || existing.id === ownID, 'release-collision');
  // Include drafts even when the by-tag endpoint does not return unpublished releases.
  for (let page = 1; ; page++) {
    const releases = await client.json(`/releases?per_page=100&page=${page}`);
    requireThat(Array.isArray(releases), 'release-list');
    requireThat(!releases.some(item => item.tag_name === run.tag && item.id !== ownID), 'release-collision');
    if (releases.length < 100) break;
  }
}

function checkRelease(release, run, id, draft) {
  requireThat(release.id === id && release.tag_name === run.tag && release.target_commitish === run.sha &&
    release.draft === draft && release.prerelease === true, 'release-identity');
}

function draftURL(release) {
  const url = new URL(release.html_url);
  requireThat(url.origin === 'https://github.com' && !url.username && !url.password && !url.search && !url.hash &&
    url.pathname.startsWith(`/${REPOSITORY}/releases/`) && /^[A-Za-z0-9_./-]+$/.test(url.pathname), 'release-url');
  return url.href;
}

function description(run, flags, boundary) {
  return `Private CI delivery: ${flags.status}; device=${flags.device}; models=${flags.models}.\n` +
    `Run: ${run.url}\nCommit: ${run.sha}\nError/validation boundary: ${boundary}.\n` +
    'Unsigned builds require local re-signing. No Apple credentials, private photos, physical-device validation, ' +
    'or public redistribution approval are supplied by this delivery. Failure evidence remains DRAFT; inspect the run for upstream errors.';
}

async function writeJSON(root, name, data) {
  const directory = path.join(root, EVIDENCE);
  await mkdir(directory, { recursive: true });
  requireThat(await realpath(directory) === directory, 'output-directory');
  const file = path.join(directory, name);
  try { requireThat((await lstat(file)).isFile() && await realpath(file) === file, 'output-file'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  await writeFile(file, `${JSON.stringify(data, null, 2)}\n`);
  return inspectFile(root, `${EVIDENCE}/${name}`, true);
}

async function announce(result, env, log) {
  // Only constructed identifiers/statuses; NEVER error.message, response bodies, tokens or signed URLs.
  const text = `Private CI delivery: ${result.outcome}; boundary=${result.boundary}; ` +
    `verifiedAssets=${result.assets?.length ?? 0}` + (result.release ?
      `; releaseID=${result.release.id}; tag=${result.release.tag}; state=${result.release.state}; ${result.release.url}` : '; no release recorded');
  log(text);
  try {
    if (env.GITHUB_STEP_SUMMARY) await appendFile(env.GITHUB_STEP_SUMMARY, `### Private CI release delivery\n${text}\n` +
      (result.assets ?? []).map(a => `- ${a.name}: id=${a.id}, ${a.bytes} bytes, SHA256=${a.sha256}, ${a.verification}\n`).join(''));
    if (env.GITHUB_OUTPUT) await appendFile(env.GITHUB_OUTPUT, `delivery_status=${result.outcome}\n` +
      `release_id=${result.release?.id ?? ''}\nrelease_tag=${result.release?.tag ?? ''}\nrelease_url=${result.release?.url ?? ''}\n`);
  } catch { log('Delivery summary/output unavailable; see the sanitized delivery status above.'); }
}

export async function main({ argv = process.argv.slice(2), env = process.env,
  root = fileURLToPath(new URL('../', import.meta.url)), transport = globalThis.fetch, log = console.log } = {}) {
  let boundary = 'configuration', client, run, flags, release = null, createdDraftURL;
  const verified = [];
  try {
    flags = parseArgs(argv); run = validateEnvironment(env); root = await realpath(root);
    boundary = 'local-evidence';
    const { assets, metadata } = await collectAssets(root, flags);
    client = createClient(env.GITHUB_TOKEN, transport);
    boundary = 'repository-commit-run'; await checkIdentity(client, run);
    if (!assets.length) {
      const result = { ok: true, outcome: 'skipped-no-failure-evidence', boundary: 'upstream-workflow', assets: [] };
      await announce(result, env, log); return result;
    }
    boundary = 'collision-check'; await checkCollisions(client, run);
    boundary = 'draft-creation';
    const draft = await client.json('/releases', { method: 'POST', body: {
      tag_name: run.tag, target_commitish: run.sha, draft: true, prerelease: true, make_latest: 'false',
      name: `DRAFT ${run.tag} ${flags.status.toUpperCase()} — delivery pending`,
      body: description(run, flags, flags.status === 'failure' ? 'upstream-workflow; evidence verification pending' : 'delivery verification pending'),
    } });
    requireThat(idOK(draft.id), 'release-id');
    release = { id: draft.id, tag: run.tag, url: `${WEB}/releases`, state: 'draft' };
    checkRelease(draft, run, release.id, true);
    createdDraftURL = draftURL(draft); release.url = createdDraftURL;
    for (const asset of assets) {
      boundary = `upload-verify:${asset.name}`;
      verified.push(await client.upload(release.id, asset));
    }
    boundary = 'delivery-manifest';
    const manifest = { schemaVersion: 1, repository: REPOSITORY, run, ...flags, ...metadata,
      release: { id: release.id, tag: run.tag, url: release.url },
      validationBoundary: 'Payload assets verified; this manifest and final release state are verified separately.',
      assets: [...verified] }; // delivery.json intentionally excludes itself.
    const manifestAsset = await writeJSON(root, 'delivery.json', manifest);
    verified.push(await client.upload(release.id, manifestAsset));
    boundary = 'final-draft-verification';
    checkRelease(await client.json(`/releases/${release.id}`), run, release.id, true);
    if (flags.status === 'success') {
      boundary = 'pre-publication-identity';
      await checkIdentity(client, run); await checkCollisions(client, run, release.id);
      boundary = 'publication'; release.state = 'unknown';
      const published = await client.json(`/releases/${release.id}`, { method: 'PATCH', body: {
        tag_name: run.tag, target_commitish: run.sha,
        draft: false, prerelease: true, make_latest: 'false', name: `CI ${run.tag} SUCCESS`,
        body: description(run, flags, 'all delivery assets verified; upstream status supplied by workflow'),
      } });
      checkRelease(published, run, release.id, false);
      const tag = await client.json(`/git/ref/tags/${run.tag}`);
      requireThat(tag.object?.type === 'commit' && tag.object.sha === run.sha, 'published-tag');
      release.state = 'published-prerelease'; release.url = `${WEB}/releases/tag/${run.tag}`;
    } else {
      boundary = 'failure-draft-status';
      checkRelease(await client.json(`/releases/${release.id}`, { method: 'PATCH', body: {
        tag_name: run.tag, target_commitish: run.sha,
        draft: true, prerelease: true, make_latest: 'false', name: `DRAFT ${run.tag} FAILURE — evidence verified`,
        body: description(run, flags, 'upstream-workflow; available delivery evidence verified'),
      } }), run, release.id, true);
    }
    boundary = 'local-delivery-record';
    const result = { ...manifest, ok: true, outcome: flags.status === 'success' ? 'published-prerelease' : 'failure-evidence-draft',
      boundary: flags.status === 'success' ? 'verified-delivery-not-device-testing' : 'upstream-workflow', release, assets: verified };
    await writeJSON(root, 'release-delivery.json', result);
    await announce(result, env, log); return result;
  } catch {
    if (release && client) {
      // Only OUR created release; one status update, never asset retry, delete or replacement.
      // A failed publication response is ambiguous until this re-draft is confirmed.
      try {
        const retained = await client.json(`/releases/${release.id}`, { method: 'PATCH', body: {
          tag_name: run.tag, target_commitish: run.sha,
          draft: true, prerelease: true, make_latest: 'false', name: `DRAFT ${run.tag} FAILURE — delivery incomplete`,
          body: description(run, { ...flags, status: 'failure' }, boundary),
        } });
        checkRelease(retained, run, release.id, true); release.state = 'draft';
        createdDraftURL = draftURL(retained);
      } catch { release.state = 'unknown'; /* Re-draft could not be confirmed; never claim it succeeded. */ }
      release.url = release.state === 'unknown' ? `${WEB}/releases` : (createdDraftURL ?? `${WEB}/releases`);
    }
    const result = { ok: false, outcome: 'delivery-failed', boundary, release, assets: verified };
    await announce(result, env, log); return result;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await main();
  if (!result.ok) process.exitCode = 1;
}