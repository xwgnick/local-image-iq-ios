import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { pngDimensions } from './package_captures.mjs';

export const campaignDemoScenes = [
  { id: '01-memory', title: '那一刻<br>凭记忆找回来', subtitle: '天空、人物、地点，一句话说清楚。',
    query: '傍晚的海边，粉紫色和橙色的天空，两个人站在水边，身后有一座长长的栈桥', theme: 'sand' },
  { id: '02-identity', title: '身份证照片<br>不必翻遍相册', subtitle: '记得是什么，就从这个词开始找。', query: '身份证', theme: 'sand' },
  { id: '03-text', title: '照片里的文字<br>也能成为线索', subtitle: '记住一句备注，找回那张照片。', query: '北门值班室', theme: 'peach' },
  { id: '04-object', title: '记住颜色和样子<br>也能找到它', subtitle: '不用记文件名，也不用提前打标签。',
    query: '绿眼睛、棕色条纹的猫', theme: 'sand' },
  { id: '05-cleanup', title: '同一画面拍多了<br>留下最满意的一张', subtitle: '相似照片放一起，清掉多余的，少占相册。', theme: 'peach' },
  { id: '06-selection', title: '挑一张留下<br>其余自己选删', subtitle: '放大对比、滑动选择，删前由你确认。', theme: 'sand' },
  { id: '07-private', title: '你的照片<br>在本机处理', subtitle: '不上传照片到 AI 服务器。', theme: 'sand' },
  { id: '08-brand', title: '找到想看的<br>留下值得的', subtitle: '找回记忆里的照片，多拍的只留想要的。', theme: 'sand' },
];
export const campaignDemoDisclaimer = '经确认的营销演示合成：使用 App 原生界面底图，搜索查询与结果为示意，不是新的真机运行截图；最终商店素材另行确认。';

export function renderCampaignDemo() {
  const kit = path.resolve('build', 'app-store', 'Piankexun-device-shoot-kit');
  const manifest = JSON.parse(fs.readFileSync(path.join(kit, 'manifest.json')));
  assert.equal(manifest.photos.length, 11);
  const assets = new Map();
  for (const item of manifest.photos) {
    assert.equal(path.basename(item.name), item.name);
    const bytes = fs.readFileSync(path.join(kit, 'photos', item.name));
    assert.equal(createHash('sha256').update(bytes).digest('hex'), item.sha256, item.name);
    const mime = item.name.endsWith('.jpg') ? 'image/jpeg' : 'image/png';
    assets.set(item.name, `data:${mime};base64,${bytes.toString('base64')}`);
  }
  const image = (name, className = '', alt = '公开演示素材') => {
    assert.ok(assets.has(name), `Missing demo artwork: ${name}`);
    return `<img class="${className}" src="${assets.get(name)}" alt="${alt}">`;
  };
  const nativeCaptures = [];
  function nativeCapture(run, prefix) {
    const directory = path.resolve('build', 'app-store', 'captures', run, 'iphone-large');
    const attachments = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'))).flatMap(t => t.attachments);
    const matches = attachments.filter(a => a.suggestedHumanReadableName.startsWith(`Store-${prefix}_`)
      && a.exportedFileName.endsWith('.png'));
    assert.equal(matches.length, 1);
    assert.equal(matches[0].isAssociatedWithFailure, false);
    const bytes = fs.readFileSync(path.join(directory, matches[0].exportedFileName));
    assert.deepEqual(pngDimensions(bytes), [1320, 2868]);
    nativeCaptures.push({ run, prefix, file: matches[0].exportedFileName,
      sha256: createHash('sha256').update(bytes).digest('hex') });
    return `data:image/png;base64,${bytes.toString('base64')}`;
  }
  const searchCompositions = [];
  function searchScreen(index, prefix, files, { run = '38219454927', gridY = 1140, queryOverride = false } = {}) {
    const capture = nativeCapture(run, prefix);
    const scene = campaignDemoScenes[index];
    searchCompositions.push({ scene: scene.id, run, prefix, query: scene.query, files,
      gridColumns: 5, gridGap: 9, tileAspectRatio: 1, controlsAltered: false, queryOverride });
    const tiles = files.map((file, offset) => {
      assert.ok(assets.has(file), file);
      const side = 232.8;
      const x = 60 + (offset % 5) * (side + 9);
      const y = gridY + Math.floor(offset / 5) * (side + 9);
      const clip = `${scene.id}-tile-${offset}`;
      return `<defs><clipPath id="${clip}"><rect x="${x}" y="${y}" width="${side}" height="${side}" rx="18"/></clipPath></defs><image href="${assets.get(file)}" x="${x}" y="${y}" width="${side}" height="${side}" preserveAspectRatio="xMidYMid slice" clip-path="url(#${clip})"/><rect x="${x}" y="${y}" width="${side}" height="${side}" rx="18" fill="none" stroke="#dfe3e9" stroke-width="3"/>`;
    }).join('');
    // Keep native controls intact; only the query value and result area are illustrative.
    const query = queryOverride ? `<rect x="226" y="394" width="730" height="100" fill="#fff"/><text x="235" y="458" font-size="57" fill="#17212b">${scene.query}</text>` : '';
    return `<div class="native-window"><svg role="img" aria-label="App原生搜索界面底图，查询与结果为演示合成" data-scene="${scene.id}" viewBox="0 190 1320 1490" xmlns="http://www.w3.org/2000/svg"><image href="${capture}" width="1320" height="2868"/>${query}<rect x="50" y="${gridY - 15}" width="1220" height="${2630 - gridY}" fill="#f7f8fa"/>${tiles}</svg></div>`;
  }
  function cleanupCrop(prefix, box) {
    return `<svg role="img" aria-label="已有真实清理界面的等比局部" viewBox="${box}" xmlns="http://www.w3.org/2000/svg"><image href="${nativeCapture('38207709838', prefix)}" width="1320" height="2868"/></svg>`;
  }
  const searchStage = (screen, art, extra = '') => `<div class="search-stage">${extra}${screen}${art}</div>`;
  const menu = assets.get('demo-menu-1.png');
  const bodies = [
    searchStage(searchScreen(0, 'pilot-01-memory-query', ['moment-sunset.jpg']),
      `<div class="search-art">${image('moment-sunset.jpg', '', '命中画面放大示意：日落、栈桥和两个人影')}</div>`,
      `<div class="query-caption"><p>${campaignDemoScenes[0].query}</p></div>`),
    searchStage(searchScreen(1, 'pilot-02-document-query', [1, 2, 3, 4].map(i => `demo-identity-${i}.png`)),
      `<div class="search-art identity-art">${image('demo-identity-1.png', '', '公开SAMPLE证件样本，不是真人证件')}</div>`),
    searchStage(searchScreen(2, 'pilot-ocr-after-2', ['demo-menu-1.png']),
      `<div class="search-art text-art">${image('demo-menu-1.png')}<div class="text-zoom"><span>照片里的备注</span><svg role="img" aria-label="菜单原图配送备注的等比放大" viewBox="100 1260 800 90" xmlns="http://www.w3.org/2000/svg"><image href="${menu}" width="1200" height="1600"/></svg></div></div>`),
    searchStage(searchScreen(3, '02-cat-search', ['distractor-cat.png'],
      { run: '38207709838', gridY: 956, queryOverride: true }),
      `<div class="search-art">${image('distractor-cat.png', '', '找到的绿眼睛虎斑猫，放大示意')}</div>`),
    `<div class="cleanup-demo"><div class="cleanup-window">${cleanupCrop('03-cleanup-overview', '0 200 1320 1390')}</div><div class="keep-story"><div><span>多拍的 6 张</span><div class="burst">${Array.from({ length: 6 }, () => image('distractor-cat.png')).join('')}</div></div><b>→</b><div class="keeper"><span>留下 1 张</span>${image('distractor-cat.png')}</div></div><p>把多余的清掉，相册更清爽。</p></div>`,
    `<div class="cleanup-demo"><div class="cleanup-window detail">${cleanupCrop('05-cleanup-detail', '0 200 1320 1200')}</div><div class="gesture"><span class="gesture-line"></span><span>滑动选中多余的照片</span></div><div class="benefit-tags"><span>放大对比</span><span>选中后删除</span></div><p>满意的留下，多余的自己选删。</p></div>`,
    `<div class="private-stage"><div class="private-collage">${image('moment-sunset.jpg')}${image('demo-identity-1.png')}${image('demo-menu-1.png')}</div><div class="lock"><svg viewBox="0 0 120 140" aria-hidden="true"><path d="M30 60V38a30 30 0 0 1 60 0v22"/><rect x="15" y="55" width="90" height="70" rx="15"/><circle cx="60" cy="85" r="5"/><path d="M60 90v15"/></svg></div><div class="private-copy"><strong>本机 AI 检索</strong><p>照片内容在本机分析<br>搜索不必交出私人相册</p></div></div>`,
    `<div class="brand-stage"><div class="wordmark">片刻寻</div><div class="brand-collage">${image('moment-sunset.jpg')}${image('demo-identity-2.png')}${image('demo-menu-1.png')}</div><div class="brand-actions"><span>凭记忆搜照片</span><span>多拍的，只留想要的</span></div></div>`,
  ];
  const posters = campaignDemoScenes.map((scene, index) => `<article class="poster ${scene.theme}" id="${scene.id}">
    <header><div class="brand">片刻寻 <span>AI 搜照片与相似清理</span></div><h1>${scene.title}</h1><p class="subtitle">${scene.subtitle}</p></header>
    <section class="visual">${bodies[index]}</section><footer><span>${index < 4 ? 'App 原界面 · 搜索结果示意' : index === 6 ? '首次准备模型与语言包可能需要联网' : '功能示意 · 演示素材'}</span><b>找到想看的，留下值得的。</b></footer></article>`).join('');
  const style = `
*{box-sizing:border-box}body{margin:0;background:#ddd9d0;color:#292723;font-family:"Microsoft YaHei","PingFang SC",sans-serif}main{display:grid;grid-template-columns:repeat(4,1320px);width:5280px;gap:0}.poster{width:1320px;height:2868px;overflow:hidden;position:relative;background:radial-gradient(ellipse at 80% 65%,#e6cb9860,transparent 60%),#fbf5e9}.poster.peach{background:radial-gradient(ellipse at 15% 60%,#f1cbbb70,transparent 65%),#f7eee7}
header{padding:90px 90px 0;height:650px}.brand{font-size:42px;font-weight:700;letter-spacing:5px;color:#846327}.brand span{font-size:25px;font-weight:400;letter-spacing:2px;margin-left:20px;color:#827764}h1{font-size:124px;line-height:1.16;letter-spacing:-4px;margin:80px 0 30px;font-weight:800}.subtitle{font-size:38px;line-height:1.6;margin:0;color:#87755b}
.visual{height:1900px;position:relative;display:flex;align-items:center;justify-content:center;padding:20px 90px 0}.search-stage{position:relative;width:100%;height:100%}.native-window{width:1080px;position:absolute;left:30px;top:50px;background:#f7f8fa;border:10px solid #292d2b;border-radius:48px;overflow:hidden;box-shadow:0 30px 65px #352b2725}.native-window svg{display:block;width:100%;height:auto}[id="01-memory"] .native-window{top:225px}.query-caption{position:absolute;left:0;right:0;top:0;background:#fffaf0;border:2px solid #d7c6a5;padding:22px 30px;border-radius:24px}.query-caption p{font-size:34px;line-height:1.65;margin:0}.search-art{position:absolute;left:50px;right:50px;bottom:20px;padding:14px;background:#fffaf0;border:2px solid #d7c6a5;border-radius:32px;box-shadow:0 20px 45px #352b2730;transform:rotate(-2deg)}.search-art>img{display:block;width:100%;height:600px;object-fit:cover;object-position:50% 70%;border-radius:20px}.identity-art{left:90px;right:90px;transform:rotate(2deg)}.identity-art>img{height:auto}.text-art{height:690px}.text-art>img{height:610px;object-fit:contain}.text-zoom{position:absolute;bottom:0;left:-30px;right:-30px;padding:26px 32px;background:#fffaf0;border:3px solid #c5a363;border-radius:28px;box-shadow:0 20px 45px #28200d30;color:#403827}.text-zoom>span{font-size:26px;color:#92723a;display:block;margin-bottom:10px}.text-zoom svg{display:block;width:100%;height:auto}
.cleanup-demo{width:100%;color:#403827}.cleanup-window{background:#f6f7f9;border:12px solid #292d2b;border-radius:60px;overflow:hidden;box-shadow:0 35px 75px #352b2730;transform:rotate(-1deg)}.cleanup-window svg{display:block;width:100%;height:auto}.cleanup-window.detail{transform:rotate(1deg)}.benefit-tags{display:flex;justify-content:center;gap:25px;margin-top:70px}.benefit-tags span{font-size:35px;background:#fff9ef;border:2px solid #d9c69d;border-radius:40px;padding:20px 30px}.cleanup-demo>p{font-size:51px;line-height:1.5;text-align:center;margin:45px 0 0;font-weight:700}.gesture{display:flex;align-items:center;justify-content:center;gap:30px;margin-top:65px;font-size:34px;color:#8b6b31}.gesture-line{width:250px;height:8px;background:#b69455;border-radius:10px;position:relative}.gesture-line:before,.gesture-line:after{content:"";position:absolute;width:35px;height:35px;background:#fff8e9;border:5px solid #b69455;border-radius:50%;top:-13px}.gesture-line:before{left:0}.gesture-line:after{right:0}
.keep-story{display:flex;align-items:center;justify-content:center;gap:30px;margin-top:65px}.keep-story span{display:block;font-size:36px;text-align:center;margin-bottom:22px;color:#87662b}.burst{display:flex;gap:8px}.burst img{width:100px;height:140px;object-fit:cover;border-radius:14px;opacity:.55}.keep-story>b{font-size:64px;color:#9b793f}.keeper img{display:block;width:220px;height:220px;object-fit:cover;border:5px solid #b99550;border-radius:24px}
.private-stage{width:100%;height:1700px;position:relative}.private-collage{display:grid;grid-template-columns:1fr 1fr;gap:22px;transform:rotate(-4deg)}.private-collage img{width:100%;height:540px;object-fit:cover;border-radius:30px}.private-collage img:first-child{grid-column:span 2;width:100%;height:580px}.lock{position:absolute;top:500px;left:calc(50% - 155px);width:310px;height:310px;border-radius:70px;background:#e4c07a;box-shadow:0 25px 65px #0003;display:flex;align-items:center;justify-content:center;transform:rotate(5deg)}.lock svg{width:145px;height:170px;stroke:#3d3523;stroke-width:9;fill:none}.private-copy{position:absolute;left:0;bottom:20px;width:100%;text-align:center}.private-copy strong{font-size:78px;color:#88672b}.private-copy p{font-size:44px;line-height:1.8;color:#7c705f}
.brand-stage{width:100%;height:1800px;position:relative}.wordmark{font-size:150px;font-weight:800;letter-spacing:16px;color:#88672b;text-align:center;margin:25px 0 90px}.brand-collage{display:grid;grid-template-columns:1fr 1fr;gap:25px;transform:rotate(-3deg)}.brand-collage img{width:100%;height:510px;object-fit:cover;border-radius:35px;box-shadow:0 15px 35px #44332225}.brand-collage img:first-child{grid-column:span 2;height:630px}.brand-actions{display:flex;justify-content:center;gap:25px;margin-top:90px}.brand-actions span{font-size:35px;border-radius:50px;border:2px solid #d1b887;background:#fffaf0;padding:24px 30px}
footer{position:absolute;bottom:75px;left:90px;right:90px;display:flex;flex-direction:column;gap:22px}footer span{font-size:25px;color:#a38f6c}footer b{font-size:31px;letter-spacing:3px;color:#8b6b35}`;
  const html = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>片刻寻 · 八张营销Demo</title><style>${style}</style><main>${posters}</main></html>`;
  const reviewStyle = `body{background:#dcd8cf}.review-note{max-width:1350px;margin:24px;font-size:18px;line-height:1.7;color:#494238}.review-note strong{display:block;font-size:28px}main{display:flex;flex-wrap:wrap;gap:24px;padding:24px;width:100%}.poster{zoom:.27}@media(max-width:800px){.poster{zoom:.22}}@media(max-width:600px){main{padding:12px;gap:12px}.poster{zoom:.25}}@media(max-width:360px){.poster{zoom:.22}}`;
  const review = html.replace('</style>', `${reviewStyle}</style>`).replace('<main>', `<aside class="review-note"><strong>片刻寻 · 完整八张营销 Demo</strong>${campaignDemoDisclaimer}<br>统一浅色底；多拍的照片，挑一张留下，其余选中删除。</aside><main>`);
  const output = path.resolve('build', 'app-store', 'campaign-demo');
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'export.html'), html);
  fs.writeFileSync(path.join(output, 'index.html'), review);
  fs.copyFileSync(path.join(kit, 'sources.json'), path.join(output, 'sources.json'));
  fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
    mode: 'native-ui-demo-composition-not-device-capture', size: [1320, 2868],
    disclaimer: campaignDemoDisclaimer,
    scenes: campaignDemoScenes.map(scene => ({ ...scene, file: `${scene.id}.png` })),
    sourcesFile: 'sources.json', publicInputHashes: manifest.photos,
    nativeCaptures, searchCompositions,
    artwork: 'Verified public artwork composed into existing native UI. Cleanup crops are unchanged; the six-to-one diagram uses one CC0 cat image, not six claimed real exposures. No competitor artwork.',
  }, null, 2) + '\n');
  return { output, scenes: campaignDemoScenes.length, mode: 'marketing-demo' };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(renderCampaignDemo()));
}
