#!/usr/bin/env node
// Dependency-free, read-only source/resource smoke checks. NOT a Swift compiler,
// Xcode build, full XML parser, Core ML validator, or proof of native parity.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const defaultRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const expectedModels = {
  imageModel: { id: 'google/siglip2-base-patch16-224', revision: '75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2' },
  textModel: { id: 'google/siglip2-base-patch16-224', revision: '75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2' },
};
// Mirror model_contract.py/base_manifest(), not a legacy export or build artifact.
const expectedPreprocessing = {
  image: {
    orientation: 'apply EXIF before RGB conversion', color: 'RGB',
    resize: 'warp directly to 224x224; do not preserve aspect ratio',
    interpolationReference: 'Pillow 11.1.0 BILINEAR', resample: 2,
    crop: 'none; cropXYWH [0,0,224,224] describes the full resized image',
    rescale: 1 / 255, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5], layout: 'NCHW',
    pooling: 'vision_model.pooler_output including learned attention pooling head',
  },
  text: {
    algorithm: 'GemmaTokenizerFast; pinned Hugging Face tokenizer.json BPE with byte fallback',
    tokenizerFile: 'tokenizer.json', tokenizerConfigFile: 'tokenizer_config.json', doLowerCase: true,
    lowercase: 'explicit Python str.lower before HF tokenization; not casefold or locale-sensitive',
    normalization: 'after lowercasing use the pinned tokenizer.json normalizer unchanged',
    specialTokens: { pad: { token: '<pad>', id: 0 }, eos: { token: '<eos>', id: 1 },
      bos: { token: '<bos>', id: 2 }, unk: { token: '<unk>', id: 3 } },
    addBOSToken: false, addEOSToken: true, sequenceLength: 64,
    truncation: 'right; at most 63 content tokens plus one appended EOS (id 1)',
    padding: 'right to 64 with PAD (id 0)', attentionMask: 'fixture checks only; never a model input',
    pooling: 'text_model.pooler_output: final sequence position then learned head; no mask',
  },
  outputNormalization: 'none; raw pooler_output; Swift L2-normalizes each encoder output once',
  outputScoring: 'no sigmoid, logit scale, logit bias or paired forward in either encoder',
  computePrecision: 'float32',
};

function validateManifest(value) {
  for (const [key, expected] of Object.entries({ schemaVersion: 2, dimension: 768, sequenceLength: 64,
    imageSize: 224, imageInput: 'pixel_values', output: 'output_embedding',
    tokenizerFile: 'tokenizer.json', tokenizerConfigFile: 'tokenizer_config.json', ...expectedModels })) {
    assert.deepEqual(value[key], expected, `Manifest ${key}`);
  }
  assert.deepEqual(value.textInputs, ['input_ids']);
  assert.match(value.modelVersion, /^siglip2-b16-224-v1-[a-f0-9]{64}$/);
  assert.deepEqual(value.features, {
    image: { pixel_values: { dtype: 'float32', shape: [1, 3, 224, 224] } },
    text: { input_ids: { dtype: 'int32', shape: [1, 64] } },
    output: { output_embedding: { dtype: 'float32', shape: [1, 768] } },
  });
  assert.deepEqual(value.preprocessing, expectedPreprocessing);
  assert.equal(value.parity?.status, 'passed');
  assert.equal(value.parity?.report, 'parity-report.json');
  assert.equal(value.parity?.precision, 'float32');
  assert.equal(value.parity?.computeUnits, 'CPU_ONLY');
  assert.equal(value.provenance, 'provenance.json');
  assert.equal(value.redistributionApproved, false);
  assert.ok(value.artifactsSHA256 && Object.keys(value.artifactsSHA256).length > 0);
}

function plistSourceSmoke(xml) {
  // Deliberately lexical. A later macOS plutil -lint is still required.
  assert.match(xml, /<plist\b[^>]*>[\s\S]*<dict>[\s\S]*<\/dict>\s*<\/plist>/,
    'Expected XML plist with a dictionary; binary plists need macOS plutil validation');
  const photo = xml.match(/<key>\s*NSPhotoLibraryUsageDescription\s*<\/key>\s*<string>([\s\S]*?)<\/string>/);
  assert.ok(photo && photo[1].trim().length > 0, 'Missing nonempty Photos usage description');
}

function filesUnder(directory, suffix) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const child = path.join(directory, entry.name);
    if (entry.isDirectory()) return filesUnder(child, suffix);
    return entry.isFile() && entry.name.endsWith(suffix) ? [child] : [];
  });
}

function text(file) { return readFileSync(file, 'utf8'); }
function json(file) { return JSON.parse(text(file)); }
async function sha(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

function selfTest() {
  const valid = '<plist version="1.0"><dict><key>NSPhotoLibraryUsageDescription</key><string>Search selected photos locally.</string></dict></plist>';
  plistSourceSmoke(valid);
  assert.throws(() => plistSourceSmoke(valid.replace('NSPhotoLibraryUsageDescription', 'Other')));
  assert.throws(() => plistSourceSmoke(valid.replace('Search selected photos locally.', '')));
  assert.throws(() => validateManifest({ schemaVersion: 2 }));
  console.log('PASS: in-memory checker smoke tests only; no Swift/XML/runtime validation performed.');
}

async function checkModels(root, notes) {
  const models = path.join(root, 'Resources', 'Models');
  const manifest = json(path.join(models, 'model-manifest.json'));
  validateManifest(manifest);
  for (const [relative, checksum] of Object.entries(manifest.artifactsSHA256)) {
    assert.match(checksum, /^[a-f0-9]{64}$/);
    const resolved = path.resolve(models, relative);
    assert.ok(resolved.startsWith(models + path.sep), `Artifact path must stay in Models: ${relative}`);
    assert.equal(await sha(resolved), checksum, `SHA-256 mismatch: ${relative}`);
  }
  for (const name of ['tokenizer.json', 'tokenizer_config.json', 'tokenizer-parity.json',
    'image-preprocess-parity.json', 'parity-report.json', 'provenance.json']) {
    assert.ok(Object.hasOwn(manifest.artifactsSHA256, name), `Missing hashed artifact ${name}`);
  }
  for (const name of ['ImageEncoder.mlpackage', 'TextEncoder.mlpackage']) {
    assert.ok(statSync(path.join(models, name)).isDirectory());
    assert.ok(Object.keys(manifest.artifactsSHA256).some(key => key.startsWith(name + '/')));
  }
  const provenance = json(path.join(models, 'provenance.json'));
  assert.equal(provenance.schemaVersion, 2);
  assert.equal(provenance.modelVersion, manifest.modelVersion);
  assert.deepEqual(Object.keys(provenance.sources), ['shared']);
  const source = provenance.sources.shared;
  assert.equal(source.id, expectedModels.imageModel.id);
  assert.equal(source.revision, expectedModels.imageModel.revision);
  assert.deepEqual(source.roles, ['image', 'text']);
  assert.equal(source.redistributionApproved, false);
  assert.equal(provenance.redistributionApproved, false);
  for (const name of ['tokenizer.json', 'tokenizer_config.json']) {
    assert.equal(source.sha256[name], manifest.artifactsSHA256[name], `Pinned source bytes differ: ${name}`);
  }
  const tokenizer = json(path.join(models, 'tokenizer.json'));
  const config = json(path.join(models, 'tokenizer_config.json'));
  assert.equal(tokenizer.model.type, 'BPE');
  assert.equal(tokenizer.model.byte_fallback, true);
  const vocabularyIDs = new Set([...Object.values(tokenizer.model.vocab),
    ...tokenizer.added_tokens.map(token => token.id)]);
  assert.equal(vocabularyIDs.size, 256000);
  assert.ok([...vocabularyIDs].every(id => Number.isInteger(id) && id >= 0 && id < 256000));
  for (const [key, expected] of Object.entries({ tokenizer_class: 'GemmaTokenizer',
    add_bos_token: false, add_eos_token: true, do_lower_case: true, padding_side: 'right',
    model_input_names: ['input_ids'], pad_token: '<pad>', eos_token: '<eos>',
    bos_token: '<bos>', unk_token: '<unk>' })) {
    assert.deepEqual(config[key], expected, `Tokenizer config ${key}`);
  }
  assert.equal(config.truncation_side ?? 'right', 'right');
  const tokens = json(path.join(models, 'tokenizer-parity.json'));
  assert.equal(tokens.schemaVersion, 2);
  assert.equal(tokens.sequenceLength, 64);
  assert.equal(tokens.embeddingDimension, 768);
  assert.equal(tokens.modelVersion, manifest.modelVersion);
  assert.deepEqual(tokens.textModel, expectedModels.textModel);
  assert.equal(tokens.embeddingsAreRaw, true);
  assert.equal(tokens.tokenizerFile, manifest.tokenizerFile);
  assert.equal(tokens.tokenizerConfigFile, manifest.tokenizerConfigFile);
  assert.equal(tokens.tokenizerSHA256, manifest.artifactsSHA256['tokenizer.json']);
  assert.equal(tokens.configSHA256, manifest.artifactsSHA256['tokenizer_config.json']);
  assert.equal(tokens.tokenizerClass, 'GemmaTokenizerFast');
  assert.deepEqual(tokens.preprocessing, expectedPreprocessing.text);
  assert.deepEqual(tokens.tokenizerOptions, { padding: 'max_length', truncation: true,
    max_length: 64, add_special_tokens: true, return_attention_mask: true, return_token_type_ids: false });
  assert.ok(tokens.cases.length > 0);
  for (const item of tokens.cases) {
    assert.equal(typeof item.text, 'string');
    // Do not substitute JavaScript lowercasing for the Python Unicode reference.
    assert.equal(typeof item.lowercasedText, 'string');
    assert.equal(item.inputIDs.length, 64);
    assert.equal(item.attentionMask.length, 64);
    assert.ok(item.inputIDs.every(id => Number.isInteger(id) && id >= 0 && id < 256000));
    assert.ok(item.attentionMask.every(mask => mask === 0 || mask === 1));
    const valid = item.attentionMask.reduce((sum, mask) => sum + mask, 0);
    assert.ok(valid >= 1 && valid <= 64);
    assert.deepEqual(item.attentionMask, [...Array(valid).fill(1), ...Array(64 - valid).fill(0)]);
    assert.equal(item.inputIDs[valid - 1], 1, 'Missing appended EOS');
    // A literal content PAD may have mask=1; only the trailing padding must be zero.
    assert.ok(item.inputIDs.slice(valid).every(id => id === 0));
    for (const name of ['referenceRaw', 'coreMLRaw']) {
      assert.equal(item[name].length, 768);
      assert.ok(item[name].every(Number.isFinite));
    }
  }
  const images = json(path.join(models, 'image-preprocess-parity.json'));
  assert.equal(images.schemaVersion, 2);
  assert.equal(images.embeddingDimension, 768);
  assert.equal(images.modelVersion, manifest.modelVersion);
  assert.deepEqual(images.imageModel, expectedModels.imageModel);
  assert.deepEqual(images.preprocessing, expectedPreprocessing.image);
  assert.equal(images.embeddingsAreRaw, true);
  assert.ok(images.cases.length > 0);
  for (const item of images.cases) {
    assert.deepEqual(item.shape, [1, 3, 224, 224]);
    assert.equal(item.layout, 'NCHW');
    assert.deepEqual(item.resizedSize, [224, 224]);
    assert.deepEqual(item.cropXYWH, [0, 0, 224, 224]);
    assert.equal(item.dtype, 'float32-little-endian');
    assert.equal(item.tensorBytes, 1 * 3 * 224 * 224 * 4);
    assert.equal(item.tensorSHA256, manifest.artifactsSHA256[item.tensor]);
    assert.equal(item.imageSHA256, manifest.artifactsSHA256[item.image]);
    assert.ok(Object.hasOwn(manifest.artifactsSHA256, item.tensor));
    assert.ok(Object.hasOwn(manifest.artifactsSHA256, item.image));
    assert.equal(statSync(path.join(models, item.tensor)).size, item.tensorBytes);
    for (const name of ['referenceRaw', 'coreMLRaw']) {
      assert.equal(item[name].length, 768);
      assert.ok(item[name].every(Number.isFinite));
    }
  }
  const report = json(path.join(models, 'parity-report.json'));
  assert.equal(report.schemaVersion, 2);
  assert.equal(report.modelVersion, manifest.modelVersion);
  assert.equal(report.passed, true);
  assert.equal(report.precision, 'float32');
  assert.equal(report.computeUnits, 'CPU_ONLY');
  assert.ok(Number.isFinite(report.thresholds.minCosineExclusive) &&
    report.thresholds.minCosineExclusive >= 0.999 && report.thresholds.minCosineExclusive < 1);
  for (const [name, ceiling] of Object.entries({ conversionMaxAbsInclusive: 1e-3,
    torchMaxAbsInclusive: 1e-5, similarityMaxAbsInclusive: 1e-4, preprocessMaxAbsInclusive: 1e-6 })) {
    assert.ok(Number.isFinite(report.thresholds[name]) && report.thresholds[name] > 0 &&
      report.thresholds[name] <= ceiling, `Export acceptance gate weakened: ${name}`);
  }
  assert.ok(report.cases.length === tokens.cases.length + images.cases.length);
  const expectedCaseIDs = [...images.cases.map(item => `image/${item.id}`), ...tokens.cases.map(item => `text/${item.id}`)];
  assert.equal(new Set(expectedCaseIDs).size, expectedCaseIDs.length);
  assert.deepEqual(report.cases.map(item => `${item.role}/${item.id}`).sort(), [...expectedCaseIDs].sort());
  for (const item of report.cases) {
    assert.deepEqual(Object.keys(item.comparisons).sort(), [
      'referenceVsWrapper', 'wrapperVsTrace', 'traceVsCoreML', 'referenceVsCoreML',
    ].sort());
    for (const [name, measurement] of Object.entries(item.comparisons)) {
      assert.ok(Number.isFinite(measurement.cosine) && measurement.cosine > report.thresholds.minCosineExclusive);
      const max = name.includes('CoreML') ? report.thresholds.conversionMaxAbsInclusive : report.thresholds.torchMaxAbsInclusive;
      assert.ok(Number.isFinite(measurement.maxAbs) && measurement.maxAbs >= 0 && measurement.maxAbs <= max);
    }
  }
  for (const item of images.cases) {
    assert.ok(Number.isFinite(item.pillowVsHFMaxAbs) && item.pillowVsHFMaxAbs >= 0 &&
      item.pillowVsHFMaxAbs <= report.thresholds.preprocessMaxAbsInclusive);
  }
  assert.deepEqual(report.pairedCosines.queryIDs, tokens.cases.map(item => item.id));
  assert.deepEqual(report.pairedCosines.imageIDs, images.cases.map(item => item.id));
  for (const key of ['reference', 'coreML']) {
    assert.equal(report.pairedCosines[key].length, tokens.cases.length);
    for (const row of report.pairedCosines[key]) {
      assert.equal(row.length, images.cases.length);
      assert.ok(row.every(Number.isFinite));
    }
  }
  assert.ok(Number.isFinite(report.pairedCosines.maxAbs) && report.pairedCosines.maxAbs >= 0 &&
    report.pairedCosines.maxAbs <= report.thresholds.similarityMaxAbsInclusive);
  notes.push('Generated fixture schemas, manifest, recorded numerical gates and file hashes checked. Predictions NOT rerun.');
  notes.push(`Native gates reported: tokenizer=${report.nativeTokenizerParity}, preprocessing=${report.nativeImagePreprocessParity}, runtime=${report.nativeModelRuntimeParity}.`);
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === '--self-test') return selfTest();
  if (args.includes('--help')) {
    console.log('node scripts/check_project.mjs [--root DIR] [--app-dir App] [--plist App/Info.plist] [--models]\nnode scripts/check_project.mjs --self-test\nRead-only lexical layout/API/plist checks; never a Swift build or full XML validation.');
    return;
  }
  const options = { root: defaultRoot, appDir: 'App', plist: null, models: false };
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === '--models') options.models = true;
    else if (['--root', '--app-dir', '--plist'].includes(arg)) {
      assert.ok(args[index + 1] && !args[index + 1].startsWith('--'), `Missing value for ${arg}`);
      const key = { '--root': 'root', '--app-dir': 'appDir', '--plist': 'plist' }[arg];
      options[key] = args[++index];
    } else throw new Error(`Unknown option: ${arg}`);
  }
  const root = path.resolve(options.root);
  const required = ['docs/IMPLEMENTATION_CONTRACT.md', 'Packages/ImageIQCore/Package.swift',
    'Resources/Models/README.md', 'scripts/export_models.py', 'scripts/encoder_wrappers.py',
    'scripts/model_contract.py', 'scripts/synthetic_fixtures.py', 'scripts/test_static.py',
    'scripts/requirements-coreml.txt', 'scripts/check_project.mjs'];
  for (const name of required) assert.ok(existsSync(path.join(root, name)), `Missing required file: ${name}`);
  const contract = text(path.join(root, 'docs/IMPLEMENTATION_CONTRACT.md'));
  for (const model of Object.values(expectedModels)) {
    assert.ok(contract.includes(model.id) && contract.includes(model.revision), 'Pinned shared model contract drift');
  }
  const packageRoot = path.join(root, 'Packages', 'ImageIQCore');
  const packageSource = text(path.join(packageRoot, 'Package.swift'));
  assert.match(packageSource, /swift-tools-version:\s*5\.9/);
  assert.match(packageSource, /\.iOS\(\.v17\)/);
  assert.match(packageSource, /\.macOS\(\.v14\)/);
  assert.doesNotMatch(packageSource, /\.package\s*\(\s*url\s*:/, 'Core must not fetch Swift dependencies');
  const coreFiles = filesUnder(path.join(packageRoot, 'Sources'), '.swift');
  assert.ok(coreFiles.length > 0, 'Missing core Swift source');
  const core = coreFiles.map(text).join('\n');
  const symbols = [/\b(?:enum|struct|class)\s+EmbeddingMath\b/, /\bfunc\s+normalized\s*\(/,
    /\bfunc\s+dot\s*\(/, /\bstruct\s+PlaceEmbedding\b/, /\bstruct\s+IndexedPhoto\b/,
    /\bstruct\s+SearchHit\b/, /\b(?:enum|struct|class)\s+VectorSearch\b/, /\bfunc\s+search\s*\(/,
    /\bstruct\s+TokenizedText\b/,
    /\binputIDs\s*:\s*\[Int32\]/, /\battentionMask\s*:\s*\[Int32\]/];
  for (const symbol of symbols) assert.match(core, symbol, `Missing core API source marker ${symbol}`);
  assert.doesNotMatch(core, /^\s*import\s+(SwiftUI|UIKit|Photos|CoreML)\b/m, 'Core should be Foundation-only');
  const tests = filesUnder(path.join(packageRoot, 'Tests'), '.swift');
  assert.ok(tests.length > 0, 'Missing Swift core tests');
  const appDirectory = path.resolve(root, options.appDir);
  const appFiles = filesUnder(appDirectory, '.swift');
  assert.ok(appFiles.length > 0, `Missing application Swift source in ${options.appDir}`);
  const app = appFiles.map(text).join('\n');
  assert.match(app, /@main\b/);
  assert.match(app, /\bimport\s+SwiftUI\b/);
  assert.match(app, /\bimport\s+Photos\b/);
  assert.match(app, /\bimport\s+CoreML\b/);
  assert.match(app, /\bimport\s+Tokenizers\b/);
  assert.match(app, /\b(?:struct|class)\s+SigLIPTokenizer\b/);
  assert.match(app, /\bAutoTokenizer\.from\s*\(\s*modelFolder\s*:/, 'Tokenizer must use bundled local JSON');
  for (const name of ['tokenizer.json', 'tokenizer_config.json']) {
    assert.ok(app.includes(name), `Missing runtime tokenizer resource marker: ${name}`);
  }
  const plist = options.plist ? path.resolve(root, options.plist) : path.join(appDirectory, 'Info.plist');
  plistSourceSmoke(text(plist));
  const notes = ['PASS: required source layout, lexical API markers and Photos plist text checks.',
    'Not compiled; XML is not fully parsed. macOS plutil, swift test and xcodebuild remain separate gates.'];
  if (options.models) await checkModels(root, notes);
  else notes.push('Model-free mode: no model/fixture/parity readiness claim.');
  console.log(notes.join('\n'));
}

main().catch(error => { console.error(`FAIL: ${error.message}`); process.exitCode = 1; });