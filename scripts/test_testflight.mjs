import assert from 'node:assert/strict';
import { generateKeyPairSync, verify, X509Certificate } from 'node:crypto';
import { rootCertificates } from 'node:tls';
import fs from 'node:fs';
import test from 'node:test';
import { archiveArguments, decodeSecret, exportOptions, identity, makeJWT, maxIPABytes, modelPrecision,
  validateInfo, validateModelDelivery, validateProfile } from './testflight.mjs';

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
  const manifest = { modelVersion: `siglip2-b16-224-v1-${'a'.repeat(64)}`,
    preprocessing: { computePrecision: 'float16' }, parity: { precision: 'float16', status: 'passed',
      acceptancePolicy: 'fp16-normalized-experiment-v1' } };
  validateModelDelivery(manifest, maxIPABytes);
  for (const bytes of [0, -1, NaN, Infinity, 1.5, maxIPABytes + 1]) {
    assert.throws(() => validateModelDelivery(manifest, bytes));
  }
  for (const override of [{ preprocessing: { computePrecision: 'float32' } },
    { parity: { precision: 'float16', status: 'failed' } },
    { modelVersion: 'siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b' }]) {
    assert.throws(() => validateModelDelivery({ ...manifest, ...override }, 700 * 1024 * 1024));
  }
  const workflow = fs.readFileSync(new URL('../.github/workflows/testflight.yml', import.meta.url), 'utf8');
  assert.ok(workflow.includes('export_models.py --download --precision float16'));
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
