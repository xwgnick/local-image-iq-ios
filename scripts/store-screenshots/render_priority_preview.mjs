import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { pngDimensions } from './package_captures.mjs';

const root = path.resolve(process.argv[2] ?? '');
assert.equal(path.basename(root), '38213207890', 'Preview uses the reviewed first pilot only');
const allScenes = JSON.parse(fs.readFileSync(new URL('priority-scenes.json', import.meta.url))).scenes;
const scenes = allScenes.slice(0, 1);
const escape = text => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');
function capture(directory, prefix) {
  const attachments = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json')))
    .flatMap(test => test.attachments);
  const matches = attachments.filter(a =>
    a.suggestedHumanReadableName.startsWith(`Store-${prefix}_`) && a.exportedFileName.endsWith('.png'));
  assert.equal(matches.length, 1, prefix);
  assert.equal(matches[0].isAssociatedWithFailure, false);
  const bytes = fs.readFileSync(path.join(directory, matches[0].exportedFileName));
  assert.deepEqual(pngDimensions(bytes), [1320, 2868]);
  const evidence = attachments.filter(a =>
    a.suggestedHumanReadableName.startsWith(`Store-${prefix}-accessibility_`) && a.exportedFileName.endsWith('.txt'));
  assert.equal(evidence.length, 1, `${prefix} accessibility evidence`);
  assert.equal(evidence[0].isAssociatedWithFailure, false);
  return { bytes, hierarchy: fs.readFileSync(path.join(directory, evidence[0].exportedFileName), 'utf8') };
}
function rectangle(hierarchy, rank) {
  const line = hierarchy.split('\n').find(line => line.includes(`identifier: 'result-tile-${rank}'`));
  assert.ok(line, `Missing actual result rank ${rank}`);
  const match = line.match(/\{\{([\d.]+), ([\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}/);
  assert.ok(match, `Missing result rectangle ${rank}`);
  const result = match.slice(1).map(Number).map(value => value * 3);
  assert.ok(result[2] > 0 && result[3] > 0 && result[0] + result[2] <= 1320 && result[1] + result[3] <= 2868);
  return result;
}
function nativeCrop(bytes, viewBox, label) {
  return `<svg xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${escape(label)}" viewBox="${viewBox}"><image href="data:image/png;base64,${bytes.toString('base64')}" width="1320" height="2868"/></svg>`;
}
const sunset = fs.readFileSync(path.resolve('build', 'app-store', 'pilot-sources', 'sunset-pier.jpg'));
assert.equal(createHash('sha256').update(sunset).digest('hex'),
  '9b505bd5d5af1b046add5e9b17a92af5a2ae766ce0e0490974a63f8cc38c0cc4');
const cards = scenes.map((scene, index) => {
  const { bytes, hierarchy } = capture(path.join(root, 'iphone-large'), scene.id);
  const rectangles = Array.from({ length: index === 0 ? 1 : 4 }, (_, rank) => rectangle(hierarchy, rank + 1));
  const left = Math.min(...rectangles.map(r => r[0]));
  const top = Math.min(...rectangles.map(r => r[1]));
  const right = Math.max(...rectangles.map(r => r[0] + r[2]));
  const bottom = Math.max(...rectangles.map(r => r[1] + r[3]));
  assert.ok(rectangles.every(r => r[1] === top), 'Leading focus crop must be one contiguous row');
  const viewBox = index === 0 ? '30 330 1260 246' : `${left} ${top} ${right - left} ${bottom - top}`;
  const native = nativeCrop(bytes, viewBox, index === 0 ? '真实搜索输入栏局部' : '真实结果前四项的连续截图局部，未重排');
  const headline = index === 0 ? '记得那个时刻<br>就能开始找' : '证件照片<br>不必翻遍相册';
  return `<article class="poster ${index === 0 ? 'memory' : 'document'}" id="scene-${index + 1}">
    <header><div class="brand">片刻寻 <span>AI 照片搜索 · 在本机处理</span></div>
    <div class="eyebrow">${index === 0 ? '用记忆中的细节寻找' : '用一个词，找到一类照片'}</div>
    <h1>${headline}</h1>
    <div class="query"><b>试着搜</b><p>${escape(scene.query)}</p></div></header>
    ${index === 0 ? `<figure class="hero"><img alt="本次实际检索排第一的日落照片，单独展示原图" src="data:image/jpeg;base64,${sunset.toString('base64')}"><figcaption>这张照片，在本次实际搜索中排第一</figcaption></figure>` : ''}
    <section class="native">${native}</section>
    <p class="focus-note">${index === 0 ? '真实搜索输入栏 · 对应结果原图见上方' : '实际搜索前四项 · 连续截图局部放大'}</p>
    <footer><strong>${index === 0 ? '把天空、人物、地点，写进同一句描述。' : '少翻相册，多留一点时间。'}</strong>
      <p>${index === 0 ? '实际中文原文检索 · 场景照片来自公开许可素材' : '原创建模演示卡 · 无真实身份信息 · 不可用于身份验证'}</p>
      <small>视觉初稿，未获批准。仅展示搜索输入或前列结果局部，不代表完整结果列表；未重排或替换结果。</small></footer>
  </article>`;
}).join('');
const ocr = allScenes[2];
const proof = ocr.reviewedEvidence;
assert.equal(proof.run, '38219454927', 'OCR uses the reviewed exact-query clean-menu pilot only');
assert.ok(proof.beforeRank > 1 && proof.afterRank === 1, 'OCR example must improve to first');
const ocrRoot = path.join(root, '..', proof.run, 'iphone-large');
const before = capture(ocrRoot, proof.beforeCapture);
const after = capture(ocrRoot, proof.afterCapture);
for (const [shot, enabled] of [[before, 0], [after, 1]]) {
  assert.ok(shot.hierarchy.split('\n').some(line =>
    line.includes("identifier: 'photo-query'") && line.endsWith(`value: ${ocr.query}`)), 'Actual OCR query must match the headline');
  assert.ok(shot.hierarchy.split('\n').some(line =>
    line.includes("identifier: 'photo-text-search-enabled'") && line.endsWith(`value: ${enabled}`)), 'Actual OCR switch state must match the comparison');
}
assert.ok(!after.hierarchy.includes("identifier: 'ocr-sync-open-details'"), 'Do not export OCR update prompt');
rectangle(before.hierarchy, proof.beforeRank);
rectangle(after.hierarchy, proof.afterRank);
const menu = fs.readFileSync(path.join(root, '..', proof.run, 'menu-photos', ocr.expectedTopPhoto));
// AppKit source art may be RGBA; the RGB-only contract still applies to native captures.
assert.ok(menu.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')));
assert.equal(menu.toString('ascii', 12, 16), 'IHDR');
assert.equal(menu[24], 8);
assert.ok([2, 6].includes(menu[25]), 'Menu source must be RGB or RGBA');
assert.deepEqual([menu.readUInt32BE(16), menu.readUInt32BE(20)], [1200, 1600]);
const menuData = menu.toString('base64');
const menuArtwork = `<section class="ocr-art"><img alt="本轮实际命中的原创菜单原图，在应用界面外展示" src="data:image/png;base64,${menuData}">
  <div><p class="eyebrow">从配送备注里<br>找回这张菜单</p><p>同一查询，实际排名</p><strong>第${proof.beforeRank}项 → 第${proof.afterRank}项</strong>
  <p>文字增强关闭 → 开启</p><p class="code">对应菜单<br>${escape(proof.visibleCode)}</p></div></section>
  <figure class="remark"><figcaption>原图配送备注 · 等比局部放大</figcaption>
  <svg xmlns="http://www.w3.org/2000/svg" role="img" aria-label="同一菜单原图中的配送备注，未替换文字" viewBox="100 1260 800 90"><image href="data:image/png;base64,${menuData}" width="1200" height="1600"/></svg></figure>`;
const ocrCard = `<article class="poster ocr" id="scene-3">
  <header><div class="brand">片刻寻 <span>AI 照片搜索 · 在本机处理</span></div>
  <div class="eyebrow">照片里的小字，也能成为线索</div><h1>记住一段文字<br>也能找到照片</h1>
  <div class="query"><b>试着搜配送备注里的地点</b><p>${escape(ocr.query)}</p></div></header>
  ${menuArtwork}
  <section class="native">${nativeCrop(after.bytes, '30 330 1260 430', '真实中文查询及开启的OCR开关')}</section>
  <p class="focus-note">真实搜索输入与开关 · 菜单原图在界面外单独展示</p>
  <footer><strong>把配送备注，也变成搜索线索。</strong><p>同一菜单实测：第${proof.beforeRank}项 → 第${proof.afterRank}项 · 原创演示素材</p>
  <small>视觉初稿，未获批准。排名来自实际开启前后结果；原图与备注在界面外放大，不代表完整列表。</small></footer>
</article>`;
const html = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>片刻寻 · 长查询与OCR视觉初稿</title><style>
*{box-sizing:border-box}body{margin:0;background:#ddd8ce;font-family:"Microsoft YaHei","PingFang SC",sans-serif;color:#292723}
main{display:flex;gap:48px;padding:48px;width:max-content}.poster{width:1320px;height:2868px;background:linear-gradient(145deg,#fffaf0,#efe5d2);overflow:hidden;position:relative;border-radius:0}
header{padding:100px 100px 58px}.brand{font-size:46px;font-weight:700;letter-spacing:5px;color:#826327}.brand span{font-size:27px;letter-spacing:1px;font-weight:400;margin-left:25px;color:#776d5c}
.eyebrow{font-size:38px;margin-top:72px;letter-spacing:4px;color:#8b7349}h1{font-size:132px;line-height:1.13;letter-spacing:-3px;margin:28px 0 56px;font-weight:800}
.query{padding:35px 42px;background:#fffdf8;border:2px solid #dfcfac;border-radius:30px;box-shadow:0 12px 30px #a7823220}
.query b{font-size:28px;color:#98773a}.query p{font-size:42px;line-height:1.55;margin:14px 0 0}
.native{margin:0 90px;overflow:hidden;border:3px solid #cec2aa;border-radius:30px;background:#f6f7f9;box-shadow:0 35px 70px #4a382d24}
.native svg{width:100%;height:auto;display:block}.focus-note{margin:20px 90px;font-size:27px;color:#746b5b}footer{padding:65px 100px}footer strong{font-size:40px;line-height:1.5}footer p{font-size:27px;line-height:1.7;color:#746b5b}
.hero{margin:0 90px 24px}.hero img{display:block;width:100%;height:auto;border-radius:30px}.hero figcaption{font-size:27px;color:#746b5b;padding:18px 0}
.memory footer{padding-top:40px}
.ocr-art{display:flex;gap:45px;margin:0 90px 30px;align-items:center}.ocr-art img{width:550px;height:auto;border:2px solid #dfcfac;border-radius:26px;box-shadow:0 20px 40px #4a382d18}.ocr-art>div{flex:1;min-width:0}.ocr-art .eyebrow{font-size:48px;line-height:1.5;margin:0 0 55px}.ocr-art p{font-size:30px;line-height:1.6;color:#746b5b}.ocr-art strong{font-size:59px;color:#826327;white-space:nowrap}.ocr-art .code{font-size:42px;line-height:1.5;color:#292723}.remark{margin:0 90px 35px}.remark figcaption{font-size:27px;color:#746b5b;margin-bottom:14px}.remark svg{display:block;width:100%;border:2px solid #dfcfac;border-radius:18px}.ocr footer{padding-top:35px}
footer small{font-size:22px;line-height:1.7;color:#8c8172;display:block}.notice{position:fixed;left:12px;bottom:12px;background:#292723;color:white;padding:10px 18px;font-size:14px;border-radius:8px;z-index:2}
</style><main>${cards}${ocrCard}</main><aside class="notice">长查询与OCR初稿 · 身份证原文检索相关性未达标，该图不展示</aside></html>`;
const output = path.join(root, 'priority-preview.html');
fs.writeFileSync(output, html);
fs.writeFileSync(path.join(root, 'priority-preview-export.html'), html.replace(/<aside class="notice">.*?<\/aside>/, ''));
console.log(JSON.stringify({ output, scenes: 2, identityStatus: 'Exact specimen query verified, but relevance rejected; identity poster withheld', ocrStatus: `Reviewed ${ocr.query}: rank ${proof.beforeRank} to ${proof.afterRank}` }));
