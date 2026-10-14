import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, createPrivateKey, randomBytes, sign, X509Certificate } from 'node:crypto';
import fs, { createReadStream } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { validateAppResources, validateDeviceSDK } from './check_release.mjs';
import { validatePlaces } from './check_places.mjs';

export const identity = Object.freeze({ bundle: 'app.piankexun.ios', version: '1.0', build: '47' });
export const modelPrecision = 'float16';
export const maxIPABytes = 900 * 1024 * 1024;
const realPhotoApproval = JSON.parse(fs.readFileSync(new URL('./fp16-real-photo-acceptance.json', import.meta.url), 'utf8'));
export const fp16AcceptancePolicy = realPhotoApproval.policy;
const secretNames = ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY', 'APPLE_TEAM_ID',
  'IOS_DISTRIBUTION_P12_BASE64', 'IOS_DISTRIBUTION_P12_PASSWORD', 'IOS_PROVISION_PROFILE_BASE64'];

export function decodeSecret(value, name) {
  assert.equal(typeof value, 'string', `Missing ${name}`);
  const compact = value.replace(/\s/g, '');
  assert.ok(compact.length > 0 && compact.length % 4 === 0
    && /^[A-Za-z0-9+/]*={0,2}$/.test(compact), `Invalid Base64 for ${name}`);
  const bytes = Buffer.from(compact, 'base64');
  assert.ok(bytes.toString('base64') === compact, `Noncanonical Base64 for ${name}`);
  return bytes;
}

export function validateProfile(profile, team, certificateHashes, now = new Date()) {
  assert.match(team, /^[A-Z0-9]{10}$/);
  assert.deepEqual(profile.TeamIdentifier, [team], 'Wrong provisioning team');
  assert.equal(profile.Entitlements?.['application-identifier'], `${team}.${identity.bundle}`);
  assert.equal(profile.Entitlements?.['com.apple.developer.team-identifier'], team);
  assert.equal(profile.Entitlements?.['get-task-allow'], false, 'Development signing is not permitted');
  assert.equal(profile.Entitlements?.['beta-reports-active'], true);
  assert.ok(!Object.hasOwn(profile, 'ProvisionedDevices') && !Object.hasOwn(profile, 'ProvisionsAllDevices'),
    'Ad Hoc and enterprise profiles are not permitted');
  assert.ok(new Date(profile.ExpirationDate) > now, 'Provisioning profile expired');
  assert.match(profile.UUID ?? '', /^[A-Fa-f0-9-]{36}$/);
  assert.ok(Array.isArray(profile.DeveloperCertificates) && profile.DeveloperCertificates.length > 0);
  const hashes = profile.DeveloperCertificates.map(value =>
    new X509Certificate(Buffer.from(value, 'base64')).fingerprint256.replaceAll(':', '').toLowerCase());
  assert.ok(hashes.some(hash => certificateHashes.includes(hash)), 'Profile does not match imported signing identity');
  return profile.UUID;
}

export function validateInfo(info) {
  assert.equal(info.CFBundleIdentifier, identity.bundle);
  assert.equal(info.CFBundleShortVersionString, identity.version);
  assert.equal(info.CFBundleVersion, identity.build);
  assert.equal(info.DTPlatformName, 'iphoneos');
  assert.deepEqual(info.CFBundleSupportedPlatforms, ['iPhoneOS']);
  validateDeviceSDK(info);
}

export function validateModelDelivery(manifest, bytes) {
  assert.equal(manifest.preprocessing?.computePrecision, modelPrecision, 'Expected experimental FP16 models');
  assert.equal(manifest.parity?.precision, modelPrecision);
  assert.equal(manifest.parity?.status, 'passed');
  assert.equal(manifest.parity?.acceptancePolicy, fp16AcceptancePolicy);
  assert.equal(manifest.modelVersion, realPhotoApproval.modelVersion, 'Only the evaluated FP16 model pair is approved');
  assert.match(manifest.modelVersion ?? '', /^siglip2-b16-224-v1-[a-f0-9]{64}$/);
  assert.notEqual(manifest.modelVersion, 'siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b',
    'FP16 must not reuse the FP32 index identity');
  assert.ok(Number.isSafeInteger(bytes) && bytes > 0 && bytes <= maxIPABytes,
    'Experimental FP16 IPA must be at most 900 MiB before upload');
}

export function validateRealPhotoAcceptance(report) {
  assert.equal(report.completed, true, 'Real-photo native comparison must complete');
  assert.equal(report.skipped, false);
  assert.equal(report.test, '-[GeneratedModelParityTests testNativeRealPhotoTopFiveRankingDiagnostics]');
  assert.equal(report.requireModels, true);
  assert.equal(report.resourceGate, 'app-bundle-manifest');
  assert.equal(report.precision, modelPrecision);
  assert.equal(report.acceptancePolicy, fp16AcceptancePolicy);
  for (const name of ['dataset', 'corpusSHA256', 'baselineModelVersion', 'modelVersion']) {
    assert.equal(report[name], realPhotoApproval[name], `Unapproved real-photo identity: ${name}`);
  }
  assert.deepEqual(report.fixtureCounts, { realPhotos: 240, chineseQueries: 48, objectCategories: 24 });
  assert.equal(report.requestedComputeUnits, 'cpuOnly+all');
  assert.equal(report.rankings.length, 96);
  assert.equal(report.relevance.length, 96);
  const configurations = {};
  for (const units of ['MLComputeUnits(rawValue: 0)', 'MLComputeUnits(rawValue: 2)']) {
    const ranks = report.rankings.filter(row => row.computeUnits === units);
    const relevance = report.relevance.filter(row => row.computeUnits === units);
    assert.equal(ranks.length, 48, 'Require all 48 rankings on each compute configuration');
    assert.equal(relevance.length, 48, 'Require all 48 relevance measurements on each compute configuration');
    const rankingByID = new Map(ranks.map(row => [row.queryID, row]));
    const relevanceByID = new Map(relevance.map(row => [row.queryID, row]));
    assert.equal(rankingByID.size, 48);
    assert.equal(relevanceByID.size, 48);
    for (const [id, baselineHits, candidateHits, baselineFirst, candidateFirst,
      baselineNDCG, candidateNDCG, firstChanged, overlap, orderChanged] of realPhotoApproval.outcomes) {
      const rank = rankingByID.get(id);
      const rel = relevanceByID.get(id);
      assert.ok(rank && rel, `Missing approved query ${id} on ${units}`);
      for (const name of ['baselineTop5Relevant', 'candidateTop5Relevant']) {
        assert.ok(Number.isInteger(rel[name]) && rel[name] >= 0 && rel[name] <= 5, `${id}: invalid ${name}`);
      }
      for (const name of ['baselineTop1Relevant', 'candidateTop1Relevant']) assert.equal(typeof rel[name], 'boolean');
      for (const name of ['baselineNDCG5', 'candidateNDCG5']) {
        assert.ok(Number.isFinite(rel[name]) && rel[name] >= 0 && rel[name] <= 1, `${id}: invalid ${name}`);
      }
      assert.ok(Number.isInteger(rel.relevantImageCount) && rel.relevantImageCount >= 8 && rel.relevantImageCount <= 240);
      assert.equal(rel.baselineTop5Relevant, baselineHits, `${id}: FP32 baseline hits changed`);
      assert.equal(rel.baselineTop1Relevant, baselineFirst, `${id}: FP32 baseline first-result relevance changed`);
      assert.ok(Math.abs(rel.baselineNDCG5 - baselineNDCG) <= 1e-10, `${id}: FP32 baseline nDCG changed`);
      assert.ok(rel.candidateTop5Relevant >= candidateHits, `${id}: FP16 top-five relevance regressed`);
      assert.ok(!candidateFirst || rel.candidateTop1Relevant, `${id}: FP16 first-result relevance regressed`);
      assert.ok(rel.candidateNDCG5 + 1e-10 >= candidateNDCG, `${id}: FP16 nDCG regressed`);
      assert.equal(typeof rank.top1Changed, 'boolean');
      assert.equal(typeof rank.orderedTop5Changed, 'boolean');
      assert.ok(Number.isInteger(rank.top5Overlap) && rank.top5Overlap >= 0 && rank.top5Overlap <= 5);
      assert.ok(!rank.top1Changed || firstChanged, `${id}: new first-result ranking drift`);
      assert.ok(rank.top5Overlap >= overlap, `${id}: increased top-five membership drift`);
      assert.ok(!rank.orderedTop5Changed || orderChanged, `${id}: new ordered top-five drift`);
      assert.ok(Number.isFinite(rank.maxScoreError) && rank.maxScoreError >= 0, `${id}: invalid score diagnostic`);
      assert.equal(rank.imageIDs.length, 240);
      assert.equal(new Set(rank.imageIDs).size, 240);
      for (const role of ['baseline', 'candidate']) {
        assert.equal(rank[`${role}Scores`].length, 240);
        assert.ok(rank[`${role}Scores`].every(Number.isFinite));
        const order = rank[`${role}Order`];
        assert.equal(order.length, 240);
        assert.equal(new Set(order).size, 240);
        assert.ok(order.every(id => rank.imageIDs.includes(id)));
      }
    }
    configurations[units] = {
      queries: 48, top1Unchanged: ranks.filter(row => !row.top1Changed).length,
      top5MembershipUnchanged: ranks.filter(row => row.top5Overlap === 5).length,
      orderedTop5Unchanged: ranks.filter(row => !row.orderedTop5Changed).length,
      top5Overlap: ranks.reduce((sum, row) => sum + row.top5Overlap, 0),
      baselineTop5Relevant: relevance.reduce((sum, row) => sum + row.baselineTop5Relevant, 0),
      candidateTop5Relevant: relevance.reduce((sum, row) => sum + row.candidateTop5Relevant, 0),
      baselineTop1Relevant: relevance.filter(row => row.baselineTop1Relevant).length,
      candidateTop1Relevant: relevance.filter(row => row.candidateTop1Relevant).length,
      baselineNDCG5: relevance.reduce((sum, row) => sum + row.baselineNDCG5, 0) / 48,
      candidateNDCG5: relevance.reduce((sum, row) => sum + row.candidateNDCG5, 0) / 48,
    };
  }
  return { policy: fp16AcceptancePolicy, approvedRun: realPhotoApproval.approvedRun,
    dataset: report.dataset, corpusSHA256: report.corpusSHA256, configurations };
}

function readRealPhotoAcceptance() {
  const metadata = fs.readFileSync(path.resolve('build', 'RealPhotoBenchmark', 'manifest.json'));
  assert.equal(createHash('sha256').update(metadata).digest('hex'), realPhotoApproval.manifestSHA256,
    'The real-photo source/license manifest must exactly match the approved corpus');
  const folder = path.resolve('build', 'testflight-native-attachments');
  const reports = [];
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.json')) continue;
    const file = path.join(folder, entry.name);
    const report = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (report.test === '-[GeneratedModelParityTests testNativeRealPhotoTopFiveRankingDiagnostics]') reports.push({ file, report });
  }
  assert.equal(reports.length, 1, 'Require exactly one native real-photo comparison report');
  const output = path.resolve('build', 'testflight-real-photo.json');
  if (fs.existsSync(output)) {
    assert.ok(fs.readFileSync(output).equals(fs.readFileSync(reports[0].file)), 'Retained native evidence changed');
  } else {
    fs.copyFileSync(reports[0].file, output, fs.constants.COPYFILE_EXCL);
  }
  const summary = validateRealPhotoAcceptance(reports[0].report);
  return { ...summary, reportSHA256: createHash('sha256').update(fs.readFileSync(output)).digest('hex') };
}

export function exportOptions(team, uuid) {
  assert.match(team, /^[A-Z0-9]{10}$/);
  assert.match(uuid, /^[A-Fa-f0-9-]{36}$/);
  return { method: 'app-store-connect', destination: 'export', signingStyle: 'manual', teamID: team,
    signingCertificate: 'Apple Distribution', provisioningProfiles: { [identity.bundle]: uuid },
    manageAppVersionAndBuildNumber: false, uploadSymbols: true, stripSwiftSymbols: true };
}

export function archiveArguments(team, uuid, archive) {
  assert.match(team, /^[A-Z0-9]{10}$/);
  assert.match(uuid, /^[A-Fa-f0-9-]{36}$/);
  return ['archive', '-project', 'LocalImageIQ.xcodeproj', '-scheme', 'LocalImageIQ',
    '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', archive,
    '-clonedSourcePackagesDirPath', 'build/SourcePackages', '-disableAutomaticPackageResolution',
    `IMAGEIQ_SIGNING_TEAM=${team}`, `IMAGEIQ_SIGNING_PROFILE=${uuid}`,
    'ARCHS=arm64', 'ENABLE_DEBUG_DYLIB=NO'];
}

export function makeJWT(keyID, issuer, privateKey, now = Math.floor(Date.now() / 1000)) {
  assert.match(keyID, /^[A-Z0-9]{10}$/);
  assert.match(issuer, /^[A-Fa-f0-9-]{36}$/);
  const key = createPrivateKey(privateKey);
  assert.equal(key.asymmetricKeyType, 'ec', 'ASC requires an EC private key');
  assert.equal(key.asymmetricKeyDetails?.namedCurve, 'prime256v1');
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const body = `${encode({ alg: 'ES256', kid: keyID, typ: 'JWT' })}.${encode({
    iss: issuer, iat: now, exp: now + 600, aud: 'appstoreconnect-v1',
  })}`;
  return `${body}.${sign('sha256', Buffer.from(body), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}

function run(command, args, { visible = false, env = process.env } = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', env,
    stdio: visible ? 'inherit' : 'pipe', maxBuffer: 64 * 1024 * 1024 });
  const knownErrors = ['MAC verification failed', 'User interaction is not allowed',
    'The specified item could not be found', 'Unknown format in import', 'No identity found'];
  const diagnostic = knownErrors.find(value => `${result.stderr ?? ''}`.includes(value));
  assert.ok(!result.error && result.status === 0,
    `${command} ${args[0]} failed (exit ${result.status ?? 'unavailable'}); ${diagnostic ?? (visible ? 'see build output' : 'sensitive command output withheld')}`);
  return result.stdout?.trim();
}

function plist(file) {
  return JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', file]));
}

async function appleAPI(suffix, secrets) {
  assert.ok(suffix.startsWith('/v1/'));
  for (let attempt = 0; attempt < 4; attempt++) {
    const response = await fetch(`https://api.appstoreconnect.apple.com${suffix}`, {
      headers: { Authorization: `Bearer ${makeJWT(secrets.ASC_KEY_ID, secrets.ASC_ISSUER_ID, secrets.ASC_PRIVATE_KEY)}` },
      signal: AbortSignal.timeout(60000),
    });
    if (response.ok) return response.json();
    if ([429, 502, 503, 504].includes(response.status) && attempt < 3) {
      await new Promise(resolve => setTimeout(resolve, 10000 * (attempt + 1)));
      continue;
    }
    throw Error(`App Store Connect GET ${suffix.split('?')[0]} returned HTTP ${response.status}; check key access and Apple account agreements.`);
  }
}

async function findApp(secrets) {
  const apps = await appleAPI(`/v1/apps?filter[bundleId]=${identity.bundle}&limit=2`, secrets);
  assert.equal(apps.data?.length, 1, 'Exactly one App Store Connect app must match the approved Bundle ID');
  assert.match(apps.data[0].id, /^\d+$/);
  return apps.data[0].id;
}

async function findBuild(appID, secrets) {
  const data = await appleAPI(`/v1/builds?filter[app]=${appID}&filter[version]=${identity.build}&include=preReleaseVersion&limit=10`, secrets);
  const build = data.data?.find(value => {
    const related = value.relationships?.preReleaseVersion?.data?.id;
    return data.included?.some(version => version.id === related
      && version.type === 'preReleaseVersions' && version.attributes?.version === identity.version
      && version.attributes?.platform === 'IOS');
  });
  return build ?? null;
}

function secretsFromEnvironment() {
  const values = {};
  for (const name of secretNames) {
    assert.ok(process.env[name]?.trim(), `Missing required GitHub Secret ${name}`);
    values[name] = process.env[name];
    delete process.env[name];
  }
  assert.match(values.APPLE_TEAM_ID, /^[A-Z0-9]{10}$/);
  return values;
}

async function main(mode) {
  if (mode === '--ranking-check') {
    console.log(JSON.stringify(readRealPhotoAcceptance()));
    return;
  }
  assert.equal(process.platform, 'darwin', 'Signing and upload require the approved macOS runner');
  assert.equal(process.env.GITHUB_REPOSITORY, 'xwgnick/local-image-iq-ios');
  assert.equal(process.env.GITHUB_REF, 'refs/heads/main', 'Never expose signing secrets to another branch');
  assert.equal(process.env.GITHUB_EVENT_NAME, 'workflow_dispatch');
  const secrets = secretsFromEnvironment();
  const appID = await findApp(secrets);
  const existing = await findBuild(appID, secrets);
  if (mode === '--preflight') {
    assert.equal(existing, null, `Build ${identity.version}/${identity.build} already exists: inspect it instead of uploading again`);
    console.log(`PASS: required Secrets present, API authenticated, approved app record found, build ${identity.version}/${identity.build} unused.`);
    return;
  }
  assert.ok(['--signing-check', '--upload'].includes(mode), 'Expected --preflight, --signing-check or --upload');
  assert.equal(existing, null, 'Build already exists; upload must not be repeated');
  const realPhotoAcceptance = mode === '--upload' ? readRealPhotoAcceptance() : null;
  assert.ok(process.env.RUNNER_TEMP, 'RUNNER_TEMP required');
  const folder = path.join(process.env.RUNNER_TEMP, 'piankexun-signing');
  assert.ok(!fs.existsSync(folder), 'Signing directory already exists');
  fs.mkdirSync(folder, { mode: 0o700 });
  const keychain = path.join(folder, 'distribution.keychain-db');
  const profileFile = path.join(folder, 'distribution.mobileprovision');
  const previousKeychains = run('security', ['list-keychains', '-d', 'user']).split('\n')
    .map(value => value.trim().replace(/^"|"$/g, '')).filter(Boolean);
  let installedProfile;
  let cleanupFailed = false;
  function cleanup(command, args) {
    const result = spawnSync(command, args, { stdio: 'ignore' });
    if (result.error || result.status !== 0) { cleanupFailed = true; console.error(`Credential cleanup failed: ${command}`); }
  }
  try {
    const p12 = path.join(folder, 'distribution.p12');
    fs.writeFileSync(p12, decodeSecret(secrets.IOS_DISTRIBUTION_P12_BASE64, 'IOS_DISTRIBUTION_P12_BASE64'), { mode: 0o600 });
    fs.writeFileSync(profileFile, decodeSecret(secrets.IOS_PROVISION_PROFILE_BASE64, 'IOS_PROVISION_PROFILE_BASE64'), { mode: 0o600 });
    // Keychain import rejects some OpenSSL 3 PBES2 exports despite a valid MAC.
    const openssl = ['/opt/homebrew/opt/openssl@3/bin/openssl', '/usr/local/opt/openssl@3/bin/openssl'].find(fs.existsSync);
    assert.ok(openssl, 'OpenSSL 3 is required to read the verified distribution P12');
    const p12Password = path.join(folder, 'p12-password.txt');
    const pem = path.join(folder, 'distribution.pem');
    const compatibleP12 = path.join(folder, 'keychain-compatible.p12');
    fs.writeFileSync(p12Password, secrets.IOS_DISTRIBUTION_P12_PASSWORD, { mode: 0o600 });
    fs.writeFileSync(pem, '', { mode: 0o600 });
    fs.writeFileSync(compatibleP12, '', { mode: 0o600 });
    run(openssl, ['pkcs12', '-in', p12, '-passin', `file:${p12Password}`, '-noenc', '-out', pem]);
    run(openssl, ['pkcs12', '-export', '-in', pem, '-out', compatibleP12,
      '-passout', `file:${p12Password}`, '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1']);
    const password = randomBytes(32).toString('hex');
    run('security', ['create-keychain', '-p', password, keychain]);
    run('security', ['set-keychain-settings', '-lut', '21600', keychain]);
    run('security', ['unlock-keychain', '-p', password, keychain]);
    run('security', ['import', compatibleP12, '-k', keychain, '-P', secrets.IOS_DISTRIBUTION_P12_PASSWORD,
      '-T', '/usr/bin/codesign', '-T', '/usr/bin/security']);
    run('security', ['set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain]);
    run('security', ['list-keychains', '-d', 'user', '-s', keychain, ...previousKeychains]);
    const identities = run('security', ['find-identity', '-v', '-p', 'codesigning', keychain]);
    assert.match(identities, /"Apple Distribution:/, 'No valid Apple Distribution identity imported');
    const certificates = run('security', ['find-certificate', '-a', '-p', keychain]);
    const hashes = [...certificates.matchAll(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g)]
      .map(match => new X509Certificate(match[0]).fingerprint256.replaceAll(':', '').toLowerCase());
    const profileXML = path.join(folder, 'profile.plist');
    fs.writeFileSync(profileXML, run('security', ['cms', '-D', '-i', profileFile]), { mode: 0o600 });
    const profile = JSON.parse(run('swift', ['scripts/read_signing_profile.swift', profileXML]));
    const uuid = validateProfile(profile, secrets.APPLE_TEAM_ID, hashes);
    const profiles = path.join(os.homedir(), 'Library', 'MobileDevice', 'Provisioning Profiles');
    fs.mkdirSync(profiles, { recursive: true });
    const destination = path.join(profiles, `${uuid}.mobileprovision`);
    assert.ok(!fs.existsSync(destination), 'Refusing to replace an existing provisioning profile');
    fs.copyFileSync(profileFile, destination);
    installedProfile = destination;
    if (mode === '--signing-check') {
      console.log('PASS: macOS imported the encrypted P12 and found a matching App Store profile and valid signing identity.');
      return;
    }
    const archive = path.resolve('build', 'TestFlight.xcarchive');
    const output = path.resolve('build', 'testflight-export');
    assert.ok(!fs.existsSync(archive) && !fs.existsSync(output), 'Refusing to replace existing signed build');
    run('xcodegen', ['generate', '--spec', 'project.testflight.yml'], { visible: true });
    run('xcodebuild', archiveArguments(secrets.APPLE_TEAM_ID, uuid, archive), { visible: true });
    const options = path.join(folder, 'ExportOptions.plist');
    fs.writeFileSync(options, JSON.stringify(exportOptions(secrets.APPLE_TEAM_ID, uuid)), { mode: 0o600 });
    run('plutil', ['-convert', 'xml1', options]);
    run('xcodebuild', ['-exportArchive', '-archivePath', archive, '-exportPath', output,
      '-exportOptionsPlist', options], { visible: true });
    const files = fs.readdirSync(output).filter(name => name.endsWith('.ipa'));
    assert.equal(files.length, 1, 'Expected exactly one signed IPA');
    const ipa = path.join(output, files[0]);
    const unpacked = path.join(folder, 'unpacked');
    run('ditto', ['-x', '-k', ipa, unpacked]);
    const payload = path.join(unpacked, 'Payload');
    const apps = fs.readdirSync(payload).filter(name => name.endsWith('.app'));
    assert.equal(apps.length, 1);
    const app = path.join(payload, apps[0]);
    validateInfo(plist(path.join(app, 'Info.plist')));
    run('codesign', ['--verify', '--deep', '--strict', app]);
    const signedEntitlements = run('codesign', ['-d', '--entitlements', ':-', app]);
    const entitlementFile = path.join(folder, 'signed-entitlements.plist');
    fs.writeFileSync(entitlementFile, signedEntitlements, { mode: 0o600 });
    const entitlements = plist(entitlementFile);
    assert.equal(entitlements['application-identifier'], `${secrets.APPLE_TEAM_ID}.${identity.bundle}`);
    assert.equal(entitlements['com.apple.developer.team-identifier'], secrets.APPLE_TEAM_ID);
    assert.equal(entitlements['get-task-allow'], false);
    assert.ok(fs.readFileSync(path.join(app, 'embedded.mobileprovision')).equals(fs.readFileSync(profileFile)),
      'Exported provisioning profile differs from approved profile');
    assert.equal(run('xcrun', ['lipo', '-archs', path.join(app, 'LocalImageIQ')]), 'arm64');
    validateAppResources(app);
    validatePlaces(app, { appBundle: true });
    const manifestPaths = [app, path.join(app, 'Models'), path.join(app, 'Resources', 'Models')]
      .map(base => path.join(base, 'model-manifest.json')).filter(fs.existsSync);
    assert.equal(manifestPaths.length, 1, 'Expected exactly one bundled model manifest');
    const modelManifest = JSON.parse(fs.readFileSync(manifestPaths[0], 'utf8'));
    validateModelDelivery(modelManifest, fs.statSync(ipa).size);
    assert.ok(!fs.existsSync(path.join(app, 'PlugIns')), 'Test bundles must not ship');
    for (const model of ['ImageEncoder.mlmodelc', 'TextEncoder.mlmodelc']) {
      assert.ok([app, path.join(app, 'Models'), path.join(app, 'Resources', 'Models')]
        .some(base => fs.existsSync(path.join(base, model))), `Missing production model ${model}`);
    }
    const keys = path.join(folder, 'private_keys');
    fs.mkdirSync(keys, { mode: 0o700 });
    const keyPath = path.join(keys, `AuthKey_${secrets.ASC_KEY_ID}.p8`);
    createPrivateKey(secrets.ASC_PRIVATE_KEY);
    fs.writeFileSync(keyPath, secrets.ASC_PRIVATE_KEY, { mode: 0o600 });
    const apiEnv = { ...process.env, API_PRIVATE_KEYS_DIR: keys };
    const apiArgs = ['-f', ipa, '-t', 'ios', '--apiKey', secrets.ASC_KEY_ID, '--apiIssuer', secrets.ASC_ISSUER_ID,
      '--output-format', 'json'];
    function altool(action) {
      const result = spawnSync('xcrun', ['altool', action, ...apiArgs], {
        encoding: 'utf8', env: apiEnv, maxBuffer: 16 * 1024 * 1024,
      });
      if (result.error || result.status !== 0) {
        let messages = [];
        try {
          messages = (JSON.parse(result.stdout)['product-errors'] ?? []).map(item =>
            `${item.code}: ${item.message}`);
        } catch (error) {
          if (!(error instanceof SyntaxError)) throw error;
          messages = ['Apple returned non-JSON diagnostics; check delivery status before any retry.'];
        }
        const safe = messages.join('; ').replace(/-----BEGIN[\s\S]*?-----END[^-]*-----/g, '[redacted]');
        throw Error(`Apple altool ${action} failed (exit ${result.status ?? 'unavailable'}). ${safe || 'No structured product error; inspect Apple delivery status before any retry.'}`);
      }
      console.log(`PASS: Apple altool ${action}`);
    }
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(ipa)) hash.update(chunk);
    const report = { ...identity, modelPrecision, modelVersion: modelManifest.modelVersion,
      acceptancePolicy: modelManifest.parity.acceptancePolicy,
      realPhotoAcceptance,
      baselineBuild: '46', baselineIPABytes: 1422924391,
      sourceSHA: process.env.GITHUB_SHA, appID,
      signed: true, nativeValidation: true, publicStoreSubmission: false,
      bytes: fs.statSync(ipa).size, sha256: hash.digest('hex'),
      uploadAttempted: false, uploadAccepted: false, processingState: 'NOT_UPLOADED' };
    const reportPath = path.resolve('build', 'testflight-delivery.json');
    const save = () => fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
    save();
    altool('--validate-app');
    report.uploadAttempted = true;
    save();
    altool('--upload-app');
    report.uploadAccepted = true;
    report.processingState = 'AWAITING_APPLE_PROCESSING';
    save();
    for (let attempt = 0; attempt < 90; attempt++) {
      const build = await findBuild(appID, secrets);
      if (build) {
        report.appleBuildID = build.id;
        report.processingState = build.attributes.processingState;
        save();
        if (report.processingState === 'VALID') {
          console.log(`PASS: App Store Connect confirms build ${identity.version}/${identity.build} processingState=VALID. No App Review or public release requested.`);
          return;
        }
        assert.ok(!['FAILED', 'INVALID'].includes(report.processingState), 'Apple processing rejected build; see App Store Connect for details');
      }
      await new Promise(resolve => setTimeout(resolve, 20000));
    }
    throw Error('Upload accepted but Apple processing not confirmed within 30 minutes. Inspect existing build; do not upload again.');
  } finally {
    cleanup('security', ['list-keychains', '-d', 'user', '-s', ...previousKeychains]);
    if (fs.existsSync(keychain)) cleanup('security', ['delete-keychain', keychain]);
    if (installedProfile) fs.unlinkSync(installedProfile);
    fs.rmSync(folder, { recursive: true, force: true });
    assert.ok(!cleanupFailed, 'Signing credential cleanup failed');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main(process.argv[2]).catch(error => { console.error(error.message); process.exitCode = 1; });
}
