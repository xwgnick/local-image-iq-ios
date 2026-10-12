import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const read = name => fs.readFileSync(new URL(`../docs/app-store/${name}`, import.meta.url), 'utf8');

test('public policies identify the approved operator and working contact link without draft placeholders', () => {
  for (const name of ['privacy.html', 'support.html']) {
    const html = read(name);
    assert.ok(html.includes('谢文戈'));
    assert.ok(html.includes('mailto:xiewenge_neu@163.com'));
    assert.ok(html.includes('90天'));
    assert.ok(html.includes('GitHub'));
    assert.ok(html.includes('href="privacy.html"'));
    assert.ok(html.includes('href="support.html"'));
    assert.ok(html.includes('href="style.css"'));
    assert.doesNotMatch(html, /草稿|待确认|未部署|noindex|<script\b|<form\b/i);
    assert.ok(html.includes('Content-Security-Policy'));
  }
  assert.ok(read('privacy.html').includes('IP 地址'));
  assert.ok(read('privacy.html').includes('github-general-privacy-statement'));
});

test('Pages workflow publishes an explicit small allowlist, not submission notes or the whole docs folder', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/app-store-pages.yml', import.meta.url), 'utf8');
  assert.ok(workflow.includes('workflow_dispatch:'));
  assert.ok(workflow.includes("github.repository == 'xwgnick/local-image-iq-ios'"));
  assert.ok(workflow.includes('cp docs/app-store/privacy.html docs/app-store/support.html docs/app-store/style.css build/public-site/'));
  assert.ok(workflow.includes('cp docs/app-store/support.html build/public-site/index.html'));
  assert.ok(workflow.includes('path: build/public-site'));
  assert.doesNotMatch(workflow, /cp\s+-[^\n]*r|path:\s*docs|metadata\.zh-Hans/);
});

test('store metadata fits Apple text and UTF-8 byte limits without inventing pending account details', () => {
  const metadata = JSON.parse(read('metadata.zh-Hans.json'));
  for (const [field, maximum] of Object.entries({
    name: 30, subtitle: 30, promotionalText: 170, description: 4000,
  })) {
    assert.equal(typeof metadata[field], 'string', field);
    assert.ok([...metadata[field]].length > 0, field);
    assert.ok([...metadata[field]].length <= maximum, field);
  }
  for (const [field, maximum] of Object.entries({ keywords: 100, reviewNotes: 4000 })) {
    assert.equal(typeof metadata[field], 'string', field);
    assert.ok(Buffer.byteLength(metadata[field], 'utf8') > 0, field);
    assert.ok(Buffer.byteLength(metadata[field], 'utf8') <= maximum, field);
  }
  assert.equal(metadata.status, 'draft-not-submitted');
  assert.equal(metadata.requiresSignIn, false);
  assert.equal(metadata.reviewContact, null);
  assert.equal(metadata.copyright, null);
  assert.equal(metadata.privacyPolicyURL, 'https://xwgnick.github.io/local-image-iq-ios/privacy.html');
  assert.equal(metadata.supportURL, 'https://xwgnick.github.io/local-image-iq-ios/support.html');
});

test('photo preparation is confined to the screenshot variant and a named disposable simulator', () => {
  const source = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
  const project = source('project.yml');
  assert.doesNotMatch(project, /StorePhotoPreparation|scripts\/store-screenshots/);
  assert.ok(source('project.store-screenshots.yml').includes('StorePhotoPreparation: [test]'));
  const helper = source('scripts/store-screenshots/StorePhotoPreparationApp.swift');
  assert.ok(helper.includes('#if targetEnvironment(simulator)'));
  assert.ok(helper.includes('^Store-(iphone-medium|iphone-large|ipad-13)-[0-9]+$'));
  assert.ok(helper.includes('arguments[marker + 1] == device'));
  assert.ok(helper.includes('existing.count == 0 || existing.count == 6'));
  assert.ok(helper.includes('PHAsset.fetchAssets(with: nil).count == 0'));
  assert.ok(helper.includes('actualNames.sorted() == names.sorted()'));
  assert.ok(helper.includes('Set(names).count == names.count'));
  assert.ok(helper.includes('await PHPhotoLibrary.requestAuthorization(for: .readWrite)'));
  const capture = source('scripts/store-screenshots/StoreScreenshotTests.swift');
  assert.ok(capture.includes('"已索引 12 张"'));
  assert.ok(capture.includes('"Prepared 12 licensed photos"'));
  assert.ok(capture.includes('app.descendants(matching: .any).matching(identifier: "result-tile-\\(rank)")'));
  assert.doesNotMatch(capture, /app\.buttons\["select-search-results"\]/);
  assert.doesNotMatch(source('.github/workflows/app-store-screenshots.yml'), /simctl (addmedia|privacy)/);
});

test('priority pilot retains actual Chinese queries, an OCR baseline and clearly marked specimen views', () => {
  const source = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
  const scenes = JSON.parse(source('scripts/store-screenshots/priority-scenes.json')).scenes;
  assert.equal(scenes.length, 3);
  assert.ok([...scenes[0].query].length >= 30);
  const capture = source('scripts/store-screenshots/StoreScreenshotTests.swift');
  for (const scene of scenes) {
    assert.ok(capture.includes(`search("${scene.query}"`), scene.id);
    assert.ok(capture.includes(`capture("${scene.id}")`), scene.id);
  }
  assert.ok(capture.indexOf('capture("pilot-ocr-before")') < capture.indexOf('ocr.tap()'));
  assert.ok(capture.includes('"文字索引已更新"'));
  assert.ok(capture.includes('"已识别 11 张"'));
  const assets = source('scripts/store-screenshots/make_pilot.swift');
  assert.ok(assets.includes('NOT A VALID ID'));
  assert.ok(assets.includes('不可用于身份验证'));
  assert.ok(assets.includes('identity-sample-both.png'));
  assert.ok(assets.includes('specimen.draw('));
  assert.doesNotMatch(assets, /头像\\n占位/);
  const preparation = source('scripts/store-screenshots/prepare_pilot.mjs');
  assert.ok(preparation.includes('0837498d3f13f3b7a391d29cccb3e756a8f524a81f406dc302a5930b24094321'));
  assert.ok(preparation.includes('PD-PRC-exempt'));
  assert.ok(preparation.includes('Retain SAMPLE markings'));
  assert.ok(assets.includes('["Q7M2", "R8N3", "S9P4", "T6K5"]'));
  assert.ok(assets.includes('["北门值班室", "松桥路东口", "河畔图书馆", "梧桐街南门"]'));
  assert.ok(capture.includes('["松桥路东口", "河畔图书馆", "梧桐街南门"]'));
  assert.ok(capture.includes('capture("pilot-ocr-before-\\(index + 2)")'));
  assert.ok(capture.includes('capture("pilot-ocr-after-\\(index + 2)")'));
  assert.ok(capture.includes('tap("dismiss-ocr-sync")'));
  assert.doesNotMatch(assets, /[0-9]{18}/);
  const workflow = source('.github/workflows/app-store-screenshots.yml');
  assert.ok(workflow.includes('options: [baseline, priority-pilot]'));
  assert.ok(workflow.includes('testCaptureThreePriorityScenes'));
  assert.ok(workflow.includes('[ "$label" != "iphone-large" ]'));
  assert.ok(workflow.includes('build/store-photos/demo-identity-*.png'));
  const preview = source('scripts/store-screenshots/render_priority_preview.mjs');
  assert.ok(preview.includes('实际搜索前四项'));
  assert.ok(preview.includes('不代表完整结果列表'));
  assert.ok(preview.includes('Leading focus crop must be one contiguous row'));
});
