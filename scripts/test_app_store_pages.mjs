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
  const capture = source('scripts/store-screenshots/StoreScreenshotTests.swift');
  assert.ok(capture.includes('"已索引 12 张"'));
  assert.ok(capture.includes('"Prepared 12 licensed photos"'));
  assert.doesNotMatch(source('.github/workflows/app-store-screenshots.yml'), /simctl addmedia/);
});
