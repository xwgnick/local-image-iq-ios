import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

const captureRoot = path.resolve('build', 'app-store', 'captures', '38219454927');
const output = path.resolve('build', 'app-store', 'Piankexun-device-shoot-kit');
const scenes = JSON.parse(fs.readFileSync(new URL('priority-scenes.json', import.meta.url))).scenes;
const sources = [
  { from: path.resolve('build', 'app-store', 'pilot-sources', 'sunset-pier.jpg'), name: 'moment-sunset.jpg',
    hash: '9b505bd5d5af1b046add5e9b17a92af5a2ae766ce0e0490974a63f8cc38c0cc4' },
  { from: path.resolve('build', 'app-store', 'source-photos', 'coffee.png'), name: 'distractor-coffee.png',
    hash: 'cc02f8ca188b167c775a7101b5d767d1e71792cf762c33d6fa15a4599b5a8de7' },
  { from: path.resolve('build', 'app-store', 'source-photos', 'chelsea.png'), name: 'distractor-cat.png',
    hash: '596aa1e7cb875eb79f437e310381d26b338a81c2da23439704a73c4651e8c4bb' },
  ...['identity', 'menu'].flatMap(family => Array.from({ length: 4 }, (_, index) => ({
    from: path.join(captureRoot, `${family}-photos`, `demo-${family}-${index + 1}.png`),
    name: `demo-${family}-${index + 1}.png`,
  }))),
];
const prepared = sources.map(source => {
  const bytes = fs.readFileSync(source.from);
  assert.ok(bytes.length > 0, `Empty source: ${source.name}`);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  if (source.hash) assert.equal(sha256, source.hash, `Unverified source: ${source.name}`);
  return { ...source, bytes, sha256 };
});
assert.equal(prepared.length, 11);
assert.equal(new Set(prepared.map(source => source.name)).size, 11);
const provenance = fs.readFileSync(path.join(captureRoot, 'provenance.json'));
fs.mkdirSync(path.join(output, 'photos'), { recursive: true });
assert.deepEqual(fs.readdirSync(output).filter(name =>
  !['photos', 'sources.json', 'manifest.json', 'shooting-guide.txt'].includes(name)), [],
  'Unexpected files in kit root; refuse to package them');
const expected = prepared.map(source => source.name).sort();
assert.deepEqual(fs.readdirSync(path.join(output, 'photos')).filter(name => !expected.includes(name)), [],
  'Unexpected files in kit; do not include private or unrelated photos');
for (const source of prepared) fs.writeFileSync(path.join(output, 'photos', source.name), source.bytes);
fs.writeFileSync(path.join(output, 'sources.json'), provenance);
fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
  sourceRun: '38219454927',
  purpose: 'Public demo photos for an actual-device shoot; not a validated translated screenshot set',
  photos: prepared.map(({ name, bytes, sha256 }) => ({ name, bytes: bytes.length, sha256 })),
  scenes: scenes.map((scene, index) => ({
    query: scene.query, chineseSearchEnhancement: true, ocr: index === 2,
    expected: scene.expectedTopPhoto ?? scene.expectedTopFamily,
  })),
}, null, 2) + '\n');
fs.writeFileSync(path.join(output, 'shooting-guide.txt'), `片刻寻 · 公开素材真机拍摄包

这是拍摄素材，不是已经通过真机翻译检索验收的商店截图。
photos 中共11张：日落1张、公开身份证样本正反面摆拍4张、自制菜单4张、咖啡和猫各1张。
证件是同一个公开样本的不同视角，保留 SAMPLE，不能说成四个人的真实身份证。

准备
1. 将 photos 中的11张公开图片保存到照片中，可建“片刻寻商店演示”相册。
2. 不删除原有照片，不清空索引，不卸载应用，不为了拍摄重置手机。
3. 优先在备用设备拍摄；或用系统有限照片访问，仅授权这些公开素材。
   如果不想改动常用手机的照片权限，先保存素材，等合适设备再拍。
   截图只允许出现本包公开素材，不拍摄或上传私人证件、聊天和私人照片。
4. iOS 18+ 真机：“中文搜索增强”保持开启，中文到英文的离线语言包已就绪。
   它就是翻译开关，不是另外一个功能。不要出现“不支持离线翻译，本次使用原文”。
5. 等演示照片索引完成，再搜索；不要把加载中的旧结果当成新查询结果。

场景1 · 长描述（OCR关闭，翻译开启）
${scenes[0].query}
保留完整结果截图；若日落排第一，再打开日落照片拍一张大图。

场景2 · 证件（OCR关闭，翻译开启）
${scenes[1].query}
保留能看见中文查询、实际译文和前列结果的完整屏幕。
如样本没有排在前列，保留真实结果，不删其它结果或手动重排。

场景3 · 配送备注（翻译始终开启，只改变OCR开关）
${scenes[2].query}
先关闭OCR搜索并截图；再开启OCR、等文字索引完成，用完全相同的查询重搜并截图。
目标是Q7M2菜单上的配送备注。排名必须按真机实际结果记录，不能套用模拟器第6到第1。
只在实际匹配时再打开菜单拍大图，原图小字的放大排版由后续处理。

交回公开素材截图即可，不需要任何真人身份证、账号密码或私人照片。
截图请保留原始分辨率，不涂改查询、不替换结果。外部标题、边框和重点放大由排版处理。
本包许可证及来源见 sources.json，每张文件哈希见 manifest.json。
`, 'utf8');
assert.deepEqual(fs.readdirSync(path.join(output, 'photos')).sort(), expected);
console.log(JSON.stringify({ output, photos: expected.length, actualDeviceCapture: 'pending' }));
