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
