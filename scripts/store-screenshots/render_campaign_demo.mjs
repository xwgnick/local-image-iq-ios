import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { pngDimensions } from './package_captures.mjs';

export const campaignDemoScenes = [
  { id: '01-memory', title: '心中重要的一刻<br>凭记忆找回', subtitle: '记得那个瞬间，就从记忆里的画面找。',
    query: '猫猫跳起来扑玩具', capture: 'memory', theme: 'sand' },
  { id: '02-cleanup', title: '同一画面拍多了<br>留下最满意的一张', subtitle: '相似照片放一起，清掉多余的，少占相册。', capture: 'cleanup', theme: 'peach' },
  { id: '03-identity', title: '想找重要证件？<br>直接搜索就行', subtitle: '不用翻遍相册，输入关键词开始找。', query: '身份证', capture: 'identity', theme: 'sand' },
  { id: '04-text', title: '照片里的文字<br>也能成为线索', subtitle: '记住一句备注，找回那张照片。', query: '北门值班室', capture: 'text', theme: 'peach' },
  { id: '05-location', title: '去过的地方<br>都替你记着', subtitle: '说出地名，那天的照片就回来了。',
    detail: '输入「三亚的海」，那年的日落就回来了。', query: '三亚的海', capture: 'location', theme: 'sand' },
  { id: '06-private', title: '照片不出手机<br>AI 照样帮你找', subtitle: '你的照片，在本机处理。', theme: 'sand' },
  { id: '07-selection', title: '挑一张留下<br>其余自己选删', subtitle: '放大对比、滑动选择，删前由你确认。', capture: 'selection', theme: 'sand' },
  { id: '08-brand', title: '找到想看的<br>留下值得的', subtitle: '找回记忆里的照片，多拍的只留想要的。', theme: 'sand' },
];
export const campaignDemoDisclaimer = '当前 App 原生界面营销演示：底图由当前生产视图在模拟器原生渲染，元数据、查询文字、照片结果和清理分组为演示，不是新的真机运行截图，不代表真实模型、OCR 或 GPS 检索验收；最终商店素材另行确认。';

export function verifyCurrentCaptureSource(source, appUITree) {
  assert.equal(source.modelFree, true);
  assert.equal(source.testPassed, true, 'Current native capture test must pass');
  assert.match(source.sha, /^[a-f0-9]{40}$/);
  assert.match(source.run, /^\d+$/);
  assert.equal(source.appUITree, appUITree, 'Native UI capture is stale; regenerate from the current App/UI tree');
}

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const escape = value => value.replace(/[&<>"']/g, character =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);

export function renderCampaignDemo() {
  const nativeDirectory = path.resolve(process.env.CAMPAIGN_NATIVE_DIR ?? path.join('build', 'app-store', 'current-native-ui'));
  assert.ok(fs.existsSync(path.join(nativeDirectory, 'source.json')),
    'Current native UI evidence is required. Run current-store-ui.yml; old screenshot fallback is forbidden.');
  execFileSync('git', ['diff', '--quiet', 'HEAD', '--', 'App/UI']);
  const source = JSON.parse(fs.readFileSync(path.join(nativeDirectory, 'source.json')));
  verifyCurrentCaptureSource(source, execFileSync('git', ['rev-parse', 'HEAD:App/UI'], { encoding: 'utf8' }).trim());
  const attachments = JSON.parse(fs.readFileSync(path.join(nativeDirectory, 'manifest.json'))).flatMap(test => test.attachments);
  const attachment = name => {
    const matches = attachments.filter(item => item.suggestedHumanReadableName.startsWith(`Current-${name}_`));
    assert.equal(matches.length, 1, `Expected exactly one current native ${name}`);
    assert.equal(matches[0].isAssociatedWithFailure, false, `Failed native capture: ${name}`);
    const file = matches[0].exportedFileName;
    assert.equal(path.basename(file), file);
    return { file, bytes: fs.readFileSync(path.join(nativeDirectory, file)) };
  };
  const layout = JSON.parse(attachment('layout').bytes);
  const captures = new Map();
  const nativeCaptures = [];
  for (const name of ['memory', 'identity', 'text', 'location', 'cleanup', 'selection']) {
    const record = layout.find(item => item.name === name);
    assert.ok(record, `Missing layout metadata: ${name}`);
    const { file, bytes } = attachment(name);
    assert.deepEqual(pngDimensions(bytes), [1320, 2868]);
    const capture = { ...record, file, sha256: hash(bytes) };
    captures.set(name, { ...capture, uri: `data:image/png;base64,${bytes.toString('base64')}` });
    nativeCaptures.push(capture);
  }

  const kit = path.resolve('build', 'app-store', 'Piankexun-device-shoot-kit');
  const manifest = JSON.parse(fs.readFileSync(path.join(kit, 'manifest.json')));
  assert.equal(manifest.photos.length, 11);
  const assets = new Map();
  function loadAsset(directory, item) {
    assert.equal(path.basename(item.name), item.name);
    const bytes = fs.readFileSync(path.join(directory, item.name));
    assert.equal(hash(bytes), item.sha256, item.name);
    assets.set(item.name, `data:${item.name.endsWith('.png') ? 'image/png' : 'image/jpeg'};base64,${bytes.toString('base64')}`);
  }
  for (const item of manifest.photos) loadAsset(path.join(kit, 'photos'), item);
  const extraDirectory = path.resolve('build', 'app-store', 'campaign-assets');
  const extraManifest = JSON.parse(fs.readFileSync(path.join(extraDirectory, 'manifest.json')));
  assert.equal(extraManifest.photos.length, 21);
  for (const item of extraManifest.photos) {
    assert.match(item.license, /^(Public domain|CC0|CC BY [0-9.]+)$/);
    loadAsset(extraDirectory, item);
  }
  const derivedArtwork = [];
  const identityFiles = [1, 2, 3, 4].map(index => `demo-identity-${index}.png`);
  const backgrounds = ['#ddd3c4', '#c6cbd0', '#e7d6be', '#bfd0dc', '#d8dfd2'];
  for (let index = 0; index < 5; index++) {
    const name = `identity-view-${index + 5}.svg`;
    const base = identityFiles[index % 4];
    const angle = [-6, 5, -3, 7, -5][index];
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1100"><rect width="1600" height="1100" fill="${backgrounds[index]}"/><image href="${assets.get(base)}" x="160" y="110" width="1280" height="880" transform="rotate(${angle} 800 550)"/></svg>`;
    assets.set(name, `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`);
    derivedArtwork.push({ name, base, description: 'Staged view of the same public SAMPLE; not a real identity. Sample markings retained.' });
  }
  identityFiles.push(...derivedArtwork.map(item => item.name));
  const orderBytes = fs.readFileSync(new URL('./campaign-order.svg', import.meta.url));
  const order = orderBytes.toString('utf8');
  assets.set('campaign-order.svg', `data:image/svg+xml;base64,${orderBytes.toString('base64')}`);
  const highlightLine = '<text x="175" y="1080" font-size="46">请送到北门值班室，</text>';
  assert.ok(order.includes(highlightLine), 'Receipt highlight must track the actual source text');
  const highlighted = order.replace(highlightLine,
    '<rect x="309" y="1033" width="242" height="62" rx="9" fill="#ffe18a"/><text x="175" y="1080" font-size="46">请送到<tspan font-weight="700">北门值班室</tspan>，</text>');
  assets.set('campaign-order-highlight.svg', `data:image/svg+xml;base64,${Buffer.from(highlighted).toString('base64')}`);
  derivedArtwork.push({ name: 'campaign-order.svg', sha256: hash(orderBytes),
    description: 'Original generic delivery receipt; no real personal information or transaction.' });
  derivedArtwork.push({ name: 'campaign-order-highlight.svg', base: 'campaign-order.svg',
    description: 'External marketing callout highlighting the existing 北门值班室 text, not an in-app highlighting feature.' });
  const catFiles = ['cat-play-08.png', 'cat-play-03.jpg', 'cat-play-02.jpg', 'cat-play-06.jpg', 'cat-play-01.jpg', 'cat-play-04.jpg'];
  const locationFiles = extraManifest.photos.filter(item => item.category === 'sanya').map(item => item.name);
  assert.equal(locationFiles.length, 6);
  const image = (name, className = '', alt = '公开演示素材') => {
    assert.ok(assets.has(name), `Missing demo artwork: ${name}`);
    return `<img class="${className}" src="${assets.get(name)}" alt="${escape(alt)}">`;
  };
  const searchCompositions = [];
  function searchScreen(scene, files) {
    const capture = captures.get(scene.capture);
    const queryOverride = capture.query !== scene.query;
    if (queryOverride) {
      assert.equal(source.run, '38727436009', 'Query artwork coordinates require the verified native capture');
      assert.equal(capture.query, { memory: '那只跳起来扑玩具的小猫', identity: '证件' }[scene.capture],
        'Only the two approved query-value revisions may be composed');
    }
    assert.equal(capture.resultCount, files.length);
    assert.equal(capture.gridColumns, 3);
    assert.equal(capture.gridGap, 9);
    assert.equal(capture.ocr, scene.capture === 'text');
    assert.equal(capture.location, scene.capture === 'location');
    const side = (capture.gridWidth - capture.gridGap * 2) / 3;
    const cropBottom = Math.min(2680, capture.gridY + Math.ceil(files.length / 3) * (side + capture.gridGap) + 55);
    searchCompositions.push({ scene: scene.id, capture: scene.capture, query: scene.query, files,
      gridColumns: 3, gridGap: 9, tileAspectRatio: 1, controlsAltered: false, queryOverride,
      nativeQuery: capture.query,
      gridX: capture.gridX, gridY: capture.gridY, side });
    // These bounds cover only text inside the verified capture's white field.
    const queryValue = queryOverride
      ? `<g data-composed-query="${escape(scene.query)}"><rect x="226" y="400" width="730" height="90" fill="#fff"/><text x="235" y="461" font-size="51" fill="#1c232b">${escape(scene.query)}</text></g>` : '';
    const tiles = files.map((file, offset) => {
      assert.ok(assets.has(file), file);
      const x = capture.gridX + (offset % 3) * (side + capture.gridGap);
      const y = capture.gridY + Math.floor(offset / 3) * (side + capture.gridGap);
      const clip = `${scene.id}-tile-${offset}`;
      return `<defs><clipPath id="${clip}"><rect x="${x}" y="${y}" width="${side}" height="${side}" rx="18"/></clipPath></defs><image href="${assets.get(file)}" x="${x}" y="${y}" width="${side}" height="${side}" preserveAspectRatio="xMidYMid slice" clip-path="url(#${clip})"/><rect x="${x}" y="${y}" width="${side}" height="${side}" rx="18" fill="none" stroke="#dfe3e9" stroke-width="3"/>`;
    }).join('');
    return `<div class="native-window"><svg role="img" aria-label="当前 App 原生界面，查询文字与照片结果为演示合成" data-scene="${scene.id}" viewBox="0 100 1320 ${cropBottom - 100}" xmlns="http://www.w3.org/2000/svg"><image href="${capture.uri}" width="1320" height="2868"/>${queryValue}${tiles}</svg></div>`;
  }
  function cleanupCrop(name, box) {
    return `<svg role="img" aria-label="当前原生清理界面，演示分组与公开素材" viewBox="${box}" xmlns="http://www.w3.org/2000/svg"><image href="${captures.get(name).uri}" width="1320" height="2868"/></svg>`;
  }
  const stage = (screen, art = '') => `<div class="search-stage">${screen}${art}</div>`;
  const bodies = [
    stage(searchScreen(campaignDemoScenes[0], catFiles)),
    `<div class="cleanup-demo"><div class="cleanup-window">${cleanupCrop('cleanup', '0 120 1320 1650')}</div><div class="keep-story"><div><span>多拍的 6 张</span><div class="burst">${Array.from({ length: 6 }, () => image('distractor-cat.png')).join('')}</div></div><b>→</b><div class="keeper"><span>留下 1 张</span>${image('distractor-cat.png')}</div></div><p>把多余的清掉，相册更清爽。</p></div>`,
    stage(searchScreen(campaignDemoScenes[2], identityFiles), '<div class="specimen-note">公开证件样本 · 非真人证件</div>'),
    stage(searchScreen(campaignDemoScenes[3], ['campaign-order.svg']),
      `<div class="search-art text-art">${image('campaign-order-highlight.svg')}<div class="text-zoom"><span>配送备注 · 匹配文字高亮示意</span><svg role="img" aria-label="配送备注中的北门值班室高亮放大" viewBox="120 950 960 300" xmlns="http://www.w3.org/2000/svg"><image href="${assets.get('campaign-order-highlight.svg')}" width="1200" height="1600"/></svg></div></div>`),
    stage(searchScreen(campaignDemoScenes[4], locationFiles),
      `<div class="location-memory">${image('sanya-01.jpg', '', '三亚湾日落 · 公开演示照片')}<div><strong>三亚的海</strong><span>那年的日落，也有了线索。</span></div></div><p class="location-requirement">需开启地点增强；取决于照片定位信息与离线地点包覆盖，不使用实时位置。</p>`),
    `<div class="private-stage"><div class="private-collage">${image('cat-play-08.png')}${image('demo-identity-1.png')}${image('campaign-order.svg')}</div><div class="lock"><svg viewBox="0 0 120 140" aria-hidden="true"><path d="M30 60V38a30 30 0 0 1 60 0v22"/><rect x="15" y="55" width="90" height="70" rx="15"/><circle cx="60" cy="85" r="5"/><path d="M60 90v15"/></svg></div><div class="private-copy"><strong>本机 AI 检索</strong><p>照片内容在本机分析<br>搜索不必交出私人相册</p></div></div>`,
    `<div class="cleanup-demo"><div class="cleanup-window detail">${cleanupCrop('selection', '0 120 1320 1650')}</div><div class="gesture"><span class="gesture-line"></span><span>滑动选中多余的照片</span></div><div class="benefit-tags"><span>放大对比</span><span>选中后删除</span></div><p>满意的留下，多余的自己选删。</p></div>`,
    `<div class="brand-stage"><div class="wordmark">片刻寻</div><div class="brand-collage">${image('sanya-01.jpg')}${image('cat-play-08.png')}${image('campaign-order.svg')}</div><div class="brand-actions"><span>凭记忆搜照片</span><span>多拍的，只留想要的</span></div></div>`,
  ];
  const posters = campaignDemoScenes.map((scene, index) => `<article class="poster ${scene.theme}" id="${scene.id}">
    <header><div class="brand">片刻寻 <span>AI 搜照片与相似清理</span></div><h1>${scene.title}</h1><p class="subtitle">${scene.subtitle}</p>${scene.detail ? `<p class="detail-copy">${scene.detail}</p>` : ''}</header>
    <section class="visual">${bodies[index]}</section><footer><span>${scene.query ? '当前 App 原界面 · 搜索结果示意' : scene.id === '06-private' ? '首次准备模型与语言包可能需要联网' : '功能示意 · 演示素材'}</span><b>找到想看的，留下值得的。</b></footer></article>`).join('');
  const style = `
*{box-sizing:border-box}body{margin:0;background:#ddd9d0;color:#292723;font-family:"Microsoft YaHei","PingFang SC",sans-serif}main{display:grid;grid-template-columns:repeat(4,1320px);width:5280px;gap:0}.poster{width:1320px;height:2868px;overflow:hidden;position:relative;background:radial-gradient(ellipse at 80% 65%,#e6cb9860,transparent 60%),#fbf5e9}.poster.peach{background:radial-gradient(ellipse at 15% 60%,#f1cbbb70,transparent 65%),#f7eee7}
header{padding:90px 90px 0;height:650px}.brand{font-size:42px;font-weight:700;letter-spacing:5px;color:#846327}.brand span{font-size:25px;font-weight:400;letter-spacing:2px;margin-left:20px;color:#827764}h1{font-size:124px;line-height:1.16;letter-spacing:-4px;margin:80px 0 30px;font-weight:800}.subtitle{font-size:38px;line-height:1.6;margin:0;color:#87755b}.detail-copy{font-size:30px;line-height:1.6;margin:12px 0 0;color:#92723a}
.visual{height:1900px;position:relative;display:flex;align-items:center;justify-content:center;padding:20px 90px 0}.search-stage{position:relative;width:100%;height:100%}.native-window{width:1080px;position:absolute;left:30px;top:30px;background:#f7f8fa;border:10px solid #292d2b;border-radius:48px;overflow:hidden;box-shadow:0 30px 65px #352b2725}.native-window svg{display:block;width:100%;height:auto}[id="03-identity"] .native-window{width:1000px;left:70px;top:10px}[id="04-text"] .native-window{width:900px;left:120px}[id="05-location"] .native-window{width:880px;left:130px}.specimen-note{position:absolute;bottom:0;left:0;right:0;text-align:center;font-size:28px;color:#92723a}
.search-art{position:absolute;left:70px;right:0;bottom:10px;padding:18px;background:#fffaf0;border:2px solid #d7c6a5;border-radius:32px;box-shadow:0 20px 45px #352b2730;transform:rotate(-2deg)}.text-art{height:1160px}.text-art>img{display:block;width:100%;height:1120px;object-fit:contain;border-radius:20px}.text-zoom{position:absolute;bottom:0;left:-35px;right:-10px;padding:26px 32px;background:#fffaf0;border:3px solid #c5a363;border-radius:28px;box-shadow:0 20px 45px #28200d30;color:#403827}.text-zoom>span{font-size:26px;color:#92723a;display:block;margin-bottom:10px}.text-zoom svg{display:block;width:100%;height:auto}
.cleanup-demo{width:100%;color:#403827}.cleanup-window{background:#f6f7f9;border:12px solid #292d2b;border-radius:60px;overflow:hidden;box-shadow:0 35px 75px #352b2730;transform:rotate(-1deg)}.cleanup-window svg{display:block;width:100%;height:auto}.cleanup-window.detail{transform:rotate(1deg)}.benefit-tags{display:flex;justify-content:center;gap:25px;margin-top:55px}.benefit-tags span{font-size:35px;background:#fff9ef;border:2px solid #d9c69d;border-radius:40px;padding:20px 30px}.cleanup-demo>p{font-size:51px;line-height:1.5;text-align:center;margin:40px 0 0;font-weight:700}.gesture{display:flex;align-items:center;justify-content:center;gap:30px;margin-top:55px;font-size:34px;color:#8b6b31}.gesture-line{width:250px;height:8px;background:#b69455;border-radius:10px;position:relative}.gesture-line:before,.gesture-line:after{content:"";position:absolute;width:35px;height:35px;background:#fff8e9;border:5px solid #b69455;border-radius:50%;top:-13px}.gesture-line:before{left:0}.gesture-line:after{right:0}.keep-story{display:flex;align-items:center;justify-content:center;gap:30px;margin-top:55px}.keep-story span{display:block;font-size:36px;text-align:center;margin-bottom:22px;color:#87662b}.burst{display:flex;gap:8px}.burst img{width:100px;height:140px;object-fit:cover;border-radius:14px;opacity:.55}.keep-story>b{font-size:64px;color:#9b793f}.keeper img{display:block;width:220px;height:220px;object-fit:cover;border:5px solid #b99550;border-radius:24px}
.location-memory{position:absolute;left:35px;right:35px;bottom:90px;border:12px solid #fffaf0;border-radius:28px;overflow:hidden;box-shadow:0 20px 45px #352b2725}.location-memory>img{display:block;width:100%;height:360px;object-fit:cover}.location-memory>div{position:absolute;left:0;right:0;bottom:0;padding:30px;background:linear-gradient(transparent,#000a);color:white;display:flex;flex-direction:column;gap:12px}.location-memory strong{font-size:48px}.location-memory span{font-size:30px}.location-requirement{position:absolute;left:35px;right:35px;bottom:0;font-size:25px;line-height:1.6;margin:0;color:#92723a}
.private-stage{width:100%;height:1700px;position:relative}.private-collage{display:grid;grid-template-columns:1fr 1fr;gap:22px;transform:rotate(-4deg)}.private-collage img{width:100%;height:540px;object-fit:cover;border-radius:30px}.private-collage img:first-child{grid-column:span 2;width:100%;height:580px}.lock{position:absolute;top:430px;left:calc(50% - 235px);width:470px;height:470px;border-radius:100px;background:#e4bf70;box-shadow:0 30px 65px #352b2730;display:flex;align-items:center;justify-content:center;transform:rotate(8deg)}.lock svg{width:230px;height:270px;fill:none;stroke:#4e3e1a;stroke-width:9;stroke-linecap:round;stroke-linejoin:round}.private-copy{position:absolute;top:1340px;left:0;right:0;text-align:center}.private-copy strong{font-size:76px;color:#8b6b35}.private-copy p{font-size:43px;line-height:1.7;color:#8a7c67}
.brand-stage{width:100%;height:1600px;position:relative}.wordmark{font-size:150px;font-weight:800;color:#8b6b35;text-align:center;letter-spacing:14px;margin-bottom:55px}.brand-collage{display:grid;grid-template-columns:1fr 1fr;gap:22px;transform:rotate(-3deg)}.brand-collage img{width:100%;height:500px;object-fit:cover;border-radius:30px}.brand-collage img:first-child{grid-column:span 2;height:570px}.brand-actions{display:flex;justify-content:center;gap:24px;margin-top:75px}.brand-actions span{font-size:31px;border:2px solid #d9c69d;border-radius:40px;background:#fff9ef;padding:22px 30px}
footer{position:absolute;bottom:75px;left:90px;right:90px;display:flex;flex-direction:column;gap:22px}footer span{font-size:25px;color:#a38f6c}footer b{font-size:31px;letter-spacing:3px;color:#8b6b35}`;
  const html = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>片刻寻 · 当前界面八张营销 Demo</title><style>${style}</style><main>${posters}</main></html>`;
  const reviewStyle = `body{background:#dcd8cf}.review-note{max-width:1350px;margin:24px;font-size:18px;line-height:1.7;color:#494238}.review-note strong{display:block;font-size:28px}main{display:flex;flex-wrap:wrap;gap:24px;padding:24px;width:100%}.poster{zoom:.27}@media(max-width:800px){.poster{zoom:.22}}@media(max-width:600px){main{padding:12px;gap:12px}.poster{zoom:.25}}`;
  const review = html.replace('</style>', `${reviewStyle}</style>`).replace('<main>', `<aside class="review-note"><strong>片刻寻 · 当前界面八张营销 Demo</strong>${campaignDemoDisclaimer}<br>顺序：猫猫记忆、相似清理、重要证件、OCR、三亚地点、本机隐私、手动选删、品牌。 <a href="credits.html">照片来源与署名</a></aside><main>`);
  const output = path.resolve('build', 'app-store', 'campaign-demo');
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'export.html'), html);
  fs.writeFileSync(path.join(output, 'index.html'), review);
  const sources = JSON.parse(fs.readFileSync(path.join(kit, 'sources.json')));
  sources.license = 'Per-source public-domain/CC0/CC BY; original demonstration artwork';
  sources.additionalPhotos = extraManifest.photos;
  sources.derivedArtwork = derivedArtwork;
  sources.usage = campaignDemoDisclaimer;
  fs.writeFileSync(path.join(output, 'sources.json'), JSON.stringify(sources, null, 2) + '\n');
  const credits = extraManifest.photos.map(item => `<li><a href="${escape(item.sourcePage)}">${escape(item.title)}</a> — ${escape(item.author)} — ${escape(item.license)}${item.licenseUrl ? ` (<a href="${escape(item.licenseUrl)}">许可</a>)` : ''}；${escape(item.modifications)}</li>`).join('');
  fs.writeFileSync(path.join(output, 'credits.html'), `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>演示照片来源与署名</title><body><h1>照片来源与署名</h1><p>公开照片按各自许可使用；仅缩放、裁剪及外部营销高亮。不是私人相册或真实检索记录。</p><ul>${credits}</ul><p>原有公开证件样本、CC0 清理照片及原创订单见 <a href="sources.json">完整来源清单</a>。</p></body></html>`);
  fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
    mode: 'current-native-ui-demo-composition-not-device-capture', size: [1320, 2868],
    disclaimer: campaignDemoDisclaimer, nativeSource: source,
    scenes: campaignDemoScenes.map(scene => ({ ...scene, file: `${scene.id}.png` })),
    sourcesFile: 'sources.json', publicInputHashes: manifest.photos,
    additionalInputHashes: extraManifest.photos, derivedArtwork, nativeCaptures, searchCompositions,
    artwork: 'Current production native UI. Search pixels are clearly labelled compositions. Cleanup grouping is synthetic with licensed pixels. OCR highlight is external marketing art, not a claimed app feature. No real model/GPS/OCR validation.',
  }, null, 2) + '\n');
  return { output, scenes: campaignDemoScenes.length, mode: 'current-native-marketing-demo', source: source.sha };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(renderCampaignDemo()));
}
