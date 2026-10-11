import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = file => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
const sha = value => createHash('sha256').update(value).digest('hex');

export function checkedRevision(directory) {
  const result = spawnSync('git', ['-C', directory, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  assert.ok(!result.error && result.status === 0, `Cannot verify checkout: ${directory}`);
  return result.stdout.trim();
}

export function renderNotices(dependencies, contents, pillow, places, apache) {
  const sections = [
    '片刻寻 - Third-party notices',
    'These licenses apply to the named third-party components, not to the app as a whole. ' +
      'No endorsement by their authors is implied.',
    'SigLIP 2 model and tokenizer\n' +
      'Source: https://huggingface.co/google/siglip2-base-patch16-224/tree/75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2\n' +
      'The pinned model card declares Apache-2.0. The image and text towers were converted ' +
      'to separate FP32 Core ML encoders; bundled tokenizer JSON is unchanged. ' +
      'Reference: Tschannen et al., SigLIP 2: Multilingual Vision-Language Encoders with ' +
      'Improved Semantic Understanding, Localization, and Dense Features (2025), https://arxiv.org/abs/2502.14786.\n\n' +
      apache,
    'Pillow 11.1.0 / Python Imaging Library\n' +
      'Swift image resampling adapts the bilinear numeric rules of Pillow 11.1.0, ' +
      'src/libImaging/Resample.c. Source: https://github.com/python-pillow/Pillow/tree/11.1.0\n\n' + pillow,
    'Offline administrative boundaries\n\n' + places,
  ];
  for (const pkg of dependencies.packages) {
    const notices = contents.get(pkg.identity);
    assert.ok(notices?.length, `Missing notices for ${pkg.identity}`);
    sections.push(`${pkg.identity} ${pkg.version}\nSource: ${pkg.url}\nRevision: ${pkg.revision}\n` +
      `License: ${pkg.license}\n\n` + notices.map(n => `${n.file}\n\n${n.text}`).join('\n\n'));
  }
  return sections.join('\n\n' + '='.repeat(72) + '\n\n').trimEnd() + '\n';
}

export function prepareNotices(checkouts, { check = false, repository = root } = {}) {
  const dependencies = JSON.parse(read(path.join(repository, 'scripts', 'release_dependencies.json')));
  assert.equal(dependencies.schemaVersion, 1);
  const contents = new Map();
  const records = [];
  for (const pkg of dependencies.packages) {
    const directory = path.join(checkouts, pkg.identity);
    assert.equal(checkedRevision(directory), pkg.revision, `Unaudited dependency revision: ${pkg.identity}`);
    const rootNotices = fs.readdirSync(directory).filter(name => /^(?:LICENSE|NOTICE|COPYING)(?:\.[a-z]+)?$/i.test(name)).sort();
    assert.deepEqual(rootNotices, [...pkg.noticeFiles].sort(), `Notice inventory changed: ${pkg.identity}`);
    const notices = pkg.noticeFiles.map(file => ({ file, text: read(path.join(directory, file)) }));
    for (const notice of notices) assert.ok(notice.text.trim().length > 100, `Empty/truncated license: ${pkg.identity}`);
    contents.set(pkg.identity, notices);
    records.push({ ...pkg, notices: notices.map(n => ({ file: n.file, sha256: sha(n.text) })) });
  }
  const header = read(path.join(repository, 'App', 'Inference', 'ImagePreprocessor.swift')).match(/\/\*([\s\S]*?)\*\//);
  assert.ok(header?.[1].includes('Permission to use, copy, modify and distribute'), 'Missing full Pillow permission notice');
  const pillow = header[1].split('\n').map(line => line.replace(/^ /, '')).join('\n').trim();
  const places = read(path.join(repository, 'Resources', 'Places', 'ATTRIBUTION.md'));
  const apache = contents.get('swift-transformers')[0].text;
  const notices = renderNotices(dependencies, contents, pillow, places, apache);
  const report = JSON.stringify({
    schemaVersion: 1,
    scope: dependencies.scope,
    packages: records,
    noticesSHA256: sha(notices),
    sourceAttributionSHA256: sha(places),
    reviewStatus: 'License texts and attribution packaged; upstream CHN/ADM1 provenance remains unresolved. Not legal clearance.',
  }, null, 2) + '\n';
  const output = path.join(repository, 'Resources', 'Legal');
  if (!check) fs.mkdirSync(output, { recursive: true });
  for (const [name, content] of [['ThirdPartyNotices.txt', notices], ['third-party-manifest.json', report]]) {
    const destination = path.join(output, name);
    if (check) assert.equal(read(destination), content, `Stale bundled legal resource: ${name}`);
    else fs.writeFileSync(destination, content);
  }
  return { packages: records.length, noticesSHA256: sha(notices) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2);
    assert.ok(args.length === 1 || (args.length === 2 && args[1] === '--check'),
      'Usage: node scripts/prepare_legal_notices.mjs CHECKOUTS_DIRECTORY [--check]');
    console.log(JSON.stringify(prepareNotices(path.resolve(args[0]), { check: args[1] === '--check' }), null, 2));
  } catch (error) {
    console.error(`Legal notice validation failed: ${error.message}`);
    process.exitCode = 1;
  }
}
