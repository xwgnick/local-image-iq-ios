import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const xcodeVersion = '26.3';
export const sdkVersion = '26.2';
export const reasons = {
  NSPrivacyAccessedAPICategoryUserDefaults: ['CA92.1'],
  NSPrivacyAccessedAPICategoryFileTimestamp: ['C617.1'],
  NSPrivacyAccessedAPICategorySystemBootTime: ['35F9.1'],
};
const sha = value => createHash('sha256').update(value).digest('hex');

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  assert.ok(!result.error && result.status === 0, `${command} failed: ${result.error?.message ?? result.stderr}`);
  return result.stdout.trim();
}

export function validatePrivacy(value) {
  assert.equal(value.NSPrivacyTracking, false);
  assert.deepEqual(value.NSPrivacyTrackingDomains, []);
  assert.deepEqual(value.NSPrivacyCollectedDataTypes, []);
  assert.ok(Array.isArray(value.NSPrivacyAccessedAPITypes));
  assert.equal(value.NSPrivacyAccessedAPITypes.length, Object.keys(reasons).length);
  assert.deepEqual(Object.fromEntries(value.NSPrivacyAccessedAPITypes.map(item =>
    [item.NSPrivacyAccessedAPIType, item.NSPrivacyAccessedAPITypeReasons])), reasons);
}

export function validateToolchain(xcode, sdk) {
  assert.equal(xcode.split(/\r?\n/)[0], `Xcode ${xcodeVersion}`, 'Unexpected Xcode; no default/fallback allowed');
  assert.equal(sdk.trim(), sdkVersion, 'Unexpected iPhoneOS SDK');
}

export function selectSimulator(devices) {
  const runtime = `com.apple.CoreSimulator.SimRuntime.iOS-${sdkVersion.replaceAll('.', '-')}`;
  const phone = devices?.devices?.[runtime]?.find(device => device.isAvailable && device.name.startsWith('iPhone'));
  assert.ok(phone && /^[a-f0-9-]{36}$/i.test(phone.udid), `No available iPhone simulator for ${runtime}`);
  return phone.udid;
}

export function validateDeviceSDK(info) {
  assert.match(info.DTSDKName ?? '', /^iphoneos26\.\d+(?:\.\d+)?$/, 'Expected the selected iOS 26 device SDK');
  assert.equal(info.DTSDKName, `iphoneos${sdkVersion}`);
  assert.match(info.DTXcode ?? '', /^263\d$/, 'Expected Xcode 26.3 device output');
  assert.equal(info.MinimumOSVersion, '17.0', 'Preserve iOS 17 support');
}

export function validateLegal(directory) {
  const bytes = fs.readFileSync(path.join(directory, 'ThirdPartyNotices.txt'));
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'third-party-manifest.json'), 'utf8'));
  const dependencies = JSON.parse(fs.readFileSync(path.join(root, 'scripts', 'release_dependencies.json'), 'utf8'));
  assert.equal(manifest.schemaVersion, 1);
  assert.equal(sha(bytes), manifest.noticesSHA256, 'Legal notice bytes do not match manifest');
  assert.deepEqual(manifest.packages.map(({ notices, ...pkg }) => pkg), dependencies.packages);
  for (const pkg of manifest.packages) {
    assert.ok(bytes.includes(Buffer.from(`${pkg.identity} ${pkg.version}`)), `Missing notice: ${pkg.identity}`);
    assert.equal(pkg.notices.length, pkg.noticeFiles.length);
    for (const item of pkg.notices) assert.match(item.sha256, /^[a-f0-9]{64}$/);
  }
  for (const fragment of ['SigLIP 2', 'Pillow 11.1.0', 'Permission to use, copy, modify and distribute',
    'geoBoundaries', 'CHN / ADM1', 'Apache License', 'MIT License']) {
    assert.ok(bytes.includes(Buffer.from(fragment)), `Missing legal text: ${fragment}`);
  }
  return { packages: manifest.packages.length, noticesSHA256: manifest.noticesSHA256 };
}

export function validateAppResources(app) {
  const plist = file => JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', file]));
  validatePrivacy(plist(path.join(app, 'PrivacyInfo.xcprivacy')));
  const legal = validateLegal(path.join(app, 'Legal'));
  for (const name of ['ThirdPartyNotices.txt', 'third-party-manifest.json']) {
    assert.deepEqual(fs.readFileSync(path.join(app, 'Legal', name)),
      fs.readFileSync(path.join(root, 'Resources', 'Legal', name)), `Bundled ${name} differs from reviewed source`);
  }
  const crypto = path.join(app, 'swift-crypto_Crypto.bundle', 'PrivacyInfo.xcprivacy');
  const manifest = plist(crypto);
  assert.equal(manifest.NSPrivacyTracking, false, 'Keep upstream Crypto privacy resource');
  assert.deepEqual(manifest.NSPrivacyAccessedAPITypes, []);
  assert.deepEqual(manifest.NSPrivacyCollectedDataTypes, []);
  assert.deepEqual(manifest.NSPrivacyTrackingDomains, []);
  return { ...legal, appPrivacyManifest: true, cryptoPrivacyManifest: true };
}

export function checkSource() {
  const dependencies = JSON.parse(fs.readFileSync(path.join(root, 'scripts', 'release_dependencies.json'), 'utf8'));
  const project = fs.readFileSync(path.join(root, 'project.yml'), 'utf8')
    .replace(/\r\n/g, '\n').replace(/^[ \t]*#.*\n/gm, '');
  for (const pkg of dependencies.packages) {
    assert.ok(project.includes(`url: ${pkg.url}\n    exactVersion: "${pkg.version}"`), `Unpinned package: ${pkg.identity}`);
  }
  assert.ok(project.includes('path: Resources/Legal\n        type: folder\n        buildPhase: resources'));
  const xml = fs.readFileSync(path.join(root, 'App', 'PrivacyInfo.xcprivacy'), 'utf8');
  for (const [category, codes] of Object.entries(reasons)) {
    assert.ok(xml.includes(`<string>${category}</string>`));
    for (const code of codes) assert.ok(xml.includes(`<string>${code}</string>`));
  }
  const info = fs.readFileSync(path.join(root, 'App', 'Info.plist'), 'utf8');
  assert.ok(info.includes('<key>UIDesignRequiresCompatibility</key><true/>'));
  for (const filename of ['ios.yml', 'ios-dev.yml']) {
    const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', filename), 'utf8');
    assert.ok(workflow.includes(`DEVELOPER_DIR: /Applications/Xcode_${xcodeVersion}.app/Contents/Developer`));
    assert.ok(workflow.includes('runs-on: macos-15'));
    assert.ok(workflow.includes('node scripts/check_release.mjs --toolchain'));
    assert.ok(workflow.includes('node scripts/prepare_legal_notices.mjs build/SourcePackages/checkouts --check'));
  }
  return validateLegal(path.join(root, 'Resources', 'Legal'));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const [mode, argument, ...extra] = process.argv.slice(2);
    assert.equal(extra.length, 0, 'Unexpected arguments');
    if (mode === '--source' && !argument) console.log(JSON.stringify(checkSource()));
    else if (mode === '--toolchain' && !argument) {
      const xcode = run('xcodebuild', ['-version']);
      const sdk = run('xcrun', ['--sdk', 'iphoneos', '--show-sdk-version']);
      validateToolchain(xcode, sdk);
      console.log(`${xcode}\niPhoneOS SDK ${sdk}`);
    } else if (mode === '--simulator' && argument) {
      assert.ok(process.env.GITHUB_ENV, 'GITHUB_ENV required to record simulator selection');
      const id = selectSimulator(JSON.parse(fs.readFileSync(argument, 'utf8')));
      fs.appendFileSync(process.env.GITHUB_ENV, `SIMULATOR_ID=${id}\n`);
      console.log(`Selected iOS ${sdkVersion} iPhone simulator ${id}`);
    } else if (mode === '--app-dir' && argument) console.log(JSON.stringify(validateAppResources(path.resolve(argument))));
    else throw Error('Usage: check_release.mjs --source | --toolchain | --simulator JSON | --app-dir APP');
  } catch (error) {
    console.error(`Release preparation check failed: ${error.message}`);
    process.exitCode = 1;
  }
}
