import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { pngDimensions } from './package_captures.mjs';

export const campaignDemoScenes = [
  { id: '01-memory', title: '那一刻<br>凭记忆找回来', subtitle: '天空、人物、地点，一句话说清楚。',
    query: '傍晚的海边，粉紫色和橙色的天空，两个人站在水边，身后有一座长长的栈桥', theme: 'sand' },
  { id: '02-identity', title: '身份证照片<br>不必翻遍相册', subtitle: '记得是什么，就从这个词开始找。', query: '身份证', theme: 'ink' },
  { id: '03-text', title: '照片里的文字<br>也能成为线索', subtitle: '记住一句备注，找回那张照片。', query: '北门值班室', theme: 'peach' },
  { id: '04-object', title: '记住颜色和样子<br>也能找到它', subtitle: '不用记文件名，也不用提前打标签。',
    query: '绿眼睛、棕色条纹，近距离拍下的猫', theme: 'sand' },
  { id: '05-cleanup', title: '相似的画面<br>放在一起挑', subtitle: '先分组，再决定哪些值得留下。', theme: 'peach' },
  { id: '06-selection', title: '放大看清楚<br>滑动轻松选', subtitle: '组里组外都能挑，选中后再删除。', theme: 'sand' },
  { id: '07-private', title: '你的照片<br>在本机处理', subtitle: '不上传照片到 AI 服务器。', theme: 'ink' },
  { id: '08-brand', title: '找到想看的<br>留下值得的', subtitle: 'AI 搜照片，也帮你挑选相似画面。', theme: 'sand' },
];
export const campaignDemoDisclaimer = '营销 Demo：功能与视觉示意，不是新的真机运行截图；最终商店素材另行确认。';

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
  const baseline = path.resolve('build', 'app-store', 'captures', '38207709838', 'iphone-large');
  const attachments = JSON.parse(fs.readFileSync(path.join(baseline, 'manifest.json'))).flatMap(t => t.attachments);
  function cleanupCrop(prefix, box) {
    const matches = attachments.filter(a => a.suggestedHumanReadableName.startsWith(`Store-${prefix}_`)
      && a.exportedFileName.endsWith('.png'));
    assert.equal(matches.length, 1);
    assert.equal(matches[0].isAssociatedWithFailure, false);
    const bytes = fs.readFileSync(path.join(baseline, matches[0].exportedFileName));
    assert.deepEqual(pngDimensions(bytes), [1320, 2868]);
    return `<svg role="img" aria-label="已有真实清理界面的等比局部" viewBox="${box}" xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,${bytes.toString('base64')}" width="1320" height="2868"/></svg>`;
  }
  const searchIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10" cy="10" r="6"/><path d="m15 15 6 6"/></svg>';
  const search = query => `<div class="search">${searchIcon}<p>${query}</p><span>→</span></div>`;
  const phone = (query, content, cls = '') => `<div class="phone ${cls}"><div class="speaker"></div><div class="app-title">片刻寻 <span>AI 照片搜索</span></div>${search(query)}${content}</div>`;
  const idGallery = `<div class="identity-grid">${[1, 2, 3, 4].map(i => image(`demo-identity-${i}.png`, '', '公开身份证样本摆拍，保留SAMPLE')).join('')}</div>`;
  const menu = assets.get('demo-menu-1.png');
  const bodies = [
    phone(campaignDemoScenes[0].query, `<div class="memory-result">${image('moment-sunset.jpg', '', '粉紫橙色日落、海边栈桥和两个人影')}</div><div class="caption">把记忆中的画面，说给片刻寻。</div>`, 'memory-phone'),
    `<div class="identity-stage">${phone('身份证', `${idGallery}<div class="caption">公开证件样本 · 不含真实身份信息</div>`, 'identity-phone')}<div class="identity-inset">${image('demo-identity-1.png', '', '同一公开样本正面的细节展示，不是真人证件')}</div></div>`,
    `<div class="text-stage">${phone('北门值班室', `<div class="menu-image">${image('demo-menu-1.png', '', '含北门值班室配送备注的原创菜单')}</div>`, 'text-phone')}<div class="text-zoom"><span>照片里的备注</span><svg role="img" aria-label="菜单原图配送备注的等比放大" viewBox="100 1260 800 90" xmlns="http://www.w3.org/2000/svg"><image href="${menu}" width="1200" height="1600"/></svg></div></div>`,
    phone(campaignDemoScenes[3].query, `<div class="object-result">${image('distractor-cat.png', '', '绿眼睛的虎斑猫')}</div><div class="caption">颜色、外形、动作，都可以是记忆点。</div>`, 'object-phone'),
    `<div class="cleanup-demo"><div class="cleanup-window">${cleanupCrop('04-cleanup-selection', '0 200 1320 1390')}</div><div class="benefit-tags"><span>相似画面分组</span><span>组级别直接挑选</span></div><p>保留哪张，你来决定。</p></div>`,
    `<div class="cleanup-demo"><div class="cleanup-window detail">${cleanupCrop('05-cleanup-detail', '0 200 1320 1200')}</div><div class="gesture"><span class="gesture-line"></span><span>横向滑动，连续选择</span></div><div class="benefit-tags"><span>放大查看</span><span>并排对比</span></div><p>看清细节，再做选择。</p></div>`,
    `<div class="private-stage"><div class="private-collage">${image('moment-sunset.jpg')}${image('demo-identity-1.png')}${image('demo-menu-1.png')}</div><div class="lock"><svg viewBox="0 0 120 140" aria-hidden="true"><path d="M30 60V38a30 30 0 0 1 60 0v22"/><rect x="15" y="55" width="90" height="70" rx="15"/><circle cx="60" cy="85" r="5"/><path d="M60 90v15"/></svg></div><div class="private-copy"><strong>本机 AI 检索</strong><p>照片内容在本机分析<br>搜索不必交出私人相册</p></div></div>`,
    `<div class="brand-stage"><div class="wordmark">片刻寻</div><div class="brand-collage">${image('moment-sunset.jpg')}${image('demo-identity-2.png')}${image('demo-menu-1.png')}</div><div class="brand-actions"><span>凭记忆搜照片</span><span>挑选清理相似画面</span></div></div>`,
  ];
  const posters = campaignDemoScenes.map((scene, index) => `<article class="poster ${scene.theme}" id="${scene.id}">
    <header><div class="brand">片刻寻 <span>AI 搜照片与相似清理</span></div><h1>${scene.title}</h1><p class="subtitle">${scene.subtitle}</p></header>
    <section class="visual">${bodies[index]}</section><footer><span>${index === 6 ? '首次准备模型与语言包可能需要联网' : '功能示意 · 演示素材'}</span><b>找到想看的，留下值得的。</b></footer></article>`).join('');
  const style = `
*{box-sizing:border-box}body{margin:0;background:#ddd9d0;color:#292723;font-family:"Microsoft YaHei","PingFang SC",sans-serif}main{display:grid;grid-template-columns:repeat(4,1320px);width:5280px;gap:0}.poster{width:1320px;height:2868px;overflow:hidden;position:relative;background:radial-gradient(ellipse at 80% 65%,#e6cb9860,transparent 60%),#fbf5e9}.poster.peach{background:radial-gradient(ellipse at 15% 60%,#f1cbbb70,transparent 65%),#f7eee7}.poster.ink{background:radial-gradient(ellipse at 80% 55%,#715b3740,transparent 65%),#232723;color:#fff9ed}
header{padding:90px 90px 0;height:650px}.brand{font-size:42px;font-weight:700;letter-spacing:5px;color:#846327}.brand span{font-size:25px;font-weight:400;letter-spacing:2px;margin-left:20px;color:#827764}.ink .brand,.ink .brand span{color:#d8bc80}h1{font-size:124px;line-height:1.16;letter-spacing:-4px;margin:80px 0 30px;font-weight:800}.subtitle{font-size:38px;line-height:1.6;margin:0;color:#87755b}.ink .subtitle{color:#d8cbb5}
.visual{height:1900px;position:relative;display:flex;align-items:center;justify-content:center;padding:20px 90px 0}.phone{width:960px;height:1780px;background:#f6f7f9;border:14px solid #272a29;border-radius:78px;box-shadow:0 45px 90px #352b2735;padding:95px 38px 45px;position:relative;color:#292723;overflow:hidden;transform:rotate(-2deg)}.identity-phone{transform:rotate(2deg)}.speaker{position:absolute;width:145px;height:23px;background:#272a29;top:25px;left:calc(50% - 72px);border-radius:15px}.app-title{font-size:47px;font-weight:700;margin:0 0 55px;padding:0 12px;display:flex;align-items:center;justify-content:space-between}.app-title span{font-size:25px;color:#8c7650;font-weight:400}.search{display:flex;align-items:center;gap:24px;border:2px solid #e2ddd1;background:#fff;padding:30px;border-radius:30px;box-shadow:0 8px 24px #2c281208}.search svg{width:35px;flex-shrink:0;stroke:#8c7650;stroke-width:2;fill:none}.search p{font-size:41px;line-height:1.55;margin:0;flex:1}.search>span{background:#856427;color:#fff;font-size:48px;width:76px;height:76px;text-align:center;line-height:70px;border-radius:22px;flex-shrink:0}.caption{font-size:29px;line-height:1.7;color:#857761;margin:40px 12px}.memory-result{margin-top:55px;border-radius:32px;overflow:hidden;box-shadow:0 14px 32px #38220d1a}.memory-result img{display:block;width:100%;height:1000px;object-fit:cover;object-position:50% 65%}.identity-grid{margin-top:70px;display:grid;grid-template-columns:1fr 1fr;gap:24px}.identity-grid img{width:100%;height:365px;object-fit:cover;border-radius:24px;box-shadow:0 15px 25px #1112}.identity-phone .caption{margin-top:65px;font-size:32px}
.text-stage{width:100%;height:100%;position:relative;display:flex;justify-content:center;align-items:center}.text-phone{transform:rotate(-2deg);height:1790px}.menu-image{margin:45px 70px 0;border-radius:24px;overflow:hidden;box-shadow:0 12px 30px #39290f20}.menu-image img{display:block;width:100%;height:1150px;object-fit:contain;background:#f6f1e4}.text-zoom{position:absolute;bottom:135px;left:0;width:100%;padding:26px 32px;background:#fffaf0;border:3px solid #c5a363;border-radius:28px;box-shadow:0 20px 45px #28200d30;color:#403827;transform:rotate(1deg)}.text-zoom>span{font-size:26px;color:#92723a;display:block;margin-bottom:10px}.text-zoom svg{display:block;width:100%;height:auto}.object-result{margin-top:60px;border-radius:35px;overflow:hidden}.object-result img{display:block;width:100%;height:1040px;object-fit:cover}.object-phone{transform:rotate(2deg)}
.cleanup-demo{width:100%;color:#403827}.cleanup-window{background:#f6f7f9;border:12px solid #292d2b;border-radius:60px;overflow:hidden;box-shadow:0 35px 75px #352b2730;transform:rotate(-1deg)}.cleanup-window svg{display:block;width:100%;height:auto}.cleanup-window.detail{transform:rotate(1deg)}.benefit-tags{display:flex;justify-content:center;gap:25px;margin-top:70px}.benefit-tags span{font-size:35px;background:#fff9ef;border:2px solid #d9c69d;border-radius:40px;padding:20px 30px}.cleanup-demo>p{font-size:51px;line-height:1.5;text-align:center;margin:45px 0 0;font-weight:700}.gesture{display:flex;align-items:center;justify-content:center;gap:30px;margin-top:65px;font-size:34px;color:#8b6b31}.gesture-line{width:250px;height:8px;background:#b69455;border-radius:10px;position:relative}.gesture-line:before,.gesture-line:after{content:"";position:absolute;width:35px;height:35px;background:#fff8e9;border:5px solid #b69455;border-radius:50%;top:-13px}.gesture-line:before{left:0}.gesture-line:after{right:0}
.private-stage{width:100%;height:1700px;position:relative}.private-collage{display:grid;grid-template-columns:1fr 1fr;gap:22px;opacity:.72;transform:rotate(-4deg)}.private-collage img{width:100%;height:540px;object-fit:cover;border-radius:30px}.private-collage img:first-child{grid-column:span 2;width:100%;height:580px}.lock{position:absolute;top:500px;left:calc(50% - 155px);width:310px;height:310px;border-radius:70px;background:#e4c07a;box-shadow:0 25px 65px #0005;display:flex;align-items:center;justify-content:center;transform:rotate(5deg)}.lock svg{width:145px;height:170px;stroke:#3d3523;stroke-width:9;fill:none}.private-copy{position:absolute;left:0;bottom:20px;width:100%;text-align:center}.private-copy strong{font-size:78px;color:#edcf93}.private-copy p{font-size:44px;line-height:1.8;color:#d7cbb6}
.brand-stage{width:100%;height:1800px;position:relative}.wordmark{font-size:150px;font-weight:800;letter-spacing:16px;color:#88672b;text-align:center;margin:25px 0 90px}.brand-collage{display:grid;grid-template-columns:1fr 1fr;gap:25px;transform:rotate(-3deg)}.brand-collage img{width:100%;height:510px;object-fit:cover;border-radius:35px;box-shadow:0 15px 35px #44332225}.brand-collage img:first-child{grid-column:span 2;height:630px}.brand-actions{display:flex;justify-content:center;gap:25px;margin-top:90px}.brand-actions span{font-size:35px;border-radius:50px;border:2px solid #d1b887;background:#fffaf0;padding:24px 30px}
footer{position:absolute;bottom:75px;left:90px;right:90px;display:flex;flex-direction:column;gap:22px}footer span{font-size:25px;color:#a38f6c}footer b{font-size:31px;letter-spacing:3px;color:#8b6b35}.ink footer span{color:#a6987f}.ink footer b{color:#dfc48e}`;
  const identityStyle = `.identity-stage{width:100%;height:100%;position:relative;display:flex;align-items:center;justify-content:center}.identity-inset{position:absolute;width:860px;left:140px;bottom:45px;transform:rotate(-4deg);padding:14px;background:#fffaf0;border:2px solid #d6c5a4;border-radius:30px;box-shadow:0 20px 45px #0004}.identity-inset img{display:block;width:100%;height:auto;border-radius:18px}`;
  const html = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>片刻寻 · 八张营销Demo</title><style>${style}${identityStyle}</style><main>${posters}</main></html>`;
  const reviewStyle = `body{background:#dcd8cf}.review-note{max-width:1350px;margin:24px;font-size:18px;line-height:1.7;color:#494238}.review-note strong{display:block;font-size:28px}main{display:flex;flex-wrap:wrap;gap:24px;padding:24px;width:100%}.poster{zoom:.27}@media(max-width:800px){.poster{zoom:.22}}@media(max-width:600px){main{padding:12px;gap:12px}.poster{zoom:.25}}@media(max-width:360px){.poster{zoom:.22}}`;
  const review = html.replace('</style>', `${reviewStyle}</style>`).replace('<main>', `<aside class="review-note"><strong>片刻寻 · 完整八张营销 Demo</strong>${campaignDemoDisclaimer}<br>身份证场景已包含；广告画面不展示检索排名或测试报告。</aside><main>`);
  const output = path.resolve('build', 'app-store', 'campaign-demo');
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'export.html'), html);
  fs.writeFileSync(path.join(output, 'index.html'), review);
  fs.copyFileSync(path.join(kit, 'sources.json'), path.join(output, 'sources.json'));
  fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
    mode: 'marketing-concept-demo-not-new-device-capture', size: [1320, 2868],
    disclaimer: campaignDemoDisclaimer,
    scenes: campaignDemoScenes.map(scene => ({ ...scene, file: `${scene.id}.png` })),
    sourcesFile: 'sources.json', publicInputHashes: manifest.photos,
    artwork: 'Only the verified public device-shoot kit; existing native cleanup crops from run38207709838. No competitor artwork.',
  }, null, 2) + '\n');
  return { output, scenes: campaignDemoScenes.length, mode: 'marketing-demo' };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(renderCampaignDemo()));
}
