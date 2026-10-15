import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { campaignDemoScenes, campaignDemoDisclaimer, verifyCurrentCaptureSource } from './render_campaign_demo.mjs';
import { pngDimensions } from './package_captures.mjs';

test('eight frames follow the owner order and exact revised copy', () => {
  assert.deepEqual(campaignDemoScenes.map(scene => scene.id), [
    '01-memory', '02-cleanup', '03-identity', '04-text',
    '05-location', '06-private', '07-selection', '08-brand',
  ]);
  assert.equal(campaignDemoScenes[0].title, '心中重要的一刻<br>凭记忆找回');
  assert.match(campaignDemoScenes[0].query, /小猫/);
  assert.match(campaignDemoScenes[1].title, /同一画面拍多了.*留下最满意的一张/);
  assert.equal(campaignDemoScenes[2].title, '想找重要证件？<br>直接搜索就行');
  assert.equal(campaignDemoScenes[2].query, '证件');
  assert.doesNotMatch(campaignDemoScenes[2].title, /身份证/);
  assert.equal(campaignDemoScenes[3].query, '北门值班室');
  assert.equal(campaignDemoScenes[4].title, '去过的地方<br>都替你记着');
  assert.equal(campaignDemoScenes[4].subtitle, '说出地名，那天的照片就回来了。');
  assert.equal(campaignDemoScenes[4].detail, '输入「三亚的海」，那年的日落就回来了。');
  assert.equal(campaignDemoScenes[4].query, '三亚的海');
  assert.equal(campaignDemoScenes[5].title, '照片不出手机<br>AI 照样帮你找');
  assert.ok(campaignDemoScenes.every(scene => ['sand', 'peach'].includes(scene.theme)));
});

test('marketing never claims automatic deletion, new phone captures or search verification', () => {
  const copy = campaignDemoScenes.map(scene => [scene.title, scene.subtitle, scene.query].join(' ')).join('\n');
  assert.doesNotMatch(copy, /自动删|自动选|自动保留|100%|完全不联网|绿眼睛|棕色条纹/);
  assert.ok(campaignDemoDisclaimer.includes('不是新的真机运行截图'));
  assert.ok(campaignDemoDisclaimer.includes('不代表真实模型、OCR 或 GPS 检索验收'));
});

test('native evidence rejects stale UI and unvalidated capture runs', () => {
  const tree = 'a'.repeat(40);
  const source = { modelFree: true, testPassed: true, sha: 'b'.repeat(40), run: '123456', appUITree: tree };
  assert.doesNotThrow(() => verifyCurrentCaptureSource(source, tree));
  assert.throws(() => verifyCurrentCaptureSource(source, 'c'.repeat(40)), /stale/);
  assert.throws(() => verifyCurrentCaptureSource({ ...source, testPassed: false }, tree), /must pass/);
  assert.throws(() => verifyCurrentCaptureSource({ ...source, run: 'unknown' }, tree));
});

test('receipt highlight targets existing delivery text without inventing a transaction', () => {
  const order = fs.readFileSync(new URL('./campaign-order.svg', import.meta.url), 'utf8');
  assert.ok(order.includes('外卖订单'));
  assert.ok(order.includes('<text x="175" y="1080" font-size="46">请送到北门值班室，</text>'));
  assert.ok(order.includes('演示订单'));
  assert.doesNotMatch(order, /片刻小馆|Q7M2/);
  const renderer = fs.readFileSync(new URL('./render_campaign_demo.mjs', import.meta.url), 'utf8');
  assert.ok(renderer.includes('width:470px;height:470px'));
  assert.ok(renderer.includes('北门值班室高亮放大'));
  assert.ok(renderer.includes('fill="#ffe18a"'));
  assert.ok(renderer.includes('.text-art{height:1160px}'));
  assert.doesNotMatch(renderer, /38219454927|38207709838|queryOverride = true/);
});

test('current native workflow is model-free and never signs or exports an IPA', () => {
  const workflow = fs.readFileSync(new URL('../../.github/workflows/current-store-ui.yml', import.meta.url), 'utf8');
  assert.ok(workflow.includes("IMAGEIQ_REQUIRE_MODELS: '0'"));
  assert.ok(workflow.includes('project.store-ui.yml'));
  assert.ok(workflow.includes('LocalImageIQTests/CurrentCampaignCaptureTests'));
  assert.doesNotMatch(workflow, /export_models|exportArchive|upload-app|testflight\.yml|\.p12/);
  const capture = fs.readFileSync(new URL('./CurrentCampaignCaptureTests.swift', import.meta.url), 'utf8');
  assert.ok(capture.includes('"photoTextSearchEnabled.v1"'));
  assert.ok(capture.includes('"三亚的海", 6, false, true'));
  assert.ok(capture.includes('"那只跳起来扑玩具的小猫", 6, false, false'));
  assert.ok(capture.includes('ContentView(state: state'));
  assert.ok(capture.includes('let cleanup = try await controlsFixture(in: self, sizes: [6, 6])'));
  assert.ok(capture.includes('SimilarPhotoCleanupSheet(state: cleanup.cleanup'));
  assert.doesNotMatch(capture, /requestAuthorization|PHAssetChangeRequest|CoreMLEncoders\(/);
});

test('exported campaign contains eight RGB frames with matching current native geometry and provenance',
  { skip: !process.env.CAMPAIGN_DEMO_DIR }, () => {
    const output = path.resolve(process.env.CAMPAIGN_DEMO_DIR);
    const manifest = JSON.parse(fs.readFileSync(path.join(output, 'manifest.json')));
    assert.equal(manifest.mode, 'current-native-ui-demo-composition-not-device-capture');
    assert.equal(manifest.nativeSource.testPassed, true);
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
    const searchScenes = campaignDemoScenes.filter(scene => scene.query);
    for (const [index, composition] of manifest.searchCompositions.entries()) {
      assert.equal(composition.scene, searchScenes[index].id);
      assert.equal(composition.query, searchScenes[index].query);
      assert.equal(composition.gridColumns, 3);
      assert.equal(composition.gridGap, 9);
      assert.equal(composition.tileAspectRatio, 1);
      assert.equal(composition.controlsAltered, false);
      assert.equal(composition.queryOverride, false);
      assert.ok(html.includes(`data-scene="${composition.scene}"`));
      assert.equal(new Set(composition.files).size, composition.files.length);
    }
    assert.deepEqual(manifest.searchCompositions.map(item => item.files.length), [6, 9, 1, 6]);
    assert.ok(manifest.searchCompositions[0].files.every(name => name.startsWith('cat-play-')));
    assert.deepEqual(manifest.searchCompositions[2].files, ['campaign-order.svg']);
    const sanya = manifest.additionalInputHashes.filter(photo => photo.category === 'sanya');
    assert.equal(sanya.length, 6);
    assert.deepEqual(manifest.searchCompositions[3].files, sanya.map(photo => photo.name));
    assert.equal(manifest.additionalInputHashes.length, 21);
    for (const photo of manifest.additionalInputHashes) {
      assert.match(photo.license, /^(Public domain|CC0|CC BY [0-9.]+)$/);
      assert.ok(photo.author.length > 0);
      assert.ok(photo.sourcePage.startsWith('https://commons.wikimedia.org/'));
    }
    assert.ok(html.includes('需开启地点增强；取决于照片定位信息与离线地点包覆盖，不使用实时位置。'));
    assert.ok(html.includes('匹配文字高亮示意'));
    assert.ok(manifest.derivedArtwork.some(item => item.name === 'campaign-order-highlight.svg'));
    assert.ok(html.includes('多拍的 6 张'));
    assert.ok(html.includes('留下 1 张'));
    assert.ok(html.includes('首次准备模型与语言包可能需要联网'));
    assert.ok(fs.readFileSync(path.join(output, 'credits.html'), 'utf8').includes('三亞灣日落5.jpg'));
    assert.ok(fs.readFileSync(path.join(output, 'index.html'), 'utf8').includes(campaignDemoDisclaimer));
  });
