import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { campaignDemoScenes, campaignDemoDisclaimer } from './render_campaign_demo.mjs';
import { pngDimensions } from './package_captures.mjs';

test('full marketing campaign has eight distinct frames including identity and cleaning', () => {
  assert.equal(campaignDemoScenes.length, 8);
  assert.equal(new Set(campaignDemoScenes.map(scene => scene.id)).size, 8);
  assert.equal(campaignDemoScenes[1].id, '02-identity');
  assert.equal(campaignDemoScenes[1].query, '身份证');
  assert.ok(campaignDemoScenes.some(scene => scene.id === '05-cleanup'));
  assert.ok(campaignDemoScenes.some(scene => scene.id === '06-selection'));
  assert.ok(campaignDemoScenes.some(scene => scene.id === '07-private'));
  assert.ok(campaignDemoScenes.every(scene => ['sand', 'peach'].includes(scene.theme)));
  assert.match(campaignDemoScenes[4].title, /拍多了.*留下.*一张/);
  assert.match(campaignDemoScenes[5].title, /留下.*自己选删/);
  assert.doesNotMatch(campaignDemoScenes.map(scene => scene.subtitle).join(' '), /自动删|自动选|自动保留/);
});

test('ad copy is benefits-led and never pretends to be a new device capture', () => {
  const copy = campaignDemoScenes.map(scene => [scene.title, scene.subtitle, scene.query].join(' ')).join('\n');
  assert.doesNotMatch(copy, /第[一二三四五六七八九十0-9]+项|排名|验收|测试|100%|完全不联网/);
  assert.ok(campaignDemoScenes[0].query.length > 30);
  assert.ok(campaignDemoScenes[2].query.includes('北门值班室'));
  assert.ok(campaignDemoDisclaimer.includes('不是新的真机运行截图'));
});

test('exported demo delivers every full-resolution RGB frame and public provenance',
  { skip: !process.env.CAMPAIGN_DEMO_DIR }, () => {
    const output = path.resolve(process.env.CAMPAIGN_DEMO_DIR);
    const manifest = JSON.parse(fs.readFileSync(path.join(output, 'manifest.json')));
    assert.equal(manifest.mode, 'native-ui-demo-composition-not-device-capture');
    assert.deepEqual(manifest.scenes.map(scene => scene.id), campaignDemoScenes.map(scene => scene.id));
    for (const scene of manifest.scenes) {
      assert.equal(scene.file, `${scene.id}.png`);
      assert.deepEqual(pngDimensions(fs.readFileSync(path.join(output, scene.file))), [1320, 2868]);
    }
    assert.deepEqual(pngDimensions(fs.readFileSync(path.join(output, 'overview.png'))), [1320, 1434]);
    const html = fs.readFileSync(path.join(output, 'export.html'), 'utf8');
    assert.equal((html.match(/<article class="poster /g) ?? []).length, 8);
    assert.equal(manifest.searchCompositions.length, 4);
    assert.equal(manifest.nativeCaptures.length, 6);
    for (const [index, composition] of manifest.searchCompositions.entries()) {
      assert.equal(composition.scene, campaignDemoScenes[index].id);
      assert.equal(composition.query, campaignDemoScenes[index].query);
      assert.equal(composition.gridColumns, 5);
      assert.equal(composition.gridGap, 9);
      assert.equal(composition.tileAspectRatio, 1);
      assert.equal(composition.controlsAltered, false);
      assert.ok(html.includes(`data-scene="${composition.scene}"`));
    }
    assert.deepEqual(manifest.searchCompositions[1].files, [1, 2, 3, 4].map(i => `demo-identity-${i}.png`));
    assert.deepEqual(manifest.searchCompositions[2].files, ['demo-menu-1.png']);
    assert.ok(html.includes(`<p>${campaignDemoScenes[0].query}</p>`));
    assert.ok(html.includes('App 原界面 · 搜索结果示意'));
    assert.ok(html.includes('多拍的 6 张'));
    assert.ok(html.includes('留下 1 张'));
    assert.doesNotMatch(html, /class="phone|class="app-title|poster ink/);
    assert.ok(html.includes('功能示意 · 演示素材'));
    assert.ok(html.includes('首次准备模型与语言包可能需要联网'));
    assert.equal(manifest.publicInputHashes.length, 11);
    assert.equal(manifest.sourcesFile, 'sources.json');
    assert.ok(fs.statSync(path.join(output, manifest.sourcesFile)).size > 0);
    assert.ok(fs.readFileSync(path.join(output, 'index.html'), 'utf8').includes(campaignDemoDisclaimer));
  });
