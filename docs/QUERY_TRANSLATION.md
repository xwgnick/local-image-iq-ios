# 中文搜索增强 · 0.4.0（build 11）

## 状态：私有 Release 首次尝试成功；IPA 已完整下载并校验

用户已批准 Apple Translation，现又明确批准**方案 2：同一私有仓库 Release＋job 级
contents: write**。新源码 `844492b754f86d519c904da21cd80c1c814c056b` 相比原生／
设备验证通过的 `0c09c46ff5edf74ffeb4a2cece2f7b9fd20a5910`，只改工作流和两个
发布／测试脚本，**没有 App、翻译、索引或模型改动**。发布器 **83 项本地 Node 22 mock
测试通过，CI 对应步骤也 PASS**。
[CI 36387878343](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343)
／[job 108817040032](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343/job/108817040032)，
已 **COMPLETED / SUCCESS**，实际 `TEST SUCCEEDED` 和设备 `BUILD SUCCEEDED`。
这是**两次 Actions artifact 配额失败后的首次私有 Release 尝试成功**，不改写前两轮历史。
[私有 Release：ci-36387878343-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)
（ID **398009938**）于 **2026-09-28T06:55:36Z** 发布，**prerelease、非 draft、非 Latest**；
9 项资产（8 载荷＋交付清单）全部上传并通过 API SHA-256 核验。

新交付使用同仓库私有 Release，不占 Actions artifact 存储配额；保留全部原生门槛，
资产全量验证后才从唯一 DRAFT 发布为非 Latest 的 prerelease。失败／部分上传不是交付，
不覆盖或删除旧 Release、tag、资产，不新增 PAT 或 Apple 凭据。私有访问控制、计费设置
不变，macOS 分钟仍按原规则计量；不是公开分发或商店安装。契约与本机只读下载 helper
见 [PRIVATE_RELEASE_DELIVERY.md](PRIVATE_RELEASE_DELIVERY.md)。

**历史不改写**：[首轮 36382669765](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36382669765)
仅两项上传配额失败，设备构建跳过；[第二轮 36383757627](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36383757627)
原生、iPhoneOS 编译及 runner 包验证通过，仍因 Upload UI／Keep evidence 配额失败，
IPA 上传跳过，artifacts API 为 `[]`。两轮截图导出通过但均未取回／审核。
已获批删除的 **10 个旧 IPA 云端产物共 10,615,840,970 字节**，对应本地备份逐份核验
长度／SHA-256 后保留；其余证据未删。只是交付路线改变，**不声称 Actions 配额恢复**。
完整清理、配额说明与两轮账本见
[BUILD_STATUS.md](BUILD_STATUS.md)。

**DELIVERED**：[../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa)
已实际全量下载，父进程直接流式复验长度／SHA-256 一致，`ipaVerifiedLocally: true`，
报告／清单齐全，无部分下载残留，旧包保留。IPA asset **594739443**，**1,414,801,288 字节**，
SHA-256：`6043afbe68a84edd16d1314ecf4369f308bff8d7cf676392aee5eee6a950ca71`，
不复用第二轮 runner 身份。另一台电脑可登录 **xwgnick 或具私有仓库读取权限的账号**，
从上述 Release 下载并核验同一包。**PENDING-DEVICE**：真实系统翻译仍未测量。此次只改文档，
不执行命令、查询 CI、追加触发或下载；以下功能说明不构成真机验证声明。

## 支持范围与开关

- App 最低系统仍为 **iOS 17**；系统翻译仅在 **iOS 18+ 物理 iPhone**启用，且还需
  系统支持对应语言对。iOS 17、模拟器及 Mac Catalyst 走原文回退；模拟器不运行真实
  Apple Translation。本轮设备报告确认 **0.4.0 / 11、Xcode 16.4／iphoneos18.5、
  arm64 Release、未签名**，最低系统并未提升到 18。真机专用翻译分支编译通过，
  报告与包已下载并校验，但不是物理手机运行证据。
- 这是系统 Translation 框架，不是 Apple Intelligence／通用 LLM 接入；不声称需要
  Apple Intelligence 资格、特定 LLM 或其下载。语言对能否使用，以系统可用性检查为准。
- **Settings → 中文搜索增强**默认开启。只有生产 App 入口注入 `UserDefaults.standard`，
  以 `chineseSearchEnabled.v1` 保存开关；普通／测试 `AppState` 默认不写标准偏好域。
  本功能不持久化查询、译文或照片信息；语言包选择本身不持久化，初始为简体。
- 输入有 Han 汉字且不含假名／Hangul 时，把**整个中文或中英混合输入**送去译成英文，
  不拆词、不做“身份证”等关键词替换。纯英文及无 Han 输入绕过翻译；含假名或 Hangul
  的输入即使也有 Han 仍绕过。纯 Han 短句可能是日文等，不能把脚本检测当成准确语种识别。
  系统 `NLLanguageRecognizer` 判为繁体时选 `zh-Hant`，否则选 `zh-Hans`，目标均为 `en`。
- Settings 的“简体中文 → 英文／繁體中文 → 英文”选择器只决定**准备／检查哪个语言对**，
  不强制后续查询使用这个来源语言；实际搜索仍按上面的输入检测选择。需要繁体时应单独
  选择并检查／准备该语言对，不能把简体就绪当成繁体也就绪。

## 搜索与下载是两个入口

1. 普通查询只在点击搜索按钮或键盘 Search **提交后**解析，不逐键翻译。
   `AppState` 先检查语言对，服务提交前再次做未缓存的可用性检查，SwiftUI host 的
   `translationTask` 内在调用 `session.translate()` 前再检查一次；搜索必须得到
   `.installed`，不信任 Settings 里旧的“就绪”状态。
2. 已知缺包、系统／语言对不支持、检查失败、翻译失败或空译文时，显示固定的原文回退
   提示，再把**同一份原始输入**交给原搜索 worker。普通搜索不显式调用
   `prepareTranslation()`，没有 App 云端翻译、查询服务器或云端兜底。
   取消不是翻译失败回退：取消时停止本次工作，不继续原文搜索。
3. 只有用户在 Settings 点击“下载离线语言包”（已就绪时为“检查离线语言包”）才进入
   显式准备入口。缺包时调用 `prepareTranslation()`，由系统请求用户同意下载；用户
   可拒绝或取消，原文搜索仍可用。已安装时只复查，不重复调用准备 API。
4. 系统准备调用返回**不等于语言包已安装**：host 返回前、状态发布前都会复查。
   未达到 `.installed` 不报就绪，显示未完成／尚未就绪提示；可稍后重新打开 Settings
   或点击检查／准备。下载需要网络和设备空间，**与 Library 的照片 iCloud 联网开关独立**，
   不改变照片授权、PhotoKit 网络偏好或现有索引，也不会为准备语言包启动图库工作。

**系统竞态边界：**可用性检查和 `session.translate()` 之间没有锁住系统语言包的原子
操作。iOS 18／当前 SDK 的 session API 在这段间隙若遇到语言包被移除，仍可能请求
系统下载／同意提示；重复检查不能消除此竞态。因此“搜索不显式准备、已知缺包回退”
**不是“任何情况下绝无 OS 下载提示”的保证**，也绝不表示 App 会改走云端翻译。

语言包占用**系统管理的存储空间**，不打进 IPA；本次语言包实际大小未测量。
本轮设备报告确认 SigLIP 2 **768 维／modelVersion**、Places **2,943 要素／
15,175,079 字节**及模型／地点包身份未变，完整身份见[构建账本](BUILD_STATUS.md)。
新 IPA 实测 **1,414,801,288 字节（约 1.4 GB）**，不是手机所需总空间；哈希见上。
原文／译文在设备上处理，不上传到 App 服务器；UI 同时提示系统可能收集不含原文或
译文的使用与性能指标，不能将“本地翻译”写成整个系统绝无任何网络活动。

## 结果、原文对照与单照片检查

- 搜索框保留用户原始输入，翻译成功后结果上方显示“已用英文搜索：…”及实际有效英文。
  同一 worker 使用有效文本，其模型、评分公式、结果数量和地点权重不因翻译改变；
  查询文本变了，排名可能变好也可能变差，不保证质量提升。
- “使用原文”只绕过**这一次**翻译，不关闭或改写保存的增强开关。之后点普通 Search
  或“使用英文翻译”又会正常检查／翻译；编辑输入或搜索设置会清除旧结果，等待再次提交。
- **Check this photo** 初始文本取已完成搜索的 `completedSearchQuery.effective`；
  原文回退／原文搜索时它就是原文，没有已完成结果时才退到当前输入。
  检查框可编辑，点击 Check 使用框内字面文本，**即使改成中文也不再翻译**，不改首页
  输入、不写回索引。检查卡历史标签“Original query”指这次诊断提交的文本，可能是英文，
  不是保证显示翻译前中文。本次升级不要求做任何单照片或整库诊断。

## 取消与 host 生命周期

- 保留串行任务链：后继任务必须等待前一任务结束，而不是只发取消。查询、地点权重、
  结果数量、增强开关的编辑，以及 Cancel／真正进入后台，会使相关搜索失效；任务取消位、
  operation token 和可用性 token 拒绝迟到结果。更换准备语言、取消准备或关闭 Settings
  也会使相关准备失效；这些不是图像索引策略变化。
- 搜索 host 在根视图，准备 host 在 Settings 内，分别注册用途与身份。每个不可变 job
  只能被一个闭包认领；待启动请求可直接结束，**已激活 host 的闭包必须 drain**后才释放
  槽位／恢复调用者。取消、host 消失或被替换后，不发布旧成功；迟到旧 host 不影响新请求。
  `TranslationSession` 只在系统提供的闭包内使用，不保存或交给额外 Task。
- 系统同意框可能仅造成 `.inactive → .active`。没有真正进入后台时，重复 `.active`
  **不会刷新并取消同意／准备流程**。这不承诺系统下载瞬间停止，也没有新增超时或重试策略。

## 索引与照片策略不变

仍为 **20 个独立图像 worker**、HQ224 本地优先／缺资源才 Fast224 的
`photokit-hq224-fast-fallback-v1`、同一 SigLIP 2 成对模型／FP32／768 维、预处理、
`modelVersion`、图像及地点缓存身份、2,943 要素 Places 包及默认地点权重 0.6。
PhotoKit 联网默认关闭且继续独立显式授权；本功能不改变图像索引、正常看图或三路诊断。

**已有 build 10 当前策略有效索引：不清库、不重建图像或地点、不必跑 Index / resume。**
仍在更旧模型／输入策略的记录才适用历史迁移要求，不能把它当成翻译升级要求；新照片或
变化照片的正常增量索引另当别论。20 worker 的既有内存风险不因翻译消失，也不新增提速承诺。

## 本轮测试通过；仅四张新增截图已做有限审核

**本轮 36387878343 实测**：核心 **79 通过**；App **349 项：348 通过、1 项真机文件保护在
模拟器跳过、0 失败（108.139 秒）**。**42 状态（0.404 秒）＋32 桥接（0.310 秒）＋
5 展示（0.438 秒）全部通过**；GeneratedModelParity **8 通过（81.423 秒）**，真实
20 槽生产工厂 **120 次预测／252 项测量**及原 **23／58** 门槛均通过且未改。
这些子套件已计入 App 总数；独立 UI **7 通过（199.344 秒）**。耗时不是手机性能。

**第二轮历史（36383757627），不作为本轮结果**：核心 **79 通过**；App **349 项：348 通过、1 项真机
文件保护在模拟器跳过、0 失败（118.821 秒）**。新增 **42 状态（0.435 秒）＋32 桥接
（1.384 秒）＋5 展示（0.561 秒）全部通过**，已计入 App 总数；独立既有 UI **7 通过
（202.326 秒）**。GeneratedModelParity **8 通过（83.298 秒）**，包括真实 20 槽生产
工厂的 **120 次预测／240 项归一化比较＋12 项张量测量＝252 项**；原 **23 次预测／
58 项测量**也通过，门槛未改。管线 **19 通过（1.865 秒）**、请求 **38 通过（0.880 秒）**，
均在 App 总数内；这些耗时不是手机性能。

**首轮历史（36382669765），不借用为第二轮结果**：App **349 项：348 通过、1 项真机文件保护在模拟器
跳过、0 失败（122.833 秒）**。新增 **42 项状态（0.411 秒）＋32 项桥接（0.056 秒）＋
5 项展示（0.461 秒）全部通过**，已计入 App 总数；独立既有 UI **7 项全部通过
（201.613 秒）**。核心步骤通过，但 **79 仅为既有／预期计数，首轮日志数量未单独核实**；
设备编译／IPA 步骤跳过。四张截图属于上述 5 项展示测试，不是 4 项新增 XCUITest。

- 状态测试用假翻译／假 worker 检查整句路由、原文回退、一次性原文、诊断、偏好隔离、
  取消／迟到完成及前后台行为。桥接测试覆盖真实服务的无 session continuation 交接和
  host 身份／drain，不调用真实语言可用性、翻译 session 或下载。
- 展示测试托管真实 `ContentView`／`SettingsSheet`，注入假翻译和零结果 worker，带
  `TEST FIXTURE · fake translation · no photos` 水印。仍构造 Photos 包装并读取授权，
  不是零 PhotoKit API；夹具要求模拟器无照片读取权限，不符可跳过。没有真实照片请求、
  编码器／数据库／网络或真实系统下载弹窗，也不是 XCUI 点按钮验证。

前两轮截图生成／导出通过但上传因配额失败，图像仍未取回／审核。本轮 UI 截图 ZIP
（asset **594739319**，**3,116,697 字节**）已下载并验证 SHA-256：
`dddc29df265e55276ffa5dd66c4ae18de7ad53b9fbc2d51716382baa2a6f2942`。
**仅提取以下四张新增 PNG**，已实际查看
[1340×758 联系图](../build/ui-review/36387878343/query-translation-contact.jpg)；
其他图片未提取／查看，ZIP 内截图总数未核实。5 项展示测试不是按钮 UI 自动化。

| 已提取／审核附件 | 场景 | 实际审核范围 |
| --- | --- | --- |
| UIReview-query-translation-translated | 393×852，普通翻译态 | 原中文、有效英文与“使用原文”可读。 |
| UIReview-query-translation-missing-pack | 393×852，缺包回退 | 回退提示及设置入口可见。 |
| UIReview-query-translation-settings-language-pack | 393×852，Settings 语言包区域 | 四个控件可见，完整页脚在屏内且可读，但较密。 |
| UIReview-query-translation-translated-accessibility-large | 375×667，大字号 | 原文、英文与“使用原文”可见；下方空状态延伸到屏外，不是整页可见性证明。 |

Settings 自动测试只约束四个控件行；本次页脚可读来自实际图像审核，不把它扩写为自动
断言或所有字号保证。没有点击／滚动验收；均为假翻译／零结果合成截图，不是 Apple
译文质量或真实下载弹窗证据。本轮模拟器测试及设备编译通过仍**不能证明
真机离线翻译可用性、真实译文／检索质量、首次／后续延迟或系统同意弹窗行为**。

## 现在可用已校验的新 IPA：签名安装后准备语言包

1. 使用页首**已实际完整下载并校验的 build 11 IPA**，无需再等 CI；另一台电脑先登录
  私有 Release 下载并核验同一包。
   原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引；现有 build 10
   当前策略索引无需重新编码图像或地点，不为此升级跑索引。
2. Settings → 保持“中文搜索增强”开启 → 选“简体中文 → 英文” → “下载离线语言包”，
   联网并同意系统提示，确认“离线语言包已就绪”；繁体需求另选繁体准备。准备未完成时
   可稍后复查，不能把返回 App 当作下载已完成；照片 Network 开关可一直 OFF。
3. 回首页搜索 **身份证**，看实际英文提示与结果；可把显示的英文直接搜索作对照（英文
  绕过翻译），再以中文搜索后的“使用原文”比较。不预设系统一定译为 “ID card” 或必定改善。
4. 可选：语言包就绪后，关闭 Wi-Fi 和蜂窝等全部网络（飞行模式后确认 Wi-Fi 也关闭），
   在物理手机重新提交中文搜索，检查英文提示／结果。这才是该手机当次离线行为的证据；
   App 不检测断网，不等于所有语言／查询均获验证。不要求清库、全图库重跑或诊断截图。

交付账本见 [BUILD_STATUS.md](BUILD_STATUS.md)，签名安装见
[WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。

源码依据：[路由与协议](../App/State/QueryTranslation.swift)、[搜索状态](../App/State/AppState.swift)、
[系统桥接](../App/Translation/AppleQueryTranslationService.swift)、
[系统 host](../App/UI/AppleQueryTranslationHost.swift)、[生产偏好入口](../App/LocalImageIQApp.swift)、
[搜索 UI](../App/UI/ContentView.swift)、[设置 UI](../App/UI/SettingsSheet.swift)、
[检查 UI](../App/UI/PhotoCheckSheet.swift)及[展示测试](../Tests/QueryTranslationPresentationTests.swift)。