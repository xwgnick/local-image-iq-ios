import assert from 'node:assert/strict';
import { generateKeyPairSync, verify, X509Certificate } from 'node:crypto';
import { rootCertificates } from 'node:tls';
import fs from 'node:fs';
import test from 'node:test';
import { archiveArguments, decodeSecret, exportOptions, fp16AcceptancePolicy, identity, makeJWT, maxIPABytes, modelPrecision,
  validateInfo, validateModelDelivery, validateProfile, validateRealPhotoAcceptance } from './testflight.mjs';

const photoApproval = JSON.parse(fs.readFileSync(new URL('./fp16-real-photo-acceptance.json', import.meta.url), 'utf8'));

function approvedPhotoReport() {
  const report = {
    completed: true, skipped: false,
    test: '-[GeneratedModelParityTests testNativeRealPhotoTopFiveRankingDiagnostics]',
    requireModels: true, resourceGate: 'app-bundle-manifest', precision: 'float16',
    acceptancePolicy: fp16AcceptancePolicy, dataset: photoApproval.dataset,
    corpusSHA256: photoApproval.corpusSHA256, modelVersion: photoApproval.modelVersion,
    baselineModelVersion: photoApproval.baselineModelVersion, requestedComputeUnits: 'cpuOnly+all',
    fixtureCounts: { realPhotos: 240, chineseQueries: 48, objectCategories: 24 },
    rankings: [], relevance: [],
  };
  const ids = Array.from({ length: 240 }, (_, index) => String(index));
  for (const computeUnits of ['MLComputeUnits(rawValue: 0)', 'MLComputeUnits(rawValue: 2)']) {
    for (const values of photoApproval.outcomes) {
      const row = Object.fromEntries(photoApproval.columns.map((name, index) => [name, values[index]]));
      report.relevance.push({ ...row, computeUnits, relevantImageCount: 8 });
      report.rankings.push({ ...row, computeUnits, imageIDs: ids, baselineOrder: ids, candidateOrder: ids,
        baselineScores: ids.map(() => 0), candidateScores: ids.map(() => 0), maxScoreError: 0 });
    }
  }
  return report;
}

test('real-photo acceptance replays every approved query on CPU and all compute units', () => {
  const report = approvedPhotoReport();
  const result = validateRealPhotoAcceptance(report);
  assert.equal(result.approvedRun, '38606281528');
  assert.equal(result.policy, 'fp16-real-photo-experiment-v2');
  for (const summary of Object.values(result.configurations)) {
    assert.equal(summary.top1Unchanged, 39);
    assert.equal(summary.top5MembershipUnchanged, 28);
    assert.equal(summary.orderedTop5Unchanged, 14);
    assert.equal(summary.top5Overlap, 215);
    assert.equal(summary.baselineTop5Relevant, 193);
    assert.equal(summary.candidateTop5Relevant, 196);
    assert.equal(summary.baselineTop1Relevant, 41);
    assert.equal(summary.candidateTop1Relevant, 40);
    assert.ok(Math.abs(summary.candidateNDCG5 - 0.8239985362541576) < 1e-10);
  }
  report.relevance[0].candidateNDCG5 = 0.99;
  assert.throws(() => validateRealPhotoAcceptance(report), /FP16 nDCG regressed/);
});

test('real-photo acceptance rejects skipped, partial, changed-identity and worse per-query results', () => {
  const mutations = [
    report => { report.completed = false; },
    report => { report.skipped = true; },
    report => { report.acceptancePolicy = 'fp16-normalized-experiment-v1'; },
    report => { report.modelVersion = photoApproval.baselineModelVersion; },
    report => { report.corpusSHA256 = 'a'.repeat(64); },
    report => { report.fixtureCounts.realPhotos = 239; },
    report => { report.rankings.pop(); },
    report => { report.relevance[0].queryID = 'unapproved'; },
    report => { report.rankings[48].computeUnits = report.rankings[0].computeUnits; },
    report => { report.relevance[0].baselineTop5Relevant = 4; },
    report => { report.relevance[0].candidateTop5Relevant = 4; },
    report => { report.relevance[0].candidateTop1Relevant = false; },
    report => { report.relevance[0].candidateNDCG5 = NaN; },
    report => { report.relevance[0].candidateNDCG5 = 1.01; },
    report => { report.rankings[0].top1Changed = true; },
    report => { report.rankings[0].top5Overlap = 3; },
    report => { report.rankings[4].orderedTop5Changed = true; },
    report => { report.rankings[0].candidateScores = [NaN]; },
    report => { report.rankings[0].candidateOrder = ['unknown']; },
  ];
  for (const mutate of mutations) {
    const report = approvedPhotoReport();
    mutate(report);
    assert.throws(() => validateRealPhotoAcceptance(report));
  }
});

test('FP16 experiment is isolated from FP32 build46 and unsigned development delivery', () => {
  assert.deepEqual(identity, { bundle: 'app.piankexun.ios', version: '1.0', build: '47' });
  const project = fs.readFileSync(new URL('../project.yml', import.meta.url), 'utf8');
  assert.ok(project.includes('PRODUCT_BUNDLE_IDENTIFIER: com.example.localimageiq'));
  assert.ok(project.includes('MARKETING_VERSION: "0.16.5"'));
});

test('Base64 credentials are mandatory and reject paths, truncated and noncanonical input', () => {
  assert.deepEqual(decodeSecret('aGVs\nbG8=', 'fixture'), Buffer.from('hello'));
  for (const value of ['', undefined, 'C:\\keys\\key.p12', 'not base64', 'aGVsbG8', 'a===', 'Zh==']) {
    assert.throws(() => decodeSecret(value, 'fixture'));
  }
});

test('archive export cannot change version, use automatic signing or public upload destination', () => {
  const uuid = 'A0000000-0000-0000-0000-000000000000';
  assert.deepEqual(exportOptions('TESTTEAM01', uuid), {
    method: 'app-store-connect', destination: 'export', signingStyle: 'manual', teamID: 'TESTTEAM01',
    signingCertificate: 'Apple Distribution', provisioningProfiles: { 'app.piankexun.ios': uuid },
    manageAppVersionAndBuildNumber: false, uploadSymbols: true, stripSwiftSymbols: true,
  });
  assert.throws(() => exportOptions('bad', uuid));
  assert.throws(() => exportOptions('TESTTEAM01', '../profile'));
});

test('archive signing and official identity are scoped to the application, not Swift package resources', () => {
  const uuid = 'A0000000-0000-0000-0000-000000000000';
  const args = archiveArguments('TESTTEAM01', uuid, 'build/TestFlight.xcarchive');
  assert.ok(args.includes('IMAGEIQ_SIGNING_TEAM=TESTTEAM01'));
  assert.ok(args.includes(`IMAGEIQ_SIGNING_PROFILE=${uuid}`));
  assert.ok(!args.some(value => /^(PROVISIONING_PROFILE_SPECIFIER|CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER|MARKETING_VERSION|CURRENT_PROJECT_VERSION)=/.test(value)));
  const spec = fs.readFileSync(new URL('../project.testflight.yml', import.meta.url), 'utf8').replaceAll('\r\n', '\n');
  assert.ok(spec.startsWith('include:\n  - project.models.yml\n'));
  assert.deepEqual([...spec.matchAll(/^  ([A-Za-z0-9_-]+):$/gm)].map(match => match[1]), ['LocalImageIQ']);
  assert.ok(spec.includes(`PRODUCT_BUNDLE_IDENTIFIER: ${identity.bundle}`));
  assert.ok(spec.includes(`MARKETING_VERSION: "${identity.version}"`));
  assert.ok(spec.includes(`CURRENT_PROJECT_VERSION: "${identity.build}"`));
  assert.ok(spec.includes('DEVELOPMENT_TEAM: "$(IMAGEIQ_SIGNING_TEAM)"'));
  assert.ok(spec.includes('PROVISIONING_PROFILE_SPECIFIER: "$(IMAGEIQ_SIGNING_PROFILE)"'));
  assert.ok(spec.includes('CODE_SIGN_STYLE: Manual'));
  assert.ok(spec.includes('CODE_SIGN_IDENTITY: Apple Distribution'));
  assert.throws(() => archiveArguments('bad', uuid, 'archive'));
  assert.throws(() => archiveArguments('TESTTEAM01', '../profile', 'archive'));
});

test('exported device IPA identity and SDK must match the approved official build', () => {
  const info = { CFBundleIdentifier: identity.bundle, CFBundleShortVersionString: '1.0',
    CFBundleVersion: '47', DTPlatformName: 'iphoneos', CFBundleSupportedPlatforms: ['iPhoneOS'],
    DTSDKName: 'iphoneos26.2', DTXcode: '2630', MinimumOSVersion: '17.0' };
  validateInfo(info);
  for (const override of [{ CFBundleIdentifier: 'com.example.localimageiq' }, { CFBundleVersion: '46' },
    { CFBundleShortVersionString: '0.16.5' }, { DTPlatformName: 'iphonesimulator' }, { DTSDKName: 'iphoneos18.5' }]) {
    assert.throws(() => validateInfo({ ...info, ...override }));
  }
});

test('FP16 delivery must change model identity and meet the actual IPA byte ceiling', () => {
  assert.equal(modelPrecision, 'float16');
  const manifest = { modelVersion: photoApproval.modelVersion,
    preprocessing: { computePrecision: 'float16' }, parity: { precision: 'float16', status: 'passed',
      acceptancePolicy: fp16AcceptancePolicy } };
  validateModelDelivery(manifest, maxIPABytes);
  for (const bytes of [0, -1, NaN, Infinity, 1.5, maxIPABytes + 1]) {
    assert.throws(() => validateModelDelivery(manifest, bytes));
  }
  for (const override of [{ preprocessing: { computePrecision: 'float32' } },
    { parity: { precision: 'float16', status: 'failed' } },
    { parity: { precision: 'float16', status: 'passed', acceptancePolicy: 'fp16-normalized-experiment-v1' } },
    { modelVersion: `siglip2-b16-224-v1-${'a'.repeat(64)}` },
    { modelVersion: 'siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b' }]) {
    assert.throws(() => validateModelDelivery({ ...manifest, ...override }, 700 * 1024 * 1024));
  }
  const workflow = fs.readFileSync(new URL('../.github/workflows/testflight.yml', import.meta.url), 'utf8');
  assert.ok(workflow.includes('export_models.py --download --precision float16'));
});

test('TestFlight reruns real-photo acceptance with test-only FP32 models before signing', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/testflight.yml', import.meta.url), 'utf8').replaceAll('\r\n', '\n');
  assert.ok(workflow.includes('export_models.py --download --precision float32 --output build/FP32Models'));
  assert.ok(workflow.includes('python scripts/prepare_real_photo_benchmark.py\n'));
  assert.ok(workflow.includes('xcodegen generate --spec project.real-photo-diagnostic.yml'));
  assert.ok(workflow.includes('xcresulttool export attachments'));
  assert.ok(workflow.includes('build/testflight-native-attachments'));
  assert.ok(workflow.includes('build/testflight-real-photo.json'));
  assert.ok(workflow.includes('build/RealPhotoBenchmark/manifest.json'));
  const source = fs.readFileSync(new URL('./testflight.mjs', import.meta.url), 'utf8');
  assert.ok(source.indexOf("mode === '--upload' ? readRealPhotoAcceptance()") < source.indexOf("run('xcodebuild', archiveArguments"));
  assert.ok(source.includes("xcodegen', ['generate', '--spec', 'project.testflight.yml'"));
  assert.ok(!workflow.includes('path: build/RealPhotoBenchmark\n'));
});

test('profile rejects wrong team, wildcard ID, debug, Ad Hoc, enterprise and expired signing', () => {
  const profile = { TeamIdentifier: ['TESTTEAM01'], UUID: 'A0000000-0000-0000-0000-000000000000',
    ExpirationDate: '2099-01-01T00:00:00Z', DeveloperCertificates: [],
    Entitlements: { 'application-identifier': 'TESTTEAM01.app.piankexun.ios',
      'com.apple.developer.team-identifier': 'TESTTEAM01', 'get-task-allow': false, 'beta-reports-active': true } };
  for (const override of [{ TeamIdentifier: ['WRONGTEAM1'] }, { ProvisionedDevices: [] },
    { ProvisionsAllDevices: false }, { ExpirationDate: '2000-01-01' },
    { Entitlements: { ...profile.Entitlements, 'get-task-allow': true } },
    { Entitlements: { ...profile.Entitlements, 'application-identifier': 'TESTTEAM01.*' } },
    { Entitlements: { ...profile.Entitlements, 'beta-reports-active': false } }, {}]) {
    assert.throws(() => validateProfile({ ...profile, ...override }, 'TESTTEAM01', []));
  }
});

test('matching synthetic profile accepts dates and certificate bytes from Foundation decoding', () => {
  const cert = new X509Certificate(rootCertificates[0]);
  const profile = { TeamIdentifier: ['TESTTEAM01'], UUID: 'A0000000-0000-0000-0000-000000000000',
    ExpirationDate: '2099-01-01T00:00:00Z', DeveloperCertificates: [cert.raw.toString('base64')],
    Entitlements: { 'application-identifier': 'TESTTEAM01.app.piankexun.ios',
      'com.apple.developer.team-identifier': 'TESTTEAM01', 'get-task-allow': false, 'beta-reports-active': true } };
  assert.equal(validateProfile(profile, 'TESTTEAM01', [cert.fingerprint256.replaceAll(':', '').toLowerCase()]), profile.UUID);
  assert.throws(() => validateProfile(profile, 'TESTTEAM01', ['wrong-certificate']));
});

test('ASC JWT uses P256 ES256 P1363 signatures and short-lived Apple audience', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const token = makeJWT('TESTKEY001', 'A0000000-0000-0000-0000-000000000000', pem, 1700000000);
  const [header, payload, signature] = token.split('.');
  assert.equal(JSON.parse(Buffer.from(header, 'base64url')).alg, 'ES256');
  const claims = JSON.parse(Buffer.from(payload, 'base64url'));
  assert.equal(claims.aud, 'appstoreconnect-v1');
  assert.equal(claims.exp - claims.iat, 600);
  assert.equal(Buffer.from(signature, 'base64url').length, 64);
  assert.ok(verify('sha256', Buffer.from(`${header}.${payload}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
  const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  assert.throws(() => makeJWT('TESTKEY001', claims.iss, rsa));
});

test('signing is manual main-only, no public IPA artifact, and upload is not automatically retried', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/testflight.yml', import.meta.url), 'utf8');
  assert.ok(workflow.includes('workflow_dispatch:'));
  assert.ok(workflow.includes("github.ref == 'refs/heads/main'"));
  assert.ok(workflow.includes('persist-credentials: false'));
  assert.ok(workflow.includes('cancel-in-progress: false'));
  assert.ok(workflow.includes('path: build/testflight-delivery.json'));
  assert.ok(!workflow.includes('publish_release') && !workflow.includes('pull_request:'));
  const source = fs.readFileSync(new URL('./testflight.mjs', import.meta.url), 'utf8');
  assert.equal((source.match(/altool\('--upload-app'\)/g) ?? []).length, 1);
  assert.ok(!source.includes('betaAppReviewSubmissions') && !source.includes('/appStoreVersionSubmissions'));
});

test('FP16 diagnostic workflow only measures and cannot sign or upload an application', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/fp16-diagnostic.yml', import.meta.url), 'utf8');
  assert.ok(workflow.includes('--diagnostic-report build/fp16-diagnostic.json'));
  assert.ok(workflow.includes('path: build/fp16-diagnostic.json'));
  assert.ok(workflow.includes("github.ref == 'refs/heads/main'"));
  assert.ok(!workflow.includes('secrets.') && !workflow.includes('testflight.mjs'));
  assert.ok(!workflow.includes('xcodebuild') && !workflow.includes('altool'));
});

test('native top-five diagnostic retains FP32 models only in the test target and cannot upload', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/fp16-native-ranking.yml', import.meta.url), 'utf8');
  assert.ok(workflow.includes('testNativeFP32AndFP16TopFiveRankingDiagnostics'));
  assert.ok(workflow.includes('testTopFiveRankingDiagnosticsDetectChangesAndStableTies'));
  assert.ok(workflow.includes('xcresulttool export attachments'));
  assert.ok(!workflow.includes('secrets.') && !workflow.includes('testflight.mjs'));
  assert.ok(!workflow.includes('altool') && !workflow.includes('-exportArchive'));
  const spec = fs.readFileSync(new URL('../project.fp16-diagnostic.yml', import.meta.url), 'utf8').replaceAll('\r\n', '\n');
  assert.ok(spec.includes('IMAGEIQ_NATIVE_FP16_RANKING: "1"'));
  const targets = spec.split('schemes:')[0];
  assert.deepEqual([...targets.matchAll(/^  ([A-Za-z0-9_-]+):$/gm)].map(match => match[1]), ['LocalImageIQTests']);
});

test('real-photo diagnostics are opt-in, test-only and do not publish photographs', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/fp16-native-ranking.yml', import.meta.url), 'utf8');
  assert.ok(workflow.includes('type: boolean'));
  assert.ok(workflow.includes('testNativeRealPhotoTopFiveRankingDiagnostics'));
  assert.ok(workflow.includes('testRealPhotoRelevanceMetricsUseLabelsRatherThanBaselineRankAgreement'));
  assert.ok(workflow.includes('build/RealPhotoBenchmark/manifest.json'));
  assert.ok(!workflow.includes('path: build/RealPhotoBenchmark\n'));
  const spec = fs.readFileSync(new URL('../project.real-photo-diagnostic.yml', import.meta.url), 'utf8').replaceAll('\r\n', '\n');
  assert.ok(spec.includes('IMAGEIQ_REAL_PHOTO_RANKING: "1"'));
  assert.deepEqual([...spec.split('schemes:')[0].matchAll(/^  ([A-Za-z0-9_-]+):$/gm)].map(match => match[1]),
    ['LocalImageIQTests']);
});
