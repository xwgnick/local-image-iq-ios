import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { checkSource, reasons, selectSimulator, validatePrivacy, validateToolchain,
  validateDeviceSDK, validateLegal } from './check_release.mjs';
import { renderNotices } from './prepare_legal_notices.mjs';

const privacy = () => ({
  NSPrivacyTracking: false, NSPrivacyTrackingDomains: [], NSPrivacyCollectedDataTypes: [],
  NSPrivacyAccessedAPITypes: Object.entries(reasons).map(([category, values]) =>
    ({ NSPrivacyAccessedAPIType: category, NSPrivacyAccessedAPITypeReasons: [...values] })),
});

test('privacy declaration requires exact reasons and no tracking/collection', () => {
  validatePrivacy(privacy());
  for (const mutate of [
    value => { value.NSPrivacyTracking = true; },
    value => { value.NSPrivacyTrackingDomains = ['example.invalid']; },
    value => { delete value.NSPrivacyCollectedDataTypes; },
    value => { value.NSPrivacyAccessedAPITypes.pop(); },
    value => { value.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPITypeReasons = ['C56D.1']; },
    value => { value.NSPrivacyAccessedAPITypes.push(value.NSPrivacyAccessedAPITypes[0]); },
  ]) {
    const value = privacy();
    mutate(value);
    assert.throws(() => validatePrivacy(value));
  }
});

test('toolchain does not silently accept runner default, beta, or mismatched SDK', () => {
  validateToolchain('Xcode 26.3\nBuild version 17C529', '26.2');
  for (const [xcode, sdk] of [['Xcode 16.4', '18.5'], ['Xcode 27.0', '27.0'],
    ['Xcode 26.3 beta', '26.2'], ['Xcode 26.3', '18.5']]) {
    assert.throws(() => validateToolchain(xcode, sdk));
  }
});

test('simulator selection uses the selected SDK runtime, not the first old iPhone', () => {
  const phone = { name: 'iPhone 17', isAvailable: true, udid: 'A0000000-0000-0000-0000-000000000000' };
  const old = { ...phone, udid: 'B0000000-0000-0000-0000-000000000000' };
  const devices = { devices: {
    'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [old],
    'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [{ ...phone, name: 'iPad' }, phone],
  } };
  assert.equal(selectSimulator(devices), phone.udid);
  devices.devices['com.apple.CoreSimulator.SimRuntime.iOS-26-2'][1].isAvailable = false;
  assert.throws(() => selectSimulator(devices), /No available iPhone/);
  assert.throws(() => selectSimulator({ devices: {} }));
});

test('device package preserves iOS17 deployment and meets selected SDK requirement', () => {
  const info = { DTSDKName: 'iphoneos26.2', DTXcode: '2630', MinimumOSVersion: '17.0' };
  validateDeviceSDK(info);
  for (const override of [{ DTSDKName: 'iphoneos18.5' }, { DTSDKName: 'iphonesimulator26.2' },
    { DTXcode: '1640' }, { MinimumOSVersion: '26.0' }]) {
    assert.throws(() => validateDeviceSDK({ ...info, ...override }));
  }
});

test('source resources and workflow pins match reviewed dependency inventory', () => {
  assert.equal(checkSource().packages, 7);
});

test('bundled attribution retains original metadata and adds verified CHN ADM1 source evidence', () => {
  const text = fs.readFileSync(new URL('../Resources/Legal/ThirdPartyNotices.txt', import.meta.url), 'utf8');
  assert.ok(text.includes('licenseSource: commons.wikimedia.org/wiki/File\n'));
  assert.ok(text.includes('https://commons.wikimedia.org/wiki/File:China_blank_province_map.svg'));
  assert.ok(text.includes('Newfraferz87'));
  assert.ok(text.includes('9cf4cb357ea388cc135b47664b40f9483c80bf29c625d3a69f9bc70011704ea4'));
});

test('full native validation can retain evidence without publishing an app or release', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/ios.yml', import.meta.url), 'utf8');
  assert.match(workflow, /publish_release:\s+description:[^\n]+\s+type: boolean\s+default: true/);
  assert.ok(workflow.includes('if: ${{ always() && inputs.publish_release }}'));
  assert.ok(workflow.includes('if: ${{ always() && !inputs.publish_release }}'));
  const artifact = workflow.slice(workflow.indexOf('- name: Keep validation evidence'));
  assert.ok(artifact.includes('build/device/device-build.json'));
  assert.doesNotMatch(artifact, /\*\.ipa|LocalImageIQ\.app/);
});

test('legal resource tampering and missing files fail explicitly', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'imageiq-legal-test-'));
  try {
    for (const name of ['ThirdPartyNotices.txt', 'third-party-manifest.json']) {
      fs.copyFileSync(new URL(`../Resources/Legal/${name}`, import.meta.url), path.join(directory, name));
    }
    assert.equal(validateLegal(directory).packages, 7);
    fs.appendFileSync(path.join(directory, 'ThirdPartyNotices.txt'), 'modified');
    assert.throws(() => validateLegal(directory), /do not match/);
    fs.unlinkSync(path.join(directory, 'ThirdPartyNotices.txt'));
    assert.throws(() => validateLegal(directory));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('notice rendering preserves full supplied license and attribution text deterministically', () => {
  const dependencies = { packages: [{ identity: 'sample', version: '1.0', url: 'https://example.invalid',
    revision: 'a'.repeat(40), license: 'MIT' }] };
  const contents = new Map([['sample', [{ file: 'LICENSE', text: 'Exact upstream permission and disclaimer.\n' }]]]);
  const text = renderNotices(dependencies, contents, 'Pillow notice.', 'Source and alterations.', 'Apache terms.');
  for (const fragment of ['Exact upstream permission and disclaimer.\n', 'Source and alterations.',
    'FP32 Core ML encoders', 'sample 1.0']) assert.ok(text.includes(fragment));
  assert.equal(renderNotices(dependencies, contents, 'Pillow notice.', 'Source and alterations.', 'Apache terms.'), text);
  assert.throws(() => renderNotices(dependencies, new Map(), '', '', ''), /Missing notices/);
});
