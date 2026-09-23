// macOS packaging only. No signing credentials, provisioning or device installation.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readdirSync, readFileSync, statSync, writeFileSync,
  mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import path from 'node:path';

function run(executable, args) {
  const result = spawnSync(executable, args, { encoding: 'utf8' });
  if (result.error || result.status !== 0) throw Error(`${executable}: ${result.error?.message ?? result.stderr}`);
  return result.stdout;
}

export function verifyPlatform(info, architectures, buildDescription) {
  assert.equal(info.DTPlatformName, 'iphoneos', 'Simulator output cannot be packaged as a device IPA');
  assert.deepEqual(info.CFBundleSupportedPlatforms, ['iPhoneOS']);
  assert.equal(info.CFBundlePackageType, 'APPL');
  assert.ok(info.CFBundleExecutable && path.basename(info.CFBundleExecutable) === info.CFBundleExecutable);
  assert.deepEqual(architectures.trim().split(/\s+/), ['arm64']);
  const platforms = [...buildDescription.matchAll(/^\s*platform\s+(\S+)\s*$/gm)].map(m => m[1]);
  assert.ok(platforms.length > 0 && platforms.every(p => p === 'IOS' || p === '2'), 'Mach-O must target physical iOS, not iOS Simulator');
}

if (process.argv[2] === '--self-test') {
  const info = { DTPlatformName: 'iphoneos', CFBundleSupportedPlatforms: ['iPhoneOS'], CFBundlePackageType: 'APPL', CFBundleExecutable: 'LocalImageIQ' };
  verifyPlatform(info, 'arm64', '    platform IOS\n');
  assert.throws(() => verifyPlatform({ ...info, DTPlatformName: 'iphonesimulator' }, 'arm64', '    platform IOSSIMULATOR\n'));
  assert.throws(() => verifyPlatform(info, 'arm64', '    platform IOSSIMULATOR\n'));
  assert.throws(() => verifyPlatform(info, 'x86_64', '    platform IOS\n'));
  console.log('PASS: device/simulator platform validator synthetic checks (not a device build)');
} else {
  assert.equal(process.platform, 'darwin', 'Package device binaries on macOS after xcodebuild -sdk iphoneos');
  assert.equal(process.argv.length, 4, 'Expected app-directory and output-directory');
  const app = path.resolve(process.argv[2]), output = path.resolve(process.argv[3]);
  assert.ok(app.endsWith('.app') && statSync(app).isDirectory());
  const info = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Info.plist')]));
  const executable = path.join(app, info.CFBundleExecutable);
  const architectures = run('xcrun', ['lipo', '-archs', executable]);
  const macho = run('xcrun', ['vtool', '-show-build', executable]);
  verifyPlatform(info, architectures, macho);
  assert.ok(!existsSync(path.join(app, 'PlugIns')), 'Do not include test bundles in the device App');
  assert.ok(!existsSync(path.join(app, 'embedded.mobileprovision')), 'This workflow does not create signed provisioned builds');
  assert.ok(!existsSync(path.join(app, '_CodeSignature')), 'Unexpected signature; produce unsigned output for local signing');
  const resource = name => [app, path.join(app, 'Models'), path.join(app, 'Resources', 'Models')]
    .map(folder => path.join(folder, name)).find(existsSync);
  const manifestPath = resource('model-manifest.json');
  assert.ok(manifestPath, 'Real model manifest is required');
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  assert.equal(manifest.schemaVersion, 2);
  assert.equal(manifest.dimension, 768);
  assert.equal(manifest.sequenceLength, 64);
  assert.equal(manifest.imageSize, 224);
  assert.match(manifest.modelVersion, /^siglip2-b16-224-v1-[a-f0-9]{64}$/);
  const source = { id: 'google/siglip2-base-patch16-224',
    revision: '75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2' };
  assert.deepEqual(manifest.imageModel, source);
  assert.deepEqual(manifest.textModel, source);
  assert.equal(manifest.imageInput, 'pixel_values');
  assert.deepEqual(manifest.textInputs, ['input_ids']);
  assert.equal(manifest.output, 'output_embedding');
  assert.deepEqual(manifest.features, {
    image: { pixel_values: { dtype: 'float32', shape: [1, 3, 224, 224] } },
    text: { input_ids: { dtype: 'int32', shape: [1, 64] } },
    output: { output_embedding: { dtype: 'float32', shape: [1, 768] } },
  });
  assert.equal(manifest.preprocessing?.image?.resize, 'warp directly to 224x224; do not preserve aspect ratio');
  assert.equal(manifest.preprocessing?.image?.resample, 2);
  assert.equal(manifest.preprocessing?.image?.rescale, 1 / 255);
  assert.deepEqual(manifest.preprocessing?.image?.mean, [0.5, 0.5, 0.5]);
  assert.deepEqual(manifest.preprocessing?.image?.std, [0.5, 0.5, 0.5]);
  assert.equal(manifest.preprocessing?.outputNormalization,
    'none; raw pooler_output; Swift L2-normalizes each encoder output once');
  assert.equal(manifest.parity?.status, 'passed');
  assert.equal(manifest.parity?.precision, 'float32');
  assert.equal(manifest.parity?.computeUnits, 'CPU_ONLY');
  for (const name of ['ImageEncoder.mlmodelc', 'TextEncoder.mlmodelc']) {
    const item = resource(name); assert.ok(item && statSync(item).isDirectory() && readdirSync(item).length, `Missing compiled device model ${name}`);
  }
  const tokenizerNames = { tokenizerFile: 'tokenizer.json', tokenizerConfigFile: 'tokenizer_config.json' };
  const tokenizerPaths = [];
  for (const [key, name] of Object.entries(tokenizerNames)) {
    assert.equal(manifest[key], name, `Wrong manifest ${key}`);
    const item = resource(name);
    assert.ok(item && statSync(item).isFile(), `Missing SigLIP tokenizer resource ${name}`);
    tokenizerPaths.push(item);
    const expected = manifest.artifactsSHA256?.[name];
    assert.match(expected, /^[a-f0-9]{64}$/, `Missing tokenizer hash: ${name}`);
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(item)) hash.update(chunk);
    assert.equal(hash.digest('hex'), expected, `Bundled tokenizer bytes differ: ${name}`);
  }
  assert.equal(path.dirname(tokenizerPaths[0]), path.dirname(tokenizerPaths[1]),
    'Both tokenizer JSON resources must share the local runtime directory');
  // A passing manifest records export parity, not native or physical-device validation.
  const frameworks = path.join(app, 'Frameworks');
  if (existsSync(frameworks)) for (const name of readdirSync(frameworks)) {
    const binary = name.endsWith('.framework') ? path.join(frameworks, name, name.slice(0, -10)) : path.join(frameworks, name);
    if (!statSync(binary).isFile()) continue;
    const description = run('xcrun', ['vtool', '-show-build', binary]);
    assert.ok(!description.includes('IOSSIMULATOR'), `Simulator framework found: ${name}`);
  }
  mkdirSync(output, { recursive: true });
  const staging = mkdtempSync(path.join(output, '.payload-'));
  const ipa = path.join(output, 'LocalImageIQ-iphoneos-unsigned.ipa');
  try {
    mkdirSync(path.join(staging, 'Payload'));
    run('ditto', [app, path.join(staging, 'Payload', 'LocalImageIQ.app')]);
    run('ditto', ['-c', '-k', '--keepParent', '--norsrc', path.join(staging, 'Payload'), ipa]);
    const entries = run('unzip', ['-Z1', ipa]).split('\n').filter(Boolean);
    assert.ok(entries.includes('Payload/LocalImageIQ.app/Info.plist'));
    assert.ok(entries.every(name => name.startsWith('Payload/')));
    assert.ok(!entries.some(name => /\.xctest(?:\/|$)|embedded\.mobileprovision$/.test(name)));
  } finally { rmSync(staging, { recursive: true, force: true }); }
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(ipa)) digest.update(chunk);
  const sha256 = digest.digest('hex');
  const report = { platform: 'iphoneos', architectures: ['arm64'], configuration: 'Release', signed: false,
    installableWithoutResigning: false, deviceTested: false, minimumOS: info.MinimumOSVersion,
    bundleIdentifier: info.CFBundleIdentifier, buildSDK: info.DTSDKName, xcode: info.DTXcode,
    modelVersion: manifest.modelVersion, modelDimension: manifest.dimension,
    ipa: path.basename(ipa), bytes: statSync(ipa).size, sha256,
    nextStep: 'Re-sign locally on Windows using the user-approved tool and their own Apple account. No account secret is used by CI.' };
  writeFileSync(path.join(output, 'device-build.json'), JSON.stringify(report, null, 2) + '\n');
  writeFileSync(path.join(output, 'SHA256SUMS.txt'), `${sha256}  ${path.basename(ipa)}\n`);
  console.log(JSON.stringify(report));
}