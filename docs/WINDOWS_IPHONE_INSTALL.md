# Windows → iPhone 安装（免费账号）

用户设备：**iPhone 15 / iOS 26.6.1**，只能使用 Windows；已同意使用
**Sideloadly**。这是第三方个人测试安装路线，不是 TestFlight、App Store 或
苹果提供的 Windows 版 Xcode。此前版本已在该手机安装、打开并使用；每个新版本
的界面与实际图库行为仍需在手机上确认。

## 当前：0.4.0（build 11）— 私有 Release 已发布，本地 IPA 已校验，可签名安装

用户已明确批准**方案 2：同一私有仓库 Release＋job 级 contents: write**，不改公开
可见性或计费。新源码 `844492b754f86d519c904da21cd80c1c814c056b` 相比已通过
原生／设备验证的 `0c09c46ff5edf74ffeb4a2cece2f7b9fd20a5910`，仅改工作流和两个
发布／测试脚本，没有 App、索引、模型改动；发布器 **83 项本地 Node 22 mock 测试通过，
CI 对应步骤也 PASS**。
[CI 36387878343](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343)
／[job 108817040032](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343/job/108817040032)，
已 **COMPLETED / SUCCESS**，实际 `TEST SUCCEEDED` 和设备 `BUILD SUCCEEDED`。
这是**两次 Actions artifact 配额失败后的首次私有 Release 尝试成功**，不是整体首轮成功。
**新 IPA 已完整下载并校验**，不是旧 build 10 包。本次只记录已核验证据，不查询 CI、
执行命令或下载。

### 已备好的 build 11 安装包：本机与另一台电脑

- **本工作区**：[../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa)。
  已实际全量下载，父进程直接流式复验长度／SHA-256 一致，`ipaVerifiedLocally: true`；
  设备报告、校验文件、交付清单及下载记录齐全，无部分下载残留，所有旧本地包保留。
- **另一台 Windows 电脑**：打开
  [私有 Release：ci-36387878343-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)，
  登录 **xwgnick 或具有该私有仓库读取权限的账号**，下载同一未签名 IPA，核验以下
  长度／SHA-256 后再签名。本地工作区链接不会把文件自动传到另一台电脑；Release 不是公开下载。
- IPA asset **594739443**，精确 **1,414,801,288 字节**；SHA-256：
  `6043afbe68a84edd16d1314ecf4369f308bff8d7cf676392aee5eee6a950ca71`。
  不使用第二轮 runner 的 **1,414,801,289 字节／fc449b…** 校验值。
- Release ID **398009938**，发布于 **2026-09-28T06:55:36Z**，**prerelease、非 draft、
  非 Latest**；9 项资产（8 载荷＋交付清单）全部上传并通过 API SHA-256 核验。
  设备报告确认 **0.4.0 / 11、iphoneos18.5、arm64 Release、未签名、Xcode 16.4、最低 iOS 17.0**。
  未签名 IPA 仍需 Sideloadly，不是已在手机安装／运行；完整记录见 [BUILD_STATUS.md](BUILD_STATUS.md)。

新路线不再使用 Actions artifact 配额；仍是私有仓库访问控制，不是 App Store、
TestFlight 或 Apple 签名服务。CI 无 PAT／Apple 凭据；成功才将已逐项验证的 DRAFT
发布为非 Latest 的 prerelease，失败或部分上传不是可安装交付。macOS 分钟仍按原规则
计量，不承诺免费。新本机 helper 的 `report` 不下载 IPA，`fetch` 才全量下载／校验；
`ui-review` 只取截图 ZIP，不代表审核完成。详见
[PRIVATE_RELEASE_DELIVERY.md](PRIVATE_RELEASE_DELIVERY.md)。

**两轮历史保留**：[首轮 36382669765](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36382669765)
仅上传配额失败，设备构建跳过；[第二轮 36383757627](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36383757627)
原生、iPhoneOS 编译及包验证通过，仍因 Upload UI／Keep evidence 配额失败，IPA 上传
跳过，artifacts API 为 `[]`。第二轮包身份仅来自 runner 日志，不是本地交付；旧哈希
不作为新包哈希。完整历史身份与测试结果见 [BUILD_STATUS.md](BUILD_STATUS.md)。

**历史云端 IPA 链接说明**：获批清理已完成 **9＋1＝10 个**旧 IPA 云端产物：首批 9 个
为 **9,906,302,776 远端字节**，后补最早 IPA（run 35636586662／artifact 10656339002）
为 **709,538,194 远端字节**，合计 **10,615,840,970 远端字节**。删除前逐份核验本地
长度／SHA-256，全部 10 份本地 IPA 保留并再次核验有效；源码、日志和测试报告保留。
下方对应旧云端 IPA 链接已失效，仅作历史记录，原测试计数不变；详细身份／校验值见
[BUILD_STATUS.md](BUILD_STATUS.md)。首批 9 个删除后只读盘点为 **31 个／1,837,708,271
字节**；最后 1 个删除后推算剩余 **30 个／1,128,170,077 字节**，不是重新完整盘点。
其他测试／证据包未动、未获准删除；这些数字不证明配额可用，账号套餐／全量存储／本月累计
用量未知。GitHub 官方计费说明：删除不清除本月已累计的存储用量，每 **6–12 小时**
更新用量，等待不保证恢复上传；未清理其他仓库或更改计费。

上述配额问题是历史阻塞；**现在同仓库私有 Release 已获批准**，不需要再次确认路线。
首次 Release 尝试已成功交付；未扩大旧产物清理，也未改变仓库可见性或计费，
**不声称 Actions 配额已恢复**。

### 现在只做这些步骤

本工作区的新包已经就绪，无需等待 CI 或重新下载；另一台电脑先按上方入口获取并校验。

1. 确认是已验证的 **0.4.0 / build 11** 新 IPA，再用**原 Sideloadly 账号、原有效
  Bundle ID 覆盖安装**，不卸载、不 Clear index。已有 build 10 当前策略有效索引
  **不需重建图像或地点，也不用点 Index / resume**；更早策略的迁移是历史要求，
  不是本次翻译升级要求。
2. 打开 **Settings → 中文搜索增强**（默认开启、记住开关），选择
  **简体中文 → 英文 → 下载离线语言包**，联网并在系统提示中同意下载。
  确认“离线语言包已就绪”后再用；需要繁体时另选“繁體中文 → 英文”检查／准备。
  系统准备返回不一定已经就绪，未完成可稍后复查。照片 **Network 可一直 OFF**，
  不必开启 iCloud 或下载照片。
3. 回首页搜索 **身份证**，看“已用英文搜索”显示的实际译文和结果。可直接搜显示的英文
  作对照（英文绕过翻译），再比较中文搜索后的**“使用原文”**；它只对本次生效，
  下次普通搜索仍可翻译。不要预设系统一定输出 “ID card” 或必定提升效果。
4. **可选离线确认**：语言包就绪后关闭全部网络，飞行模式后也确认 Wi-Fi 关闭，
  在真机重新提交中文搜索，查看英文提示／结果。这只验证该手机当次行为，App 不检测
  是否断网；不要求清库、整库索引、单照片检查或诊断截图。

### 系统、空间与回退说明

- 系统翻译限 **iOS 18+ 真机**及受支持语言对；App 最低 iOS 17 不变，不支持时仍可
  原文搜索。本轮设备报告确认 **Xcode 16.4／iOS 18.5 SDK** 和设备编译通过，
  包含真机专用翻译分支，但没有真机运行证据。
  这是 Translation 框架，不声称要求 Apple Intelligence 或 LLM；模拟器不能验证真实翻译。
- 中文／中英混合整句仅在提交搜索时翻译，不逐键调用；英文、含假名／Hangul 的输入绕过。
  纯 Han 短句有歧义，系统识别简繁。Settings 选择的是准备语言对，不强制搜索来源语种。
- 普通搜索重新检查 `.installed`，host 内调用前再查，不显式准备；已知缺包或翻译失败
  会提示并用同一原文，无 App 查询服务器或云端翻译兜底。只有显式准备入口调用
  `prepareTranslation()`，缺包须用户同意；但**检查与翻译没有原子锁**，中间语言包被
  移除时系统 session 仍可能请求下载提示，不能承诺任何竞态下绝无 OS 弹窗。
- 语言包下载与 Photos 联网许可分开，占**系统空间、不在 IPA 内**，实际大小未测量。
  模型未换，新 IPA 实测 **1,414,801,288 字节（约 1.4 GB）**，哈希见上；不要把
  IPA 大小当成手机所需总剩余空间，签名／安装和系统语言包还需要空间。
- **20 worker、HQ224／Fast、模型／预处理、图像和地点缓存及 Places 不变**，增强功能
  不更改照片设置。原文留在输入框，结果显示有效英文；单照片检查默认沿用有效查询，
  编辑框按字面使用、不再翻译。取消／后台与活跃 host 等待结束的检查保留；未进后台的
  重复 active 不取消系统同意流程。

**本轮实测（36387878343）**：核心 **79 通过**；App **349 项：348 通过、1 项真机文件保护在
模拟器跳过、0 失败（108.139 秒）**，含 **42 状态（0.404 秒）＋32 桥接（0.310 秒）＋
5 展示（0.438 秒）**全部通过；独立 UI **7 通过（199.344 秒）**。GeneratedModelParity
**8 通过（81.423 秒）**，含 20 槽工厂 **120 次预测／252 项测量**及原 **23／58**
门槛，均未放宽。子套件已计入 App 总数，测试耗时不是手机性能。

**前两轮历史**：首轮设备步骤跳过，第二轮设备构建通过，但两轮均未交付；原测试计数／
耗时及第二轮 runner 包身份保留在 [BUILD_STATUS.md](BUILD_STATUS.md)，不混用为本轮结果。

本轮截图 ZIP 已下载校验，**仅提取／审核四张新增翻译图**的
[1340×758 联系图](../build/ui-review/36387878343/query-translation-contact.jpg)：原中文、英文及
“使用原文”可读；缺包提示／设置入口可见；Settings 四控件与屏内页脚可读但较密；
大字号原文／英文／按钮可见，下方空状态延伸到屏外，不证明整页可见。
其余图像未提取／查看，总数未核实。假翻译／零结果截图及 5 项展示测试不是按钮 UI 自动化。
**PENDING-DEVICE**：真实系统翻译仍未测量，
不能据模拟器测试或设备编译声称系统弹窗、真机离线质量／延迟已验证。
详细状态见 [BUILD_STATUS.md](BUILD_STATUS.md)，行为与测试边界见
[QUERY_TRANSLATION.md](QUERY_TRANSLATION.md)。

## 历史：0.3.4（build 10）— 首轮验证通过，已校验 IPA 可用于签名安装

以下及后续旧版章节保留当时包身份与操作，“现在／本次”仅指对应历史版本。
已在 build 10 当前策略上的索引升级 build 11 不用重新跑索引，勿重复历史迁移／诊断步骤。

源码 `3381fa6750f8efa76aa0895a72963c2d56a497f5` 的
[CI 35991227461](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461)
／[job 107605532969](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461/job/107605532969)
已 **SUCCESS，首轮通过，无需修复重跑**，日志确认 `TEST SUCCEEDED` 和设备
`BUILD SUCCEEDED`。build 10 新 IPA 已实际完整下载并校验，**无需再等新包**；
仍须 Sideloadly 本机签名，下方 build 9／8 旧包不能代替本次更新。

### 已备好的 build 10 安装包

- [../build/device-download/35991227461/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35991227461/LocalImageIQ-iphoneos-unsigned.ipa)
  已通过有界流式完整下载，实际长度／SHA-256 核验后才最终重命名；无需重新下载。
  [../build/device-download/35991227461/device-build.json](../build/device-download/35991227461/device-build.json)
  与 [../build/device-download/35991227461/SHA256SUMS.txt](../build/device-download/35991227461/SHA256SUMS.txt)
  均已存在，无部分下载残留，旧包保留。
- [IPA 产物 10805190700](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461/artifacts/10805190700)：
  外层 **1,414,740,610 字节**，内层 IPA **1,414,733,291 字节**；IPA SHA-256：
  `0e1bc7ece93af94745e81e780d9ddf3fc78b9173c2e987a68710322be46bf7ff`。
- 设备报告确认 **0.3.4 / build 10、iphoneos18.5、arm64 Release、未签名、Xcode 16.4、
  最低 iOS 17.0**，同一 768 维 SigLIP 2 模型及 2,943 要素地点包；不是已在手机运行。

### 现在只做这些步骤

1. **使用上方已下载并校验的 build 10 IPA。**不追加诊断或截图任务，也不用清空现有索引。
2. 用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**，不卸载、不 Clear index。
3. 保持 App 的 **Network OFF**，打开 **Library → Index / resume** 跑一次，
  保持 App 在前台。模型没换，但取图策略变了，旧策略记录会自动重新编码。
4. 完成后再试搜索。如果 App 被 iOS 终止，重新打开，再点 **Index / resume**；
  已成功保存且仍有效的前缀会复用，未提交部分需要重做。**不保证 20 槽一定跑完。**

### 为什么要跑一次索引

同一 SigLIP 2 图文模型、768 维／FP32、模型版本和地点包不变；输入策略从实际
已发布的 `photokit-preview-v1` 改为 `photokit-hq224-fast-fallback-v1`。
旧策略向量在新记录成功提交前不参与搜索／当前有效计数，因此迁移期间可搜照片可能
减少甚至为 0，排名也可能改变；这不是让你清库，不承诺迁移中搜索保持原样。
新策略已完成且仍有效的记录可续用；Fast 兜底产生的记录也会缓存，不会自动提高清晰度。

地点文本缓存也以完整的 `IndexImagePolicy.cacheVersion` 为键，旧策略地点文本向量
不能跨此次迁移复用；新策略内相同地点文本仍共享缓存，只需编码一次。

索引先离线请求短边目标 224 的高质量图，无可用本地资源才离线请求 Fast 224；均保留
`.aspectFit`、`.current`、`resizeMode = .fast`，有可用像素就接受，含降质／单回调。
取消、权限／授权失败或无像素普通错误不触发兜底。只有两路本地均无资源且已显式
允许联网，才允许第三次高质量联网请求；默认关闭，不调用原图 API，不要求下载原图。
三路诊断及正常看图界面不变，不能把索引取图调整说成正常显示已经更清晰。

### iPhone 15 的 20 槽实验与验证边界

新输入策略及 20 个独立图像 actor 已由源码和测试验证，不声称设备报告含有输入策略字段。
复用 1 个主图像 actor，19 个额外仅图像 actor 索引期间懒加载，全部子任务结束后
释放作用域持有；仍只有 1 个文本模型和 1 个
tokenizer。进行中和完成待顺序提交一起占 20 槽，按顺序逐项提交补位，不是每 20 张
一批。这是用户批准的高内存实验，**可能被 iOS 终止**；不静默限制或自动缩回 4，
不代表硬件同时算 20 张，不承诺相对四槽快 5 倍或系统立即归还内存。

已有匿名真机个例仅说明 Fast **68×120 → 高质量 224 的 224×398**，高质量 480
不可用；不是全图库结论或清晰度保证。本页不嵌入／上传私人照片、文件名或截图。

本次核心 **79 通过**；App **270 项：269 通过、1 项真机文件保护在模拟器跳过、
0 失败（122.720 秒）**。请求 **38 通过（0.694 秒；此前 26，非 25，新增 12）**、
管线 **19 通过（1.124 秒）**、三路比较 **18 通过（0.074 秒）**、比较展示
**19 通过（1.340 秒）**。GeneratedModelParity **8 通过（94.326 秒）**，实际完成
真实 20 槽工厂的 **6 夹具／120 次预测／240 项归一化比较＋12 项张量测量＝252 项**；
原 **23 次预测／58 项测量**也通过且门槛不变。以上子套件均在 App 总数内；UI
**7 通过（202.650 秒）**，不是手机性能测量。

24 张 UI 截图已下载，**仅审核 3 张索引／地点界面**的
[../build/ui-review/35991227461/hq20-index-contact.jpg](../build/ui-review/35991227461/hq20-index-contact.jpg)
（990×742）：Library 回填后／零 GPS、Settings 尚未检查地点的可见内容清楚。
折叠项未展开，屏外联网页脚／20 worker 标签及其余 21 张均未视觉审核；合成场景
不是实际图库或硬件 20 路并发证据。
**PENDING-DEVICE**：本机签名／安装、迁移、20 槽稳定性、速度／内存／发热及文件保护；
**PENDING-LICENSE-REVIEW**：模型及地点再分发人工审查。完整状态见
[BUILD_STATUS.md](BUILD_STATUS.md)。

## 历史：0.3.3（build 9）— 首轮验证通过，新包已完整下载并校验

以下保留 build 9 的原始结果及当时步骤，“现在／本次”均指当时，不要求现在重做。
旧版“不跑索引”及截图诊断不适用于 build 10；更早版本的可选清库测速也不适用。

源码 `9e055b13be62ca184593387b1b5dc647b3a85a26` 的
[CI 35965638523](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523)
／[job 107523495276](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523/job/107523495276)
已 **SUCCESS，首轮通过**，日志确认 `TEST SUCCEEDED` 和设备 `BUILD SUCCEEDED`。
Swift 核心 **79 通过**；App **258 项：257 通过、1 项真机文件保护在模拟器跳过、
0 失败**，其中新增加载器 **18 项**、状态／展示 **19 项**及模型 parity **8 项**均通过；
UI **7 项全部通过**。这些不代表已在手机安装或验证真实 PhotoKit。

### 已备好的 build 9 安装包

- [../build/device-download/35965638523/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35965638523/LocalImageIQ-iphoneos-unsigned.ipa)
  **已实际完整下载**，有界流式读取核验实际长度／SHA-256 后才最终重命名；无需重新下载。
  [../build/device-download/35965638523/device-build.json](../build/device-download/35965638523/device-build.json)
  与 [../build/device-download/35965638523/SHA256SUMS.txt](../build/device-download/35965638523/SHA256SUMS.txt)
  均已存在，无部分下载残留，旧包保留。
- [IPA 产物 10794875285](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523/artifacts/10794875285)：
  外层 **1,414,738,797 字节**，内层 IPA **1,414,731,479 字节**；IPA SHA-256：
  `5c36d87fa1b5845a6806274a200ad602a917b778da5398b49116b2e9b303328b`。
- 设备报告确认 **0.3.3 / build 9、iphoneos18.5、arm64 Release、未签名、Xcode 16.4、
  最低 iOS 17.0**，同一 768 维 SigLIP 2 模型及地点包；仍须 Sideloadly 本机签名。

### 现在只做这几步

1. 用原 Sideloadly 账号、原有效 Bundle ID 覆盖安装并完成必要的系统信任。
  不卸载、不清索引、不重建，也不用点 Index / resume。
2. 打开 App 前先开飞行模式，并在系统设置中关闭 Wi-Fi；App 本身不检测飞行模式。
3. 打开 App，搜索 `a hand holding a broken white pen`，选此前找到的手持破损白笔照片；
  或选一张当前可访问的搜索结果。这是人工选图例子，不是 App 硬编码或固定排名。
4. 点开照片 → 底部“本地预览对比”。页面自动依次请求 Fast 224／高质量 224／高质量 480。
  等结束后先发默认三路“等框对比”截图，尽量带上三路图像和像素／标记；不可用也照实截图。
5. 可选切换“同一区域细节”，点下方参考图选择区域，再发一张。无需为了此诊断重建索引。

不要在测试前特意联网打开目标照片；这可能预热缓存。打开 App、正常搜索／大图加载及
前一路请求也可能影响后一路，三路都不绕过系统缓存。页面的网络关闭只表示请求禁止联网；
实际离线可用性要看手机结果。返回 CG 像素、方向与原始降质标记会显示在图下，
尺寸大或标记“否”不等于更清晰。

仅内存诊断，不调用索引 worker、编码器或 SQLite；SigLIP 2、四 worker、Places、
预处理／索引、正常显示及默认联网策略不变，不是质量修复。
24 张 UI 截图已下载，**仅审核 4 张新增预览图**的
[../build/ui-review/35965638523/local-preview-contact.jpg](../build/ui-review/35965638523/local-preview-contact.jpg)
（1340×758）：三列尺寸／元数据与等框、不可用状态、同一区域细节可见；大字号仅见菜单
和首个大面板，屏外元数据／其余面板未审核，未实际点击／滚动验证。像素为生成假数据。

**PENDING-DEVICE**：本机签名／安装、真实 PhotoKit 离线结果、速度／内存／发热等仍待验证。
**PENDING-LICENSE-REVIEW**：模型及地点再分发仍需人工审查。完整证据见
[BUILD_STATUS.md](BUILD_STATUS.md)，请求与测试边界见
[LOCAL_PREVIEW_COMPARISON.md](LOCAL_PREVIEW_COMPARISON.md)。

## 历史：0.3.2（build 8）— 4 worker 首轮验证通过，旧包已完整下载并校验

以下保留 build 8 的结果与当时测速步骤；它不含三路对比，不是本次清库／续跑要求。

源码：`b40d2faaf11b2f499779881b4863325fa7dae659`。
[CI 35848409845](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845)
／[job 107140049230](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/job/107140049230)
已 **SUCCESS，首轮通过**；App 版本已核验为 **0.3.2 / build 8**。
核心、模型导出、地点包、模型／App 资源检查、原生与 UI 测试及设备打包均通过；
新 IPA 已实际完整下载并校验本地字节数／SHA-256，不是下方旧 build 7 的包。
本次只记录已核验结果，不运行命令、测试、CI 查询／重试或下载，不签名或操作手机。

### 本版改变了什么

- 用户明确要求 **4 worker**：固定 4 槽滚动窗口，子任务各自完成 PhotoKit 取预览、
  预处理和图像推理，使用独立图像模型 actor。**进行中＋完成待提交合计最多 4 张**，
  完成但等待前序提交也占槽位；不再提交第 5 张未提交项，不无限积累预览／结果。
  每顺序提交一张就能补位，不是每 4 张一起等完的批次屏障。
- 复用一份常驻主图像模型，另 3 份仅图像模型在本次索引中按需懒加载、全部子任务
  结束后释放作用域持有。中央仍只有 **1 份文本模型＋1 份 tokenizer**，不是 4 份
  文本模型或四套图文模型。明确增加的是 **3 份图像模型及并发中间张量的内存代价**；
  不声称系统立即归还全部内存，更不保证 4 倍提速、手机耗时／内存／发热。
- 地点文本去重、写库和进度由父任务按快照顺序处理，成功保存后才发布计数。
  取消／错误退出会取消并等待全部最多 4 个子任务结束；同步预测可能要等返回，
  迟到 PhotoKit 回调仍由 gate 忽略。有效缓存命中不取预览、不做图像推理，纯缓存
  扫描不加载额外 3 份图像模型。没有新增任务超时、自动重试或图库数量／字节限制。
- 同一 SigLIP 2 权重／版本、FP32、预处理、`photokit-preview-v1`、2,943 要素
  四国地点包、评分及默认地点权重 **0.6** 均不变，联网仍默认关闭，不要求下载原图。
  build 8 本次资源检查已通过，设备报告确认同一模型及地点包身份。

### 本次实际验证

- Swift 核心 **79 通过**；App **221 项：220 通过、1 项真机文件保护在模拟器
  跳过、0 失败**。IndexPipeline **19 项全部通过**，含新增 4 项；新增默认工厂
  边界测试通过。原生子套件均已计入 App 总数，不重复相加。
- GeneratedModelParity **8 项全部通过（101.581 秒）**，含新增真实四图像 actor
  测试：6 夹具 × 4 槽＝**24 次预测、48 项归一化向量比较＋12 项张量测量＝60 项**。
  计数及图像余弦 **≥ 0.995** 门槛已断言通过；旧 **23 次／58 项**也通过，门槛未改。
- UI **7 项全部通过（209.329 秒）**；模型报告 `parityPassed:true`。未返回本次
  原始精确极值，不把旧版余弦／误差极值当成本次测量。

### 已完整下载并验证的 build 8 安装包

- [build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa)
  **实际完整流式下载已完成，本地字节数及 SHA-256 已验证**；校验文件与设备构建
  JSON 均已存在，无残留部分下载文件，无需重新下载。仍须 Sideloadly 本机签名。
- [GitHub 产物 10745235946](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/artifacts/10745235946)：
  外层 **1,414,636,737 字节**，内层 IPA **1,414,629,419 字节**。
- IPA SHA-256：`7d37581966a45028213a52a0a9c504e2ed273293a92bbbad4ab9d77a0d73ef8e`。
- 本次设备报告确认 **0.3.2 / build 8**，modelVersion 仍为
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`；
  **2,943 要素**地点包 GeoJSON SHA-256 仍为
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`。
  完整地点包身份见 [构建记录](BUILD_STATUS.md)。未签名包不等于已在物理 iPhone 执行。
- 已取回 **20 张**原生截图，**仅审核 3 张索引／地点界面**的
  [960×680 联系图](../build/ui-review/35848409845/four-workers-ui-contact.jpg)：
  Library 回填后、Library 零 GPS、Settings 尚未检查地点。折叠项未展开，未检查
  内部全部计数，其余 17 张不计入审核；合成界面不是用户 GPS 或四 worker 真机证据。

`PENDING-DEVICE`：签名／覆盖安装及物理手机表现尚无结果；没有实际速度／内存测试。
`PENDING-LICENSE-REVIEW`：模型及地点再分发许可仍需人工审核，不追加手机诊断任务。

### 使用已验证新包：正常升级复用缓存；从零测速是可选分支

1. 用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装 build 8**，不卸载 App，
   不为升级清空索引／缓存。
2. 正常使用 **Library → Index / resume**：有效 0.3.0／0.3.1 图像向量继续复用，
   地点照常检查／按需回填，新增或变化照片才图像编码。前台运行、联网关闭，中断可
   续跑。**升级不要求清空索引，也不要求整库图像重编码或下载原图。**
3. 用户明确希望从零测速时，可在**安装后主动选择 Settings → Clear index，再打开
  Library → Index / resume**，联网关闭、保持 App 前台。这会丢失已有索引／缓存，
  需要重新索引，**不会删除系统相册的照片**。这是可选测速，不是覆盖安装前提；
  本次文档编辑不会替用户清空或运行手机。

冷建测速比较 **0.3.1 与 0.3.2（同一地点包）**，两边都从空索引开始；保持同一手机、
同一批授权照片及数量、联网关闭、相近温度／发热和供电条件。不要拿旧版从零建库与
新版缓存续跑比较，也不要把 4 worker 写成 4 倍提速。除此以外，不要求额外诊断查询、
截图、索引抢救或数据回传。新包身份及已核验结果见 [构建记录](BUILD_STATUS.md)。

## 历史：0.3.1（build 7）— 首轮验证通过，旧包已完整下载并校验

以下是旧版 build 7 的测试、安装包和当时操作说明，不是 build 8 的交付或验证结果。

源码：`18ad52d37690ecfbf92b63a21285a6c3e8e753d4`。
[CI 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
／[job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763)
已 **SUCCESS，首轮通过，无需修复重跑**，包含 `TEST SUCCEEDED` / `BUILD SUCCEEDED`。
源码／静态 30 通过，核心 79 通过；App **215 项：214 通过、1 项真机文件保护在
模拟器跳过、0 失败**。全部 **7 个模型 parity 通过（67.736 秒）**，全部 **7 个 UI
测试通过（202.143 秒）**。公开地点生成校验、模拟器／设备 App 资源检查、iPhoneOS
arm64 Release 编译及 IPA 验证均已通过。完整测试明细和本次模型报告见
[构建记录](BUILD_STATUS.md)。本次仅记录已核验结果，不运行命令、测试、下载或查询 CI。

### 历史 build 7 安装包（不是 build 8 或当前 build 9）

- [build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa)
  **已实际完整下载**；有界内存流式长度／SHA-256 校验完成，下载后本地报告已写入并
  检查，无需重新下载。不要用下方历史 build 6 的包代替。
- [GitHub 产物 10741731376](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741731376)：
  外层 **1,414,628,123 字节**，内层 IPA **1,414,620,805 字节**。
- IPA SHA-256：`98fb537004a64adaa84b1ba15d798acaf71a0684555275faddc647d1adafd8d6`。
- 实际设备报告确认 **0.3.1 / build 7、iphoneos18.5 / arm64 Release、Xcode 16.4、
  最低 iOS 17.0、FP32、未签名**。仍需 Sideloadly 本机签名，不能直接安装；
  **用户安装后的物理 iPhone 行为尚未验证**。
- 20 张原生截图已取回，但只审核 3 张新增地点界面的
  [960×680 联系图](../build/ui-review/35840838147/index-places-contact.jpg)：
  Library 回填后、Library 零 GPS、Settings 尚未检查地点。可见内容可读；折叠项未
  展开，未视觉检查内部全部计数。数字为合成测试数据，不是用户 GPS 结果。

### 当时的 build 7 操作：覆盖安装＋一次地点回填

1. 用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**。不卸载、不清索引。
2. 打开 **Library → Index / resume** 跑一遍地点回填，保持 App 在前台、联网关闭。
  **仍有效的 0.3.0 图像向量直接复用，不取预览、不整库图像重编码**；新增或变化照片
  才按正常流程编码。中断后继续同一入口，不要求下载原图或“下载并保留原片”。
3. 完成后正常搜索、看图，不另加测试查询、诊断截图或性能数据回传任务。

这次没有再次换模型：图像和文本仍为同一 SigLIP 2 配对，`modelVersion`、FP32、
预处理及 `photokit-preview-v1` 与 0.3.0 相同。若仍保留 0.2.x 的 CLIP 旧索引，
才需要下方历史模型迁移；不能混用 CLIP 向量，也不能因此让已有 0.3.0 向量全部重算。

新增的是下一张缓存／PhotoKit 预览预取与当前张父任务处理重叠，仍单模型对、串行
推理、单一路径顺序保存；取消时取消并等待子任务，迟到 PhotoKit 回调被忽略。
没有新增任意数量／时间上限、多个推理 worker、联网默认变化或手机提速保证。

地点包覆盖中国、法国、德国、荷兰历史 ADM1／ADM2，代表年份 2017–2022；**实际设备包
检查**确认 **2,943 个要素、15,175,079 字节、CHN／FRA／DEU／NLD、8 个来源**，GeoJSON SHA-256
`41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`。
清单 SHA-256：`0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`。
这不是仅凭本地源码清单的声明，也不代表全球覆盖、街道地址或 POI。
Library 区分扫描时有 GPS／找到标签／无 GPS／无可用包／包外／不可用，未检查即未知；
扫描计数不是永久 GPS 总数，已保存标签数也不等于有 GPS 的照片数。
不新增当前手机位置权限或在线反查，原始坐标不保存、不上传。
默认地点权重 **0.6** 保持不变，但回填后地点分支开始实际参与评分，排名可能有意变化，
无需为掩盖变化改权重；不承诺私人图库地点覆盖数字。详见
[索引与地点说明](INDEX_PIPELINE_PLACES.md)。

## 历史：更新到 0.3.0（build 6）— 当时的新包已下载并校验

本节结果、下载链接和迁移步骤仅属历史 CLIP → SigLIP 2 升级，不是 build 7／8 交付证据。

用户已批准成对替换为 SigLIP 2。源码
`f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78` 的
[CI 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
／job `107062896845` 已 **SUCCESS**，包含 `TEST SUCCEEDED` / `BUILD SUCCEEDED`。
核心 79 通过；App 178 项，177 通过、1 项真机文件保护在模拟器跳过、0 失败；
全部 7 个原生模型 parity 测试通过（72.985 秒），全部 7 个 UI 测试通过。
生产 App 编码 API 测试已断言并通过 23 次预测（17 文本＋6 图像）、58 项测量。
完整导出测量和测试边界见 [构建记录](BUILD_STATUS.md)。

### 历史 build 6 安装包（不是 build 8 或当前 build 9）

- 本地已完整下载并校验的
  [build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa)。
  使用有界内存流式下载，**实际长度及 SHA-256 已验证完成**，无需重新下载。
- [GitHub 产物 10734323054](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795/artifacts/10734323054)：
  外层产物 **1,408,905,095 字节**，内层 IPA **1,408,903,848 字节**。
- IPA SHA-256：`529b8ae5f708f57d14929fccf4a374dfb943d0e950b7671239e99f69b5acd98e`。
- **未签名、FP32、iphoneos18.5 / arm64、最低 iOS 17.0**；使用 Xcode 16.4 /
  Swift 6 工具链（App 为 Swift 5 语言模式）。仍需 Sideloadly 本机签名，不能直接安装。
- 已取回 17 张原生截图，**仅审核首页／图库／设置／主结果布局 4 张**的
  [缩小联系图](../build/ui-review/35824403795/siglip2-ui-contact.jpg)。
  均为合成／测试场景，没有私人照片；不代表 17 张均已审核或手机性能已验收。

首轮源码 `aee4cdc00be92e1699f68baa9ef7ccc72cbcfbda` 的
[CI 35823153931](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35823153931)
已失败：模型导出通过，但原生图像几何／重采样及 Unicode Final Sigma 检查失败。
当时修正后的源码改为显式 Pillow 兼容的 22-bit 重采样器，不再用 CoreGraphics medium
插值完成模型缩放；`SigLIPTokenizer.normalizedQuery` 已包含 Unicode Final Sigma
规则。build 6 的 68×120、112×199 原生输入和精确 Gemma IDs／masks 均已通过，查询、
完整同张量检查和数值门槛未放宽。导出 JSON 的原生 `not-run` 产生于 XCTest 之前，
不是失败；随后通过的 XCTest 才是原生执行证据。

当时从 0.2.x 升级，使用上方已校验的 build 6 包：

1. 仍用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**。不卸载、不手动清索引。
2. **必须打开 Library → Index / resume**，用新模型建一次向量索引，保持联网关闭。
  模型已变，尚未生成新向量时旧模型记录的可用覆盖为 **0** 属于预期，不是需要清库。
  不用下载原图，不用改成“下载并保留原片”。中断后再点同一入口，已完成且仍有效的
  新版本记录会复用。
3. 完成后正常搜索、看图即可；不要求额外测试查询、单照片检查或截图回传。

0.3.0 与此前只改界面／诊断不同：图像和文本编码器一起换，schema 2、768 维、
64 token，来源固定为同一 `google/siglip2-base-patch16-224` revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`。App 用 `swift-transformers` 1.3.4
读取该模型的两份本地 tokenizer JSON。旧 CLIP 512 维行仅可解码用于迁移，不能
参与 SigLIP 2 搜索；图像及地点文本向量都需重算，不能混用。详见
[实现契约](IMPLEMENTATION_CONTRACT.md)。

本包 modelVersion：
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。

旧 IPA 保留，但照片记录按 `id` 主键被新向量逐条替换，**旧安装包不是旧索引备份**。
回退包不保证恢复已替换的旧记录；不要用卸载或清库来处理这次升级。

`photokit-preview-v1` 不变：本地预览优先、可接受低清图、联网默认关闭，用户显式
开启才可按需联网。不要求原图，也不承诺每张云照片都可离线读取；本次不是预览质量
修复。模型不保证所有语言、查询都更好，桌面 CPU 数字也不是 iPhone 性能。

以下两个升级小节也仅保留历史说明，不要求重新执行。0.3.2 的可选从零测速属于历史；
本次 0.3.3 预览对比不换模型、不清库、不重建，不适用历史 CLIP 整体换模型步骤。

## 历史：已装 0.2.0，更新到 0.2.1 检查版

仍用原账号、原有效 Bundle ID 覆盖安装，不卸载、不清索引。这个版本新增
**Check this photo** 按钮；检查结果只显示在手机上，不换模型、不修改索引向量。
操作见 [单照片检查](PHOTO_CHECK.md)。不要把检查误当作重建索引或检索质量修复。

## 历史：已装 0.1.1／0.1.2，更新到 0.2.0

直接把新版未签名 IPA 拖进 Sideloadly，用**原账号、原有效 Bundle ID 覆盖安装**。
不要卸载 App，不要清空或重建已有索引。此版仅重做界面和权限提示时机，不改
模型、排序、预览输入策略或联网默认值；检索质量问题仍待单独处理。

安装后检查：首页搜索；结果大图／紧凑网格切换；点图后翻页、缩放、关闭与分享；
搜索后键盘收起；Library／Settings 能正常打开、关闭。索引、授权和 iCloud 开关
现在放在 Library；结果数量在 Settings，权重和分数在 Advanced。

## 先区分两种构建

- `LocalImageIQ-Simulator.zip`：模拟器程序，**不能用于 iPhone 安装**。
- `LocalImageIQ-iphoneos-unsigned.ipa`：使用 `iphoneos` SDK 为 arm64 编译的
  真机程序，内含 `Payload/LocalImageIQ.app` 和两个已编译 Core ML 模型。
  它是**未签名**包，不能直接点击安装，必须由本机工具签名。
- `device-build.json` 记录实际 SDK、最低 iOS、架构、模型版本、大小及 SHA-256；
  `SHA256SUMS.txt` 用于校验下载。不把模拟器 arm64 当成真机 arm64：构建同时
  验证 Info.plist 的 iPhoneOS 平台和 Mach-O 的 IOS 平台标记。

设备运行比构建 SDK 更新的 iOS，不代表应用一定不能运行；最终仍需测试实际
安装、系统授权、内存和推理行为，不声称云端模拟器替代了 iOS 26.6.1 真机验证。

**以下通用步骤可用于已经交付并校验的 build 11 IPA**；本机文件及另一台电脑的私有
Release 入口见页首。另一台电脑需自行下载并核验同一包；签名／真机表现仍待确认。

## 1. 安装工具（由你操作）

从 [Sideloadly 官方网站](https://sideloadly.io/) 下载 Windows 64-bit 版本，
不要从镜像站、网盘或所谓“免签平台”获取。安装器的 UAC／管理员确认由你处理。
若这是受管理的工作电脑，先确认允许安装第三方签名工具和 Apple 设备驱动。

工具若提示缺少 Apple Mobile Device / iTunes / iCloud 组件，按其当前官方
安装提示补齐。**不要未经确认卸载你已有的 iTunes、Apple Devices 或 iCloud**；
不同分发版本的驱动兼容性按工具实际提示排查。

Sideloadly 自己的 [隐私声明](https://sideloadly.io/privacy) 声称 Apple 凭据只发送
给 Apple；这只是开发者声明，不是本项目对工具的安全审计。首次使用需要接受
这个第三方工具的信任边界；不向任何聊天、GitHub Secrets 或本项目脚本提供密码。

## 2. USB 连接手机

1. 用支持数据传输的 USB-C 线连接 iPhone 和这台 Windows，解锁手机。
2. 在手机弹窗选择“信任此电脑”，手机密码仅在手机上输入。
3. 等 Sideloadly 中的设备列表显示你的 iPhone。没有识别时先排查驱动／线缆，
   不反复提交 Apple 登录。

## 3. 签名安装

1. 将已完整下载并校验的
  [../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa)
  拖进 Sideloadly；另一台电脑先登录页首私有 Release 下载并校验同一包。
  历史 build 10／9／8 包都不含本次翻译功能，不作替代。
   新 Release 单独提供 IPA，无需解压外层 Actions ZIP；**不解压或修改 IPA 的 Payload**。
2. 选择已连接的 iPhone，使用原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，
   不卸载、不清索引；Apple Account 必须是本人有权使用的账号。
3. 点击 Start；密码及双重认证仅由你在工具／Apple 登录流程中手动输入。
   如工具明确要求普通密码或 App 专用密码，以当前官方说明为准，不互相替代试错。
4. 不启用 dylib 注入、插件或其它改包功能。首次签名可能需要调整开发用 Bundle ID；
   保持之后重签所用账号／标识一致，不随意删除旧 App 以免丢失其本地索引。

## 4. 手机上完成信任

- 如提示“未受信任的开发者”，在“设置 → 通用 → VPN 与设备管理”找到自己的
  开发者身份并信任，只信任你刚使用的账号，不安装陌生企业描述文件。
- iOS 16+ 开发测试通常需要“设置 → 隐私与安全性 → 开发者模式”，开启后按系统
  要求重启和确认。菜单暂时不出现时，先完成一次配对／开发签名安装再检查。
- 若遇到账户或设备管理政策禁止开发者模式，停止并确认政策，不绕过设备管理。

## 5. build 11 安装后：准备语言包，沿用已有索引

新包已交付并完成本地校验；覆盖安装后，打开 **Settings → 中文搜索增强 → 简体中文 →
英文 → 下载离线语言包**，同意系统下载并确认就绪，再搜索 **身份证**，查看实际英文及
“使用原文”对照，不保证输出 “ID card”。可选断开全部网络验证真机；照片 Network 保持 OFF。
已有 build 10 当前策略索引不清库、不重建图像或地点、不必跑 Index / resume。
更早模型／输入策略尚未迁移的情况才参考历史迁移；不因翻译升级重做整库诊断。

## 隐私与模型许可不因本次更新而放宽

照片、坐标和向量仍在本机处理，不上传图库；应用不扫描未授权照片。PhotoKit
网络默认关闭，只有用户主动开启后才可按需访问 iCloud；不会要求下载整库原图。
系统语言包准备是独立的用户同意流程，不改变上述开关；原文／译文在设备上处理，
不上传到 App 服务器，无 App 云端兜底。系统可能收集不含原文／译文的使用及性能指标；
“本地翻译”不等于系统绝无任何网络活动，语言包竞态提示边界见页首。
Apple 凭据仍只由用户在本机签名工具／Apple 流程处理，不交给聊天或 CI。

共享 SigLIP 2 模型卡声明 Apache-2.0，导出流程复制实际存在的模型卡／LICENSE／NOTICE
证据，并保留 `redistributionApproved:false` 及人工许可审查。复制许可证、数值测试
通过或个人签名成功，都不是公开分发的法律认证。地点包的来源／年份／许可记录已随包
保存，同样不能代替再分发许可审查。正式发布还需 App 图标、正式 Bundle ID、
签名及 TestFlight／商店配置；当前未提交商店。

## 免费账号的限制

开发描述文件通常 **7 天**失效，需要通过电脑重新签名刷新；这不是永久安装。
通常每台设备最多同时 3 个免费开发应用，App ID 创建也有限制。Sideloadly 提供
自动刷新功能，但是否启用常驻服务／Wi-Fi 刷新由你决定，本项目不会偷偷安装。
TestFlight / App Store 分发仍是另一条需要相应开发者资格的路线。

当前只准备自己的开发测试程序，不越狱、不绕过付费、不使用来历不明的证书。
参考：[Sideloadly FAQ](https://sideloadly.io/faq) ·
[Apple Personal Team 限制](https://developer.apple.com/support/compare-memberships/)。