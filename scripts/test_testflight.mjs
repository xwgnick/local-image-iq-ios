import assert from 'node:assert/strict';
import { generateKeyPairSync, verify, X509Certificate } from 'node:crypto';
import { rootCertificates } from 'node:tls';
import fs from 'node:fs';
import test from 'node:test';
import { decodeSecret, exportOptions, identity, makeJWT, validateInfo, validateProfile } from './testflight.mjs';

test('first official build identity is isolated from unsigned development delivery', () => {
  assert.deepEqual(identity, { bundle: 'app.piankexun.ios', version: '1.0', build: '46' });
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

test('exported device IPA identity and SDK must match the approved official build', () => {
  const info = { CFBundleIdentifier: identity.bundle, CFBundleShortVersionString: '1.0',
    CFBundleVersion: '46', DTPlatformName: 'iphoneos', CFBundleSupportedPlatforms: ['iPhoneOS'],
    DTSDKName: 'iphoneos26.2', DTXcode: '2630', MinimumOSVersion: '17.0' };
  validateInfo(info);
  for (const override of [{ CFBundleIdentifier: 'com.example.localimageiq' }, { CFBundleVersion: '45' },
    { CFBundleShortVersionString: '0.16.5' }, { DTPlatformName: 'iphonesimulator' }, { DTSDKName: 'iphoneos18.5' }]) {
    assert.throws(() => validateInfo({ ...info, ...override }));
  }
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
