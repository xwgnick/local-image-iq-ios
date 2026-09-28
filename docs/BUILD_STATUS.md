# Cloud build status — 2026-09-28

## Current: 0.4.0 (11) — native/package PASS; second run COMPLETED / FAILURE (upload quota only)

用户已批准系统 Apple Translation。以下记录交接提供的已核验证据，本次仅编辑指定
四份文档，不执行 Git、命令、测试、CI 查询／重试、下载或手机操作。源码已提交；
本次最终文档检查点留待父流程提交，不把文档提交视为另一次 CI 验证。

- **首轮**：源码 `7b63e3539cdd34a2c7593b5f3431775af72e2dda`，
  [Run 36382669765](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36382669765)
  ／[job 108801470042](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36382669765/job/108801470042)
  最终 **FAILED**。失败步骤仅 **Upload UI／Keep evidence**，均为产物存储配额问题；
  不是原生测试失败。错误：`Failed to CreateArtifact: Artifact storage quota has been hit.`
  GitHub 提示用量每 **6–12 小时**重新计算。
- **当前源码**：`0c09c46ff5edf74ffeb4a2cece2f7b9fd20a5910`，补充准确的语言包竞态
  UI 提示，并将设备构建移到**首次 artifact 上传之前**；没有跳过测试或放宽门槛，
  版本仍为 **0.4.0 / build 11**。
- **第二轮最终结果**：个人仓库 `xwgnick/local-image-iq-ios`（`personal`）的
  [Run 36383757627](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36383757627)
  ／[job 108804722901](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36383757627/job/108804722901)
  已 **COMPLETED / FAILURE**。原生 `TEST SUCCEEDED`、iPhoneOS `BUILD SUCCEEDED`、
  包验证 **SUCCESS**；仅 **Upload UI／Keep evidence** 两项因同一 artifact 配额失败。
  **IPA 上传因 UI 上传失败而 SKIPPED**，不是设备构建或打包失败。
- **BLOCKED-DELIVERY**：artifacts API 返回 `[]`。设备报告／IPA 身份仅来自 **job 日志中的
  runner 本地产物**，没有上传产物 ID，没有本地新 IPA／下载后报告／完整下载校验；
  UI 截图也未取回或视觉审核。第二轮阻塞已确认，停止额外重试，等待与用户商讨。

### 本次源码范围与边界

- 系统翻译仅 **iOS 18+ 真机**，iOS 17／模拟器不支持时用原文；最低系统仍 17。
  第二轮 job 日志确认 **Xcode 16.4／iphoneos18.5、arm64、未签名**；真机专用
  Translation 分支已编译通过，但没有真机运行结果。
  不声称需要 Apple Intelligence 或 LLM。默认开启的增强开关仅由生产入口注入
  `UserDefaults.standard` 持久化，不保存查询／译文。
- 提交搜索才翻译中文或中英混合整个输入，英文及含假名／Hangul 的输入绕过；Han
  短句可能歧义，简繁由系统 `NLLanguageRecognizer` 选择。Settings 的简体／繁体 →
  英文选择只用于语言包检查／准备，与照片 iCloud 联网许可分开。
- 搜索在状态层、服务提交前及 host 内调用前检查 `.installed`；缺包／非取消失败可见
  回退同一原文，不显式调用准备 API，无 App 查询服务器或云端翻译兜底。**检查与调用无
  原子锁**：期间语言包被移除时，iOS 18 session 仍可能请求系统下载提示，不能保证
  所有竞态下绝无 OS 弹窗。只有显式准备入口调用 `prepareTranslation()`，缺包由用户
  同意；返回后仍复查，不把准备返回当作就绪。
- 搜索框保留原文，显示有效英文；“使用原文”只绕过本次。单照片检查使用已完成搜索的
  有效查询，编辑框按字面检查，不再次翻译。取消／编辑／后台拒绝迟到结果，活跃 host
  drain 后才放行后继；没有后台切换的重复 active 不取消同意流程。
- **20 worker、HQ224／Fast、`photokit-hq224-fast-fallback-v1`、SigLIP 2／FP32／768 维、
  预处理、模型／图像和地点缓存身份、2,943 要素 Places 及照片联网默认值均不变**。
  已有 build 10 当前策略索引不需清库、图像／地点重建或索引续跑。语言包占系统空间，
  不打进 IPA；runner 报告的 IPA 大小为 **1,414,801,289 字节**，不是 Windows 本地
  下载测量。语言包实际大小仍未测量。

### build 11 验证账本：第二轮实测与首轮历史分开

第二轮为 **36383757627／0c09c46f**，首轮为 **36382669765／7b63e353**。
App 子套件已计入各轮 349 项，不重复相加；耗时不是手机性能，不混用两轮数值。

| 项目 | 第二轮最终证据 | 首轮历史证据 |
| --- | --- | --- |
| 源码／公开地点包／模型导出 | 步骤 SUCCESS；不引用历史数值极值作本轮测量。 | 步骤 SUCCESS。 |
| Swift 核心 | 79 通过，已核实。 | 步骤 SUCCESS；79 仅为既有／预期计数，首轮数量未单独核实。 |
| App XCTest | 349 项：348 通过、1 项真机文件保护在模拟器跳过、0 失败；118.821 秒。 | 同为 349／348 通过／1 跳过／0 失败；122.833 秒。 |
| `QueryTranslationStateTests` | 新增 42 项全部通过；0.435 秒。 | 42 通过；0.411 秒。 |
| `AppleQueryTranslationBridgeTests` | 新增 32 项全部通过；1.384 秒。 | 32 通过；0.056 秒。 |
| `QueryTranslationPresentationTests` | 新增 5 项全部通过；0.561 秒。 | 5 通过；0.461 秒。 |
| `GeneratedModelParityTests` | 8 通过；83.298 秒。真实 20 槽生产工厂完成 6 夹具 × 20＝120 次预测，240 项归一化比较＋12 项张量测量＝252 项；原 23 次预测／58 项测量也通过，门槛未改。 | 本检查点不补写首轮子套件耗时。 |
| `IndexPipelineTests`／`IndexingImageRequestTests` | 分别 19 通过（1.865 秒）／38 通过（0.880 秒）。 | 本检查点不补写首轮子套件耗时。 |
| UI 测试 | 既有 7 项全部通过；202.326 秒。 | 7 通过；201.613 秒。 |
| 截图生成／导出 | 生成测试通过，导出步骤 SUCCESS；未取回／未逐项核验／未视觉审核。 | 导出 SUCCESS；未下载／未审核。 |
| 原生／设备编译与包验证 | PASS-NATIVE／PASS-PACKAGE：TEST SUCCEEDED、iPhoneOS BUILD SUCCEEDED、包验证 SUCCESS；报告仅见 job 日志。 | 设备编译／IPA 步骤 SKIPPED；没有设备报告或新包身份。 |
| 上传与交付 | Upload UI／Keep evidence 配额失败；IPA 上传 SKIPPED；artifacts API `[]`，未交付。 | 同为两项上传配额失败；未交付。 |

**PENDING-DEVICE**：签名／覆盖安装、系统同意与语言包就绪、断网翻译、质量／延迟，
以及既有 20 槽稳定性、内存／发热和文件保护仍待真机验证。
**PENDING-LICENSE-REVIEW**：模型／地点人工审查要求不变。

### 第二轮 runner 包身份：仅来自 job 日志，不是下载／交付验证

- 设备报告：**0.4.0 / build 11、iphoneos18.5、arm64、Xcode 16.4、未签名**。
  这是设备 SDK 编译／包验证通过，不是物理 iPhone 安装或系统翻译运行通过。
- 同一 **768 维 SigLIP 2**，`modelVersion` 不变：
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。
- Places **2,943 要素／15,175,079 GeoJSON 字节**；GeoJSON SHA-256：
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`；清单 SHA-256：
  `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`。
- runner IPA **1,414,801,289 字节**；日志报告 SHA-256：
  `fc449baec02d71c1c868acdc4e7ca8e459566575b89b189d4018e8ee79c094ba`。
  **没有上传、没有 Windows 本地新 IPA、没有下载后长度／SHA-256 复验**；不提供不存在的
  新包／本地报告链接，也不假定 runner 结束后仍能取回该包。

### 截图与系统翻译的证据边界

状态／展示使用假服务；桥接测试覆盖真实服务的 **session-free** continuation／host
交接，不调用真实系统翻译。展示测试托管真实 SwiftUI 视图、假翻译／零照片结果并加
TEST 水印，仍构造 Photos 包装并读授权，不是零 PhotoKit API；模拟器若已有读照片
权限等条件不符可跳过，两轮这五项实际均通过。截图生成测试及导出步骤通过，设计包含
以下**四个**附件，不是新增四项 UI 交互测试；未逐项取得／核验图像，更未视觉审核：

| 预期附件名 | 场景 | 产物／审核状态 |
| --- | --- | --- |
| UIReview-query-translation-translated | 英文有效查询／使用原文，393×852 | 上传受阻，未逐项核验／未下载／未审核 |
| UIReview-query-translation-missing-pack | 缺包可见回退，393×852 | 上传受阻，未逐项核验／未下载／未审核 |
| UIReview-query-translation-settings-language-pack | Settings 语言包控件，393×852 | 上传受阻，未逐项核验／未下载／未审核 |
| UIReview-query-translation-translated-accessibility-large | 大字号英文提示，375×667 | 上传受阻，未逐项核验／未下载／未审核 |

不能把假截图当成真实系统下载弹窗，或把桥接／状态通过当成真机离线、翻译质量及延迟
证据。完整行为及检查／下载竞态边界见 [QUERY_TRANSLATION.md](QUERY_TRANSLATION.md)。

### 已批准且完成的清理：9＋1＝10 个已有本地备份的旧 IPA 云端产物

用户仅批准删除已有有效本地备份的旧 IPA 云端产物。清理分两阶段，**各备份在删除
对应云端产物前均重新核验实际长度／SHA-256**；全部 10 份本地 IPA 保留并再次核验有效。
源码、运行日志、测试报告均未删除；没有清理其他仓库，也没有更改计费设置。

| 阶段 | 已删除的云端 IPA artifact ID | 对应 run |
| --- | --- | --- |
| 首批 9 个 | 10675548340 | 35683805304 |
| 首批 9 个 | 10678914749 | 35694536774 |
| 首批 9 个 | 10684943653 | 35708194014 |
| 首批 9 个 | 10732805206 | 35817552815 |
| 首批 9 个 | 10734323054 | 35824403795 |
| 首批 9 个 | 10741731376 | 35840838147 |
| 首批 9 个 | 10745235946 | 35848409845 |
| 首批 9 个 | 10794875285 | 35965638523 |
| 首批 9 个 | 10805190700 | 35991227461 |
| 后补 1 个（最早 IPA） | 10656339002 | 35636586662 |

- **首批 9 个**：合计 **9,906,302,776 远端字节**。
- **后补 1 个**：发现此前遗漏的最早 IPA，run **35636586662**／artifact
  **10656339002**；远端 **709,538,194 字节**，本地 IPA **709,536,954 字节**。
  删除前已验证本地长度与 SHA-256：
  `f4027e85899914735d0d4f17fbbb727e0f4ca06c6406c7d0be7a80a862cc88a2`。
- **累计 10 个**：**10,615,840,970 远端字节**，不是本地 IPA 内层大小之和。

首批 9 个删除后的**只读远端完整清单**有 **31 个 artifacts／1,837,708,271 字节**。
最后 1 个删除后，按该清单扣减推算为 **30 个／1,128,170,077 字节**；这是推算，
**不是删除后重新完整盘点**。其余测试／证据包未动，未获准删除。这些只是该仓库的
产物数字，**不是账号配额可用的证明**；账号套餐、全量存储与本月累计用量仍未知。

GitHub 官方计费说明：**删除产物不清除已经累计的月度存储用量**；用量每 **6–12 小时**
更新，但等待不保证配额或上传恢复，不能把删除的字节数直接当成新增可用配额。

**历史链接统一说明**：下方对应这 10 个产物的云端 IPA 链接已失效，仅保留历史身份／
下载证据；本地包仍保留。历史测试计数、通过结果和原下载记录不改写，不代表当前新版
交付。第二轮现已结束且再次被配额阻塞，没有继续删除其他产物。

**授权边界**：用户拒绝预先授权 private Release：“**等真的被阻止了，我们再来商讨对策**”。
除上述已获批的旧 IPA 清理外，**未授权 Release／权限／计费／存储变更或其他删除**。
实际阻塞现已确认，**停在此处，待与用户商讨，不额外重试**。后续可讨论 private Release
或由用户处理账号配额，但均未获实施批准；未创建 Release，未更改权限／计费／存储，
不自动换发布路线、扩大清理或承诺等待刷新即可恢复。

### 交付后再做的操作

**当前没有可安装的新包**。原生与 runner 包验证已通过；待用户另行确认交付路线，
新 IPA 实际完整下载并核验长度／SHA-256 后，再用 build 11 IPA，原 Sideloadly
账号／有效 Bundle ID 覆盖安装；已有 build 10 当前策略索引不卸载、不清库、不重建。
Settings → 中文搜索增强 → 简体中文 → 英文 → 下载离线语言包并同意，确认就绪后搜索
身份证，对比显示的英文与“使用原文”；可选下载后关闭全部网络验证该手机当次离线行为。
不强制整库索引／诊断。详见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。

## Historical: 0.3.4 (10) — SUCCESS first attempt; IPA downloaded and verified

以下及后续旧版记录保留当时事实，“当前／本次／现在”均指对应历史版本，不是 build 11
通过证据。build 10 的一次策略迁移不适用于已具有该策略有效索引的 build 11 升级。

源码 `3381fa6750f8efa76aa0895a72963c2d56a497f5` 已推送至个人仓库
`xwgnick/local-image-iq-ios`（`personal`）。
[Run 35991227461](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461)
／[job 107605532969](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461/job/107605532969)
已 **SUCCESS，首轮通过，无需修复重跑**；日志确认 `TEST SUCCEEDED` 和设备
`BUILD SUCCEEDED`。源码检查、Swift 核心、公开地点包生成／校验、模型导出、
原生／UI 测试及设备打包均通过；build 10 IPA 已实际完整下载并校验。
本次仅记录提供的已核验证据，不重新运行命令、测试、CI 查询或下载。

### 当前源码实现与未改变的边界

- 索引先以短边目标 224 请求 `.highQualityFormat`，网络关闭；只有无可用本地
  资源才退回同目标 `.fastFormat`，仍网络关闭。均为 `.aspectFit`、`.current`、
  `resizeMode = .fast`，不调用原图 API；请求目标不是实际返回像素保证。
- 任一请求返回可用像素即接受，包括降质图及仅一次回调；取消、权限／授权失败、
  无像素的普通错误不触发兜底。只有两次本地请求均无可用资源，且用户已显式允许
  联网，才允许第三次高质量联网请求。默认仍关闭联网，不要求下载原图。
- 输入策略 `photokit-hq224-fast-fallback-v1` 替换实际已发布的
  `photokit-preview-v1`。同一 SigLIP 2 图文配对、768 维／FP32、`modelVersion`、
  tokenizer、模型预处理、2,943 要素四国地点包、评分和默认地点权重 0.6 不变。
  本次设备报告已确认模型与地点包身份；新输入策略及 20 actor 由源码和测试验证，
  不声称设备报告含有或验证了输入策略字段。
- 下次 Index / resume 自动重编码旧策略行，无需手动 Clear index。旧策略向量在
  新行成功提交前被搜索与当前有效计数排除；覆盖可能暂时下降至 0，不能承诺迁移
  期间搜索或排名不变。已提交且仍有效的新策略行可复用／续跑；Fast 兜底行也缓存，
  不会在后续续跑时自动提升输入质量。
- 地点文本缓存同样以完整的 `IndexImagePolicy.cacheVersion` 为键；旧策略地点文本
  向量不能跨此次迁移复用。新策略内相同地点文本仍共享缓存，只需编码一次。
- **20 个实际独立图像模型 actor／槽位**：复用 1 个常驻主图像 actor，19 个额外
  仅图像 actor 在索引作用域内懒加载，全部子任务结束后释放作用域持有；中央只有
  **1 个文本模型＋1 个 tokenizer**。有效缓存命中不取图／图像推理，纯缓存扫描不
  懒加载额外 19 份模型。释放引用不等于系统立即回收全部内存。
- 固定 20 槽滚动窗口包括进行中和已完成待顺序提交的项目；慢队首可阻塞补位，
  每顺序提交一项才补一个，不是批次 20。父任务按快照顺序处理地点、写库、发布
  进度，先保存后计数；取消／错误退出取消并等待所有子任务结束，同步预测可能需
  等返回，迟到 PhotoKit 回调由 gate 忽略，不表示系统已确认取消。
- 用户明确批准 20 槽高内存实验，将在 **iPhone 15** 测试；额外模型和中间张量可能
  使 iOS 终止 App。没有静默限制或自动缩回 4，也没有硬件同时执行 20 路、相对
  四槽 **5 倍提速**或整库必定完成的证据／承诺。没有新增任意图库上限或超时。
- 三路预览诊断及正常图片显示不变，不宣称 UI 图像现在更清晰。

### 当前验证账本：build 10 实际执行结果

以下 App 子套件已计入 270 项总数，不重复相加；耗时不是手机性能测量。

| 项目 | build 10 已核验结果／边界 |
| --- | --- |
| CI／源码与资源检查 | 上述 run／job 首轮 SUCCESS；源码检查、公开地点包生成／校验、模型／App 资源检查及设备打包通过。 |
| Swift 核心 | 79 通过。 |
| App XCTest | 270 项：269 通过、1 项真机文件保护在模拟器跳过、0 失败；122.720 秒。 |
| `IndexingImageRequestTests` | 38 项全部通过；0.694 秒。此前实际为 26 项，不是 25 项；新增 12 项。 |
| `IndexPipelineTests` | 19 项全部通过；1.124 秒。20 槽顺序窗口、缓存、取消／续跑契约通过。 |
| `LocalPreviewComparisonTests` | 18 项全部通过；0.074 秒。三路诊断行为保持不变。 |
| `LocalPreviewComparisonPresentationTests` | 19 项全部通过；1.340 秒。假服务／生成像素，不是真实 PhotoKit。 |
| `GeneratedModelParityTests` | 8 项全部通过；94.326 秒，包含真实 20 图像 actor 的生产工厂测试。 |
| 真实生产工厂数值测试 | 6 夹具 × 20 槽＝120 次预测；240 项归一化向量比较＋12 项张量测量＝252 项，实际执行及计数／门槛断言通过。 |
| 原生产编码 API 数值门槛 | 原 23 次预测／58 项测量通过，原阈值不变。 |
| UI 测试 | 7 项全部通过；202.650 秒；TEST SUCCEEDED。 |
| 模型导出 | parityPassed:true，23 cases；本次导出极值见下文，不是原生 XCTest 极值。 |
| 设备构建／资源检查 | BUILD SUCCEEDED；实际报告确认 0.3.4 / 10 及下述模型／地点包身份。 |
| 新 IPA／下载校验 | COMPLETE：有界流式完整下载，实际本地长度／SHA-256 校验通过后才最终重命名；报告和校验文件齐全，无部分下载残留。 |
| iPhone 15 实测 | PENDING-DEVICE：安装、输入策略迁移、20 槽稳定性、搜索效果、耗时／内存／发热及文件保护均待验证。 |
| 模型／地点再分发 | PENDING-LICENSE-REVIEW，人工审查仍未完成。 |

真实工厂测试保留归一化 768 维输出、norm error ≤ 1e-5、图像余弦 ≥ 0.995 的
原门槛且已通过；12 项张量测量按 6 个夹具各测两项，不是每槽重复 12 项。
原 23／58 测试独立保留并通过，120／252 不替代它。

非致命日志备注：CI 出现测试临时库的 SQLite “vnode unlinked while in use” 警告，
路径位于测试临时目录；相关测试仍 PASS。静态审查提示夹具可能持有两个独立
`SQLitePhotoStore` 连接：`context.store` 已关闭，但 worker store 仍有独立生命周期。
这只是可能解释，未确认全部警告原因，也不是生产 drain 失败证据；本次不扩展修复范围。
刻意输入 3 字节无效数据的 ImageIO 错误属于已通过的负例测试，不作为失败处理。

| 模型导出指标 | build 10 报告值（非原生／真机极值） |
| --- | --- |
| 最小余弦 | 0.9999999999960657 |
| 最大原始分量误差 | 0.000011444091796875 |
| pairedCosineMaxAbs | 1.8557397291063538e-7 |

### 实际设备包与完整下载

- 设备报告确认 **0.3.4 / build 10、iphoneos18.5、arm64 Release、未签名、Xcode 16.4、
  最低 iOS 17.0**。这是真机 SDK 构建，不是已在物理 iPhone 安装或运行。
- 仍为同一 FP32／768 维 SigLIP 2 配对 `google/siglip2-base-patch16-224`，revision
  `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`；`modelVersion`：
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。
- 同一设备报告确认 Places **2,943 要素、15,175,079 GeoJSON 字节、CHN／FRA／DEU／NLD、
  8 个来源**。GeoJSON SHA-256：
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`；清单 SHA-256：
  `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`。
- [IPA 产物 10805190700](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461/artifacts/10805190700)：
  外层 **1,414,740,610 字节**；内层 IPA **1,414,733,291 字节**；IPA SHA-256：
  `0e1bc7ece93af94745e81e780d9ddf3fc78b9173c2e987a68710322be46bf7ff`。
- **完整下载已实际完成**：有界内存流式读取，实际长度／SHA-256 核验通过后才最终重命名为
  [../build/device-download/35991227461/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35991227461/LocalImageIQ-iphoneos-unsigned.ipa)。
  同目录的 [../build/device-download/35991227461/device-build.json](../build/device-download/35991227461/device-build.json)
  与 [../build/device-download/35991227461/SHA256SUMS.txt](../build/device-download/35991227461/SHA256SUMS.txt)
  均已存在；父进程已直接读取完成记录 JSON 并核对本地文件名，无部分下载残留，旧包保留。
  **现在即可用于 Sideloadly 本机签名，无需等待新包或重新下载。**

### 有限截图审核：仅 3 张索引／地点界面

[UI 产物 10804911624](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461/artifacts/10804911624)
为 **2,714,944 字节**，24 张截图已下载；仅审核 **3 张**的 **990×742** 联系图
[../build/ui-review/35991227461/hq20-index-contact.jpg](../build/ui-review/35991227461/hq20-index-contact.jpg)：
Library 回填后、Library 零 GPS、Settings 尚未检查地点，可见内容清楚。
折叠项未展开，内部计数未视觉审核；联网页脚及 20 worker 标签在屏外，**未视觉审核**；
其余 **21 张未审核**。合成场景不是私人图库 GPS／真实 PhotoKit 或硬件 20 路并发证据。

### 已有匿名真机观察：仅为改动动机

一个真实手机个例中，Fast 本地返回 **68×120**，高质量 224 本地返回 **224×398**，
高质量 480 不可用。仅记录匿名尺寸／可用性，不嵌入或上传私人照片、照片文件名或
截图；不是全图库统计，不证明任意照片都可获得更好像素，也不证明检索或正常显示
已经改善，更不是 build 10 的真机通过证据。

### 用户下一步：用已校验的新包，一次正常迁移

1. 使用上方已完整下载并校验的 build 10 IPA；不追加手机诊断或截图任务。
2. 用原 Sideloadly 账号、原有效 Bundle ID 覆盖安装；不卸载、不 Clear index。
3. Network OFF，Library → Index / resume 跑一次，保持前台。模型没换，但新输入
  策略需要重编码旧策略行；无需下载原图。
4. 完成后再试搜索。若被 iOS 终止，重新打开并点 Index / resume；已成功提交且
  仍有效的前缀保留，未提交工作重做。不保证 20 槽配置一定能完成。

操作见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)，机制见
[INDEX_PIPELINE_PLACES.md](INDEX_PIPELINE_PLACES.md)，数值边界见
[NATIVE_PARITY.md](NATIVE_PARITY.md)。

## Historical: 0.3.3 (9) — 首轮验证通过，IPA 已完整下载并校验

以下及更早版本保留原始结果和当时步骤；“本次／current”仅指各自历史版本。
旧版“不跑索引”、截图诊断或可选清库测速均不是 build 10 当前操作要求。

源码 `9e055b13be62ca184593387b1b5dc647b3a85a26` 的
[Run 35965638523](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523)
／[job 107523495276](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523/job/107523495276)
已 **SUCCESS，首轮通过**；日志确认 `TEST SUCCEEDED` 和设备 `BUILD SUCCEEDED`。
以下为本次 build 9 的已核验证据，不借用历史结果。

### 本次测试结果

| 项目 | 已核验结果／边界 |
| --- | --- |
| Swift 核心 | 79 通过。 |
| App XCTest | 258 项：257 通过、1 项真机文件保护在模拟器跳过、0 失败；96.471 秒。下列 App 子套件已计入总数，不重复相加。 |
| LocalPreviewComparisonTests | 18 项全部通过；0.060 秒。 |
| LocalPreviewComparisonPresentationTests | 19 项全部通过；1.248 秒。注入假服务／生成像素，不是真实 PhotoKit。 |
| GeneratedModelParityTests | 8 项全部通过；71.345 秒，包含生产工厂的真实四图像模型 actor。 |
| 四 actor 数值门槛 | 6 夹具 × 4 槽＝24 次预测；48 项归一化向量比较＋12 项张量测量＝60 项；计数及图像余弦 ≥ 0.995 均断言通过。 |
| 原生产编码 API 门槛 | 23 次预测／58 项测量通过，原门槛不变。 |
| UI 测试 | 7 项全部通过；198.491 秒。测试耗时不是手机速度测量。 |
| 模型导出报告 | parityPassed:true，23 cases；本次导出极值见下表，不是原生 XCTest 极值。 |
| 真机 | PENDING-DEVICE：本机签名／覆盖安装、真实 PhotoKit 离线结果、细节质量、文件保护、速度／内存／发热及私人图库 GPS 覆盖均待验证。 |
| 再分发许可 | PENDING-LICENSE-REVIEW：模型及地点数据仍需人工审查。 |

| 模型导出指标 | 本次报告值（非原生／真机极值） |
| --- | --- |
| 最小余弦 | 0.9999999999960657 |
| 最大原始分量误差 | 0.000011444091796875 |
| pairedCosineMaxAbs | 1.8557397291063538e-7 |

### 实际设备包与完整下载

- 设备报告确认 **0.3.3 / build 9、iphoneos18.5、arm64 Release、未签名、Xcode 16.4、
  最低 iOS 17.0**。这是真机 SDK 构建，不是已在物理 iPhone 安装或运行。
- 模型仍为同一 FP32 SigLIP 2 配对、**768 维**：`google/siglip2-base-patch16-224`，
  revision `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`；`modelVersion`：
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。
- 同一设备报告确认 Places **2,943 要素、15,175,079 GeoJSON 字节、CHN／FRA／DEU／NLD、
  8 个来源**。GeoJSON SHA-256：
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`；清单 SHA-256：
  `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`。
- [IPA 产物 10794875285](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523/artifacts/10794875285)：
  外层 **1,414,738,797 字节**；内层 IPA **1,414,731,479 字节**。
  IPA SHA-256：`5c36d87fa1b5845a6806274a200ad602a917b778da5398b49116b2e9b303328b`。
- **完整下载已实际完成**：有界内存流式读取，实际长度／SHA-256 核验通过后才最终重命名为
  [../build/device-download/35965638523/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35965638523/LocalImageIQ-iphoneos-unsigned.ipa)。
  同目录的 [../build/device-download/35965638523/device-build.json](../build/device-download/35965638523/device-build.json)
  与 [../build/device-download/35965638523/SHA256SUMS.txt](../build/device-download/35965638523/SHA256SUMS.txt)
  均已存在；父进程已直接读取完成记录 JSON 并核对本地文件，无残留部分下载。旧包保留，
  不需重新下载；本包仍须 Sideloadly 本机签名。

### 有限截图审核：只审核 4 张新增预览图

[UI 产物 10794342294](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523/artifacts/10794342294)
为 **2,711,196 字节**，24 张 UIReview 截图已下载；**仅审核其中 4 张新增预览图**，
其余 20 张未审核。前三张各 393×852，大字号图 375×667；在 **1340×758** 联系图
[../build/ui-review/35965638523/local-preview-contact.jpg](../build/ui-review/35965638523/local-preview-contact.jpg)
中审核的范围如下：

- 三路预览：三列尺寸／元数据及等大面板清楚可见。
- 全部不可用：不可用状态清楚可见。
- 同一区域细节：三路面板的共同区域可见。
- 大字号：当前视口仅见菜单和第一个大面板；屏外元数据／其余面板**未做视觉审核**。

像素均为程序生成的假数据；**未实际点击或滚动验证**，不证明真实 PhotoKit、离线覆盖、
清晰度或手机性能。UI 测试通过不等于这四个预览场景已完成真机交互验收。

### 安装后直接对比，不改索引

用原 Sideloadly 账号／原有效 Bundle ID **覆盖安装，不卸载、不清库、不重建，
不用点 Index / resume**。打开 App 前先开飞行模式并关闭 Wi-Fi，选已知白笔照片或
任一可访问结果 → 大图底部“本地预览对比” → 自动顺序完成 Fast 224／高质量 224／
高质量 480 → 发默认三路“等框对比”截图；可选“同一区域细节”。

对比仅在内存中，不调用索引 worker、编码器或 SQLite，不保存／导出图像、不改向量／排名。
模型、四 worker、Places、预处理／索引版本、正常显示及默认联网策略均不变。
三路禁止联网，但不检测飞行模式、不绕过系统缓存；打开 App、先前看图和前一次请求都
可能预热缓存。实际 CG 像素更大或原始降质标记为“否”不保证更清晰，也不是质量修复。
操作与请求契约见 [LOCAL_PREVIEW_COMPARISON.md](LOCAL_PREVIEW_COMPARISON.md)。

## Historical: 0.3.2 (8) — four workers passed first attempt; IPA downloaded and verified

The following results and speed-test instructions belong to build 8, not build 9.
Its IPA has no three-way comparison; the current diagnostic needs no index clear or rerun.

Source: `b40d2faaf11b2f499779881b4863325fa7dae659`.
[Run 35848409845](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845)
/ [job 107140049230](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/job/107140049230):
**SUCCESS on the first attempt**. App version **0.3.2 / build 8** is verified.
Core, export, places, model/App resource checks, native/UI tests and device
packaging passed; the local IPA download and actual length/hash verification are
complete. Physical-phone performance remains unmeasured. This edit records the
supplied verified results only; it runs no commands, tests, downloads, CI
queries/retries or phone actions.

### Implemented scope — the user's explicit four-worker request

- A fixed **four-slot rolling window** covers child cache reads, PhotoKit preview
  retrieval, preprocessing and image inference. Running and finished-but-not-yet-
  committed items **together occupy at most four slots**. A slow snapshot head can
  stall submission: an out-of-order completion does not admit a fifth outstanding
  item or grow an unbounded reorder queue. Each ordered commit frees one slot
  immediately; this is **not a four-item batch barrier**.
- Production slots have independent image `MLModel` actors. Slot 0 reuses the
  persistent primary image encoder; three additional image-only actors are scoped
  to this indexing call, load lazily on first use, and lose their scoped ownership
  after the children drain and the call exits. **One central text model and one
  tokenizer remain**, not four model pairs or four text models. Cache-only indexing
  does not load the three extra image models; valid image hits fetch no previews
  and perform no image inference.
- The parent alone handles locations, distinct-place text-cache reuse/deduplication,
  database writes and progress in snapshot order. Successful saves precede their
  published counters. Finished results retain embeddings/errors, not preview pixels.
  Cancellation/fatal scope exit cancels and awaits all up-to-four Swift children
  before the next serialized operation; an in-flight synchronous Core ML call may
  finish before draining. Late PhotoKit callbacks are gated out, not evidence of an
  OS cancellation acknowledgement.
- The extra **three image models plus concurrent preprocessing/inference state**
  are an explicit memory trade-off. Releasing scoped references is not a measured
  immediate OS-memory reduction. Four actors do not prove four simultaneous GPU/ANE
  executions, **4× speed**, or any physical-device speed/memory/heat outcome.
- No new job timeout, automatic retry, arbitrary row/byte ceiling or whole-library
  batch limit. Four is the requested concurrency window, not a library-size limit.
  Same SigLIP 2 paired weights/revision, FP32, semantic modelVersion, preprocessing,
  `photokit-preview-v1`, **2,943-feature** geography pack, scoring formula and default
  location weight **0.6**. Network remains off by default with explicit opt-in only;
  no originals-download requirement. This run's device report confirms the
  unchanged model and geography identity recorded below.

### Validation ledger — observed build 8 results

Four new pipeline tests bring that suite from 15 to **19**; one injected-default-
factory boundary test and one real-model four-encoder parity test bring the App
source total from 215 to **221**. The generated-model suite grows from 7 to **8**.
The actual model-enabled App result is **221 total / 220 passed / 1 physical-device
file-protection test skipped on simulator / 0 failures**. The suites below are
included in the App total, not additional tests to add again.

| Gate | Verified build 8 result / remaining boundary |
| --- | --- |
| Windows local Node checks | Reported PASS; not rerun by this edit and not native proof. |
| CI conclusion / job | SUCCESS first attempt: run 35848409845 / job 107140049230, linked above. |
| Source/static, places, model and App checks | All passed, including model export, geography generation/validation and bundled-resource checks; no historical test count is substituted for a new count. |
| Pure Swift core | 79 passed. |
| Model export report | Passed; model-report parityPassed:true. Raw exact extrema were not returned, so no historical minimum/maximum is relabelled as a build 8 measurement. |
| App XCTest summary | 221 total, 220 passed, 1 physical-protection skip on simulator, 0 failures. |
| IndexPipelineTests | All 19 passed, including the 4 additions; overlap, ordered-window, drain/resume and centralized place-cache contracts. |
| Default factory boundary | New injected-slot/pre-cancellation test passed; mocks alone do not prove production model independence. |
| GeneratedModelParityTests | All 8 passed in 101.581 seconds, including the new real four-image-actor factory gate. 6 fixtures × 4 slots = 24 predictions; 48 normalized comparisons + 12 tensor measurements = 60, with counts and image cosine ≥ 0.995 gates asserted and passed. |
| Existing production App encoder API gate | Passed with unchanged 23 predictions / 58 measurements and thresholds; retained alongside the new 24/60 gate. |
| UI tests | All 7 passed in 209.329 seconds. |
| Native screenshot review | 20 frames retrieved; only 3 index/place frames reviewed in the 960×680 contact sheet below. Collapsed disclosures were not expanded. |
| Simulator/device resources, arm64 Release and IPA validation | Passed; device report verifies 0.3.2 / build 8 and unchanged model/pack identity. Unsigned device package, not physical-device execution. |
| Artifact / bytes / SHA-256 | Artifact 10745235946; verified identity and exact byte/hash values below. |
| Complete local IPA download | COMPLETE: bounded-memory stream, actual local bytes/hash verified; checksum and device-build JSON exist, no partial download remains. |
| User-side signing/install; physical-phone speed, memory/heat, file protection and GPS coverage | PENDING-DEVICE — no phone run or additional diagnostics requested by this edit. |
| Model/geography redistribution | PENDING-LICENSE-REVIEW — unchanged separate release requirement. |

### Verified build 8 device package and completed download

- [Unsigned IPA artifact 10745235946](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/artifacts/10745235946):
  outer artifact **1,414,636,737 bytes**; inner IPA **1,414,629,419 bytes**.
- IPA SHA-256:
  `7d37581966a45028213a52a0a9c504e2ed273293a92bbbad4ab9d77a0d73ef8e`.
- **Download actually completed** using bounded-memory streaming. Actual local
  byte length and SHA-256 were verified at
  [build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa).
  The checksum file and device-build JSON exist alongside it; **no partial download
  remains**. This is the verified **0.3.2 / build 8** unsigned package, still
  requiring local Sideloadly signing.
- This run's device report confirms the unchanged modelVersion:
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
  Both towers retain `google/siglip2-base-patch16-224`, revision
  `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`, FP32 and the same preprocessing.
- The same device report confirms the unchanged **2,943-feature** places pack:
  **15,175,079 GeoJSON bytes, CHN/FRA/DEU/NLD, 8 sources**. GeoJSON SHA-256:
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`.
  Manifest SHA-256:
  `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`.
  These are confirmed build 8 device-package identities, not an inference from
  unchanged source or build 7 results.

### Bounded build 8 visual review — not a four-worker phone test

**20 native UI screenshots retrieved; only 3 index/place frames reviewed**:
Library after backfill, Library with zero GPS, and Settings with locations not
checked, in the **960×680**
[build/ui-review/35848409845/four-workers-ui-contact.jpg](../build/ui-review/35848409845/four-workers-ui-contact.jpg).
Disclosures stayed collapsed; their expanded internal counters were not visually
reviewed. The other 17 frames were not reviewed. Synthetic scenes do not establish
user GPS coverage, four-worker execution on a physical phone, speed or memory/heat.

### Update normally; optionally start from zero for the user's speed comparison

Use the verified **build 8** package above and overwrite using the same Sideloadly
account and effective Bundle ID; do not uninstall or clear index/cache for the update. Normal
**Library → Index / resume** reuses still-valid 0.3.0/0.3.1 SigLIP 2 image vectors,
checks/backfills places as needed, and encodes only new/changed images. Resume
after interruption through the same entry; keep the app foreground and network off.

The user wants a from-zero indexing speed comparison. **Optionally clear the index
only for that deliberately chosen cold test**: after installation, choose
**Settings → Clear index**, then **Library → Index / resume**, with network off
and the app foreground. This removes the App's existing index/cache, **not photos
in the system library**, and requires reindexing. Clearing is
not an update prerequisite or normal-resume requirement. Compare **0.3.1 vs 0.3.2
with the same geography pack**, both starting with an empty index, the same phone,
authorized photo set/count, network off and comparable temperature/heat and power
conditions. A warm cache-resume is not a cold-build comparison. No speed measurement
or physical memory test has been made, no phone action is performed here, and no
index-rescue or extra diagnostic/query round is required. Detailed contracts:
[INDEX_PIPELINE_PLACES.md](INDEX_PIPELINE_PLACES.md),
[NATIVE_PARITY.md](NATIVE_PARITY.md), [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md).

## Historical: 0.3.1 (7) — SUCCESS first attempt; IPA downloaded and verified

The following build 7 results, one-ahead implementation and installation handoff
are older evidence, not success or delivery evidence for build 8 or current build 9.

Source: `18ad52d37690ecfbf92b63a21285a6c3e8e753d4`.
[Run 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
/ [job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763).
**SUCCESS on the first attempt; no fix or retry was needed.** Logs contain
`TEST SUCCEEDED` and `BUILD SUCCEEDED`. The evidence below belongs to this run,
not build 6. This documentation-only edit records supplied verified results;
it does not run commands, tests, downloads or CI queries.

| Gate | Verified build 7 result / remaining boundary |
| --- | --- |
| Source/static contracts | 30 passed. |
| Pure Swift core | 79 passed. |
| Generate and validate public offline Places pack | Public-place build and test_places step passed, including generated-pack validation. The 25-test count is declared in code / prior local documentation, not asserted here as a separately observed CI log total. |
| Convert and check pinned model pair | Passed; model-report artifact 10741671604 records 23 cases and 92 comparisons, with this run's measurements below. |
| Native App tests | 215 total: 214 passed, 1 physical-device file-protection test explicitly skipped on simulator, 0 failures. All App suites listed below are included in this total, not additional tests. |
| GeneratedModelParityTests | All 7 passed in 67.736 seconds; no parity skip. |
| IndexPipelineTests / PlaceAvailabilityTests | All 15 / 17 passed, respectively. |
| BundledPlacesTests | Both tests passed: actual host-app pack hash/counts and public-city coverage, including New York outside coverage. Not a private-library GPS test. |
| IndexPlacesPresentationTests | All 3 passed; screenshot review is narrower than test execution, as recorded below. |
| UI tests | All 7 passed in 202.143 seconds; TEST SUCCEEDED. |
| Simulator / device App resources and IPA validation | Passed: compiled simulator and device App bundle checks, device packager and IPA contents validation. Actual device-report Places identity is recorded below. |
| iPhoneOS arm64 Release build and IPA upload | BUILD SUCCEEDED; unsigned 0.3.1 (7) package uploaded as artifact 10741731376. Not a physical-device execution test. |
| New IPA download / length / SHA-256 | Actually completed with bounded-memory streaming; local length/hash verified and the post-download local report written and checked. |
| Native visual review | 20 screenshots retrieved; only the 3 new index/place frames reviewed in a 960×680 contact sheet. Disclosures remained collapsed; their full internal counters were not visually reviewed. |
| Physical iPhone / private-library coverage / speed | PENDING-DEVICE after user installation. No measured phone speedup or real-GPS coverage percentage is promised; file protection remains untested on a physical device. |
| Distribution review | PENDING-LICENSE-REVIEW for model and geography redistribution; preserved source/license evidence is not legal approval. |

### Export evidence from this run

[Model-report artifact 10741671604](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741671604):
**23 cases, 92 comparisons**, with unchanged modelVersion.

| Metric | Build 7 measured value |
| --- | --- |
| Minimum embedding cosine across comparisons | 0.9999999999960657 |
| Maximum raw component difference | 0.000011444091796875 |
| Maximum paired text/image cosine matrix difference | 1.8557397291063538e-7 |

The export's native `not-run` markers precede XCTest; the later seven passing
GeneratedModelParityTests establish native execution, not those exporter markers.
These synthetic numerical checks do not measure real-photo retrieval quality.

### Verified device package, completed download and bounded visual review

- Device report: **0.3.1, app build 7; iphoneos18.5 SDK; arm64 Release;
  unsigned; Xcode 16.4; minimum iOS 17.0**. FP32 and semantic modelVersion are
  unchanged from 0.3.0.
- [Unsigned IPA artifact 10741731376](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741731376):
  outer artifact **1,414,628,123 bytes**; inner IPA **1,414,620,805 bytes**.
- IPA SHA-256:
  `98fb537004a64adaa84b1ba15d798acaf71a0684555275faddc647d1adafd8d6`.
- **Download actually completed**, with bounded-memory streaming and verified
  local length/SHA-256, at
  [build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa).
  The local report was written and checked after download. This is the build 7
  package, not the old build 6 IPA; it still needs local Sideloadly signing.
- Actual **device-package** bundledPlaces checks confirm **2,943 features,
  15,175,079 GeoJSON bytes, CHN/FRA/DEU/NLD, 8 sources**. GeoJSON SHA-256:
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`.
  Manifest SHA-256:
  `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`.
  These are verified device-package results, not just local source metadata.
- **20 native UI screenshots retrieved; only 3 new index/place frames reviewed**:
  Library after backfill, Library with zero GPS, and Settings with locations not
  checked, in the **960×680**
  [build/ui-review/35840838147/index-places-contact.jpg](../build/ui-review/35840838147/index-places-contact.jpg).
  Visible content is readable. Disclosures are collapsed, so this is **not** a
  visual check of every expanded internal counter. Counts are synthetic fixtures,
  not user GPS observations; the other 17 screenshots were not reviewed this round.

### Implemented scope, not a physical-phone performance claim

- One structured child prefetches the next asset's cache row / PhotoKit preview
  while the parent handles the current asset. One model pair, serial encoder
  calls and one ordered commit path remain; this is not multiple inference workers.
  Writes and progress stay in snapshot order, with successful saves completed
  before their counters publish. Cancellation/error scope exit cancels and drains
  the Swift child. PhotoKit has no cancellation acknowledgement; the existing
  gate ignores late callbacks, without claiming the OS request has stopped.
- No new arbitrary library/batch ceilings, deadlines, retries, original-download
  requirement or networking policy. Preview-first, reduced previews accepted,
  iCloud default off / explicit opt-in remain unchanged. Overlap is not measured
  iPhone acceleration and may help little if inference dominates.
- Both encoders still use `google/siglip2-base-patch16-224` at revision
  `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`, FP32, the same preprocessing and
  `photokit-preview-v1`. Semantic modelVersion remains
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
  Compatible 0.3.0 image vectors are reused while locations/place vectors are
  backfilled; compatible persisted distinct-place vectors are reused as well.
- China, France, Germany and Netherlands ADM1/ADM2 public boundaries are now
  required app resources in the normal CI path, including model-free builds.
  The generated [manifest](../Resources/Places/places-manifest.json) and actual
  device-package checks agree on the pack identity recorded above. Simulator,
  device App and IPA resource gates passed; this edit does not rerun those checks.
- Represented years are China ADM1 2019 / ADM2 2017, France 2022, Germany 2021,
  Netherlands 2022. Historical administrative approximations are not current
  addresses, POIs or global coverage. Labels use photo metadata, not current-device
  location or online reverse geocoding; raw coordinates are neither stored nor uploaded.
- Library separates current/last-scan GPS observations from saved labels:
  resolved, no GPS, GPS with no usable pack, GPS outside coverage, and unavailable.
  Not checked means unknown; label count is not GPS count or a permanent census.
  The existing centered-place score and default weight **0.6** are unchanged;
  supplying real place labels activates that branch, so ranking changes are intentional.

Implementation, provenance and test contracts: [INDEX_PIPELINE_PLACES.md](INDEX_PIPELINE_PLACES.md).

### Historical build 7 handoff: install the verified package; backfill places once

Overwrite with the same Sideloadly account/effective Bundle ID; **do not uninstall,
clear the index or re-encode the whole existing 0.3.0 image library**. Open
**Library → Index / resume** for one location-backfill pass, keep the app open and
network off, and resume there if interrupted. Valid image-cache hits need no pixels
or image inference; new/changed photos follow normal encoding. Do not download all
originals or change the location weight to disguise expected ranking changes.
An index still using 0.2.x CLIP requires the separate historical model migration;
build 7 does not make old CLIP vectors compatible. Normal use afterwards is enough,
without a new user diagnostic/query round.

### Remaining boundaries

CI, native parity/UI execution, simulator/device resource checks, IPA packaging
and the verified download are complete. User-side signing, overwrite installation
and the one-pass location backfill have not yet been confirmed for build 7.
Physical-iPhone behavior, file protection, latency/memory/heat and private-library
GPS/coverage remain unverified; cloud tests and synthetic screenshots do not fill
those gaps. No additional diagnostic/query round is requested. Expanded disclosure
contents are outside this visual review's scope. Public release still requires
model/geography license review, an App icon, a production Bundle ID, signing and
TestFlight/distribution configuration; no store submission has occurred.

## Historical: SigLIP 2 · 0.3.0 (6) — SUCCESS; IPA downloaded and verified

Everything in this build 6 section, including its migration instructions, metrics,
package and screenshot review, belongs to the older release, not build 7 or build 8.

Source: `f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78`.
[Run 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
/ job `107062896845`: **SUCCESS**, the corrected run. The logs report
`TEST SUCCEEDED` and `BUILD SUCCEEDED`. The prior documentation update recorded
that completed run and verified download, not a physical-device result.

Initial [run 35823153931](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35823153931)
at `aee4cdc00be92e1699f68baa9ef7ccc72cbcfbda` **failed**. It passed all 30 static tests, 79 core tests, model conversion
and same-tensor native prediction, but failed native compatibility checks: Quartz
resizing did not match bilinear interpolation for the 68×120/112×199 inputs, and
Swift lowercasing omitted Unicode Final_Sigma context. All seven UI tests passed.
The fix replaces resizing with explicit Pillow-compatible 22-bit separable
bilinear filters and implements Unicode Final_Sigma. It does not change fixtures,
thresholds, PhotoKit policy or queries. Ten resampler and three Unicode regression
tests were added. The corrected run above now passes both low-resolution native
cases and the exact Gemma token checks, including Final_Sigma. Full same-tensor
controls and numerical gates were retained, not weakened to obtain a pass.

The user approved replacing BOTH encoders with `google/siglip2-base-patch16-224`,
same revision `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2` for image and text.
[IMPLEMENTATION_CONTRACT.md](IMPLEMENTATION_CONTRACT.md) is authoritative:
schema 2, 768-dimensional raw outputs, 64 text positions, only `input_ids` as
text input, both original tokenizer JSON resources, explicit lowercase and
EOS/right-padding policy. The App pins `swift-transformers` 1.3.4 / `Tokenizers`
for local JSON loading; the Foundation-only core is separate. Do not mix a
SigLIP image encoder with the retired CLIP text encoder or old index vectors.

### Completed validation — evidence from corrected run 35824403795

| Gate | Historical build 6 evidence / then-remaining boundary |
| --- | --- |
| Python static checks | 30 passed, reported for this change; not rerun by this documentation edit. Static checks are not model export or native parity. |
| Pure Swift core | 79 passed, zero failures in this run. |
| FP32 Python/Core ML export | Passed: 17 texts + 6 synthetic images = 23 cases, 92 stage comparisons and a 17×6 paired cosine matrix; measured values below. |
| Native generated parity | All 7 GeneratedModelParityTests passed in 72.985 seconds: exact Gemma IDs/masks including Final_Sigma, same-tensor runtime, native preprocessing and requested CPU / `.all` checks. No parity skip. |
| Production encoder API coverage | Passed with asserted counts: 23 predictions (17 text + 6 image previews), 58 measurements (12 tensor + 46 normalized embedding comparisons). These are executed results, distinct from the exporter's 92 comparisons; diagnostic tensor measurements are not bit-exact Pillow gates. |
| App tests | 178 total: 177 passed, 1 physical-device file-protection test explicitly skipped on simulator, 0 failures. The 7 generated parity tests are included, not additional App tests. |
| UI tests | All 7 passed on the iOS 18.5 simulator; `TEST SUCCEEDED`. |
| Device build | iPhoneOS arm64 Release `BUILD SUCCEEDED`; unsigned FP32 package, not a physical-iPhone execution test. |
| New unsigned IPA | Artifact 10734323054 downloaded completely with bounded-memory streaming; local length and SHA-256 verified. Identity and link below. |
| iPhone behavior / performance | `PENDING-DEVICE`: not established by static, CPU or simulator results; no additional user diagnostic/query round is requested. |
| Distribution review | `PENDING-LICENSE-REVIEW`: shared model card declares Apache-2.0; copying license evidence is not legal certification. |

Measured FP32 export report (not physical-device measurements):

| Metric | Corrected-run value |
| --- | --- |
| Minimum embedding cosine across 92 comparisons | 0.9999999999960657 |
| Maximum raw component difference | 0.000011444091796875 |
| Maximum paired text/image cosine matrix difference | 1.8557397291063538e-7 |

Model version:
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
The export JSON's native `not-run` statuses were produced **before XCTest**;
they are provenance, not failures or a claim that the subsequent native tests
did not run. The later passing XCTest results establish native parity. Exact
token IDs/masks, full same-input tensor controls and all numerical thresholds
remain unchanged; synthetic parity is not real-library quality evidence.

### Verified IPA and bounded visual review

- Toolchain: **Xcode 16.4 / Swift 6**, with App Swift 5 language mode;
  **iphoneos18.5 SDK / arm64 / minimum iOS 17.0 / FP32**.
- [Unsigned IPA artifact 10734323054](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795/artifacts/10734323054):
  outer artifact **1,408,905,095 bytes**; inner IPA **1,408,903,848 bytes**.
- IPA SHA-256:
  `529b8ae5f708f57d14929fccf4a374dfb943d0e950b7671239e99f69b5acd98e`.
- **Download actually completed**, with bounded-memory streaming and verified
  local length/SHA-256:
  [build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa).
  This was the verified build 6 package, not a pending download or the build 7 IPA.
  It remains unsigned and requires local Sideloadly signing before installation.
- **17 native UI screenshots retrieved; only 4 reviewed**: Home, Library,
  Settings and hero-results layout, in the downscaled
  [build/ui-review/35824403795/siglip2-ui-contact.jpg](../build/ui-review/35824403795/siglip2-ui-contact.jpg).
  Synthetic/test scenes only, no private photos. Retrieval of the other 13 is
  not visual review; neither these screenshots nor simulator `.all` tests
  establish physical-phone performance or actual Neural Engine execution.

### Historical installation and required migration from CLIP to build 6

1. Overwrite using the same Sideloadly account and effective Bundle ID. **Do not
   uninstall or manually clear the index.**
2. **Now open Library → Index / resume once** to generate the new vectors; this
   is required because the model changed. Before new vectors exist, usable
   coverage from old-model rows is expected to be **0**, not a reason to clear
   storage. Keep network access off. Original-photo downloads / “Download and Keep Originals”
   are not prerequisites. If interrupted, resume there; completed, still-valid
   new-version rows are reused.
3. Use search and photos normally. No further test queries, screenshots or
   single-photo diagnostics are required for this handoff.

Legacy 512D CLIP rows can be decoded ONLY to support migration; they are not
searchable with a SigLIP 2 768D query. The semantic modelVersion changes while
`photokit-preview-v1` stays unchanged. Image and any place-text vectors must be
regenerated under the new modelVersion, never padded or mixed across models.
Photo rows use `id` as their primary key and are replaced as reindexing succeeds.
The old IPA is retained, but it is NOT an index backup: rolling back the binary
does not promise restoration of overwritten old-model rows.

### Unchanged boundaries

- PhotoKit remains preview-first with local reduced previews accepted, network
  default off and online fallback only after explicit user opt-in. This change
  does not fix preview quality, force original downloads or guarantee offline
  access to every cloud asset. Scoring/settings/privacy policies are unchanged.
- The small desktop comparison showed trade-offs by query, language and input
  resolution, not an across-the-board winner. Desktop CPU timings are not
  iPhone latency, memory, heat or energy measurements.
- The exporter copies actual shared model-card/LICENSE/NOTICE evidence where
  present, preserves manual review and `redistributionApproved:false`; neither
  Apache-2.0 metadata nor numerical parity is certification for distribution.
- Free Apple development profiles still normally expire after seven days;
  Sideloadly is local third-party signing, not TestFlight or permanent installation.
  No Apple credentials go to chat/CI, and photos, GPS and local vectors are not
  uploaded. No new user diagnostics are part of this model replacement.

## Historical records — old versions, not SigLIP 2 proof

Everything below records the earlier builds and their then-current instructions.
In particular, old “do not rebuild” guidance applied to UI/diagnostic-only updates;
it did not waive build 6's CLIP-to-SigLIP new-vector indexing step above. That
migration is not a requirement to re-encode valid 0.3.0 image vectors for build 7.
Old success counts,
parity measurements, license findings, package sizes and checksums do not describe
the current build. Preserve them as history, not as pending-result substitutes.

## Historical: read-only single-photo check · 0.2.1 (5)

User confirmed the target is absent from Top 12 for `Dog eat my apple pen`, but
appears first for `a hand holding a broken white pen`. It is therefore indexed;
the cause of the ranking difference is still unproven. The user approved a simple
check button and screenshot workflow, not a new retrieval model or index rebuild.

The full-screen viewer now offers **Check this photo**. The check page accepts the
missed query and compares full-gallery cached rank with the rank after replacing
only this photo's vector using the existing local preview/encoder path. Request
dimensions, actual CGImage dimensions, raw degraded flag and vector cosine appear
on the screenshot card. Historical cached dimensions remain unknown.

Dedicated SQLite read-only handle; no cache reconciliation, schema writes, vector
updates, original-data requests or network fallback in this operation. The existing
AppState task chain serializes it with other work and rejects late cancelled
results. Current photo selection, query and gallery survive the check.

New tests: 18 worker/storage plus 20 state/render tests (five native screenshots).
Synthetic inputs and temporary databases only. No private photos, database or GPS
uploaded. See [PHOTO_CHECK.md](PHOTO_CHECK.md) for the test contract and phone steps.

[Run 35817552815](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35817552815)
at `36b4a7fa43fd5dd8d47cda8332fbaef4be0630ec`: **SUCCESS**, first attempt.

- Core: 79 passed. App: 152 total, 151 passed, one physical-protection skip.
  All 18 PhotoDiagnosticTests and 20 PhotoCheckPresentationTests passed, including
  actual temporary SQLite byte/hash invariance and cancellation/serialization.
- All seven existing UI navigation/keyboard tests passed. These tests do not
  exercise the new check button on a real photo; that remains a device test.
- Five new native screenshots reviewed in one 960×1360 contact sheet. Idle,
  result, unavailable-preview and large-type layouts are readable/scrollable;
  the viewer button is visible and correctly disabled for a nonexistent test ID.
  The example ranks/pixels are explicitly synthetic, not private-library findings.
- iPhoneOS arm64 Release build passed with unchanged model version and cache policy.
- [Unsigned IPA artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35817552815/artifacts/10732805206):
  **709,826,214 bytes**, SHA-256
  `a96c377ae0562022215daeffe75be778ba620137f32d2c4f43e573964b8f6465`.
- Downloaded with bounded-memory streaming and verified size/SHA-256 locally at
  `build/device-download/35817552815/LocalImageIQ-iphoneos-unsigned.ipa`.
  Review contact: `build/ui-review/35817552815/photo-check-contact.jpg`.

Overwrite with the same Sideloadly identity/effective Bundle ID. Do not uninstall,
clear or rebuild the index. Phone steps are in [PHOTO_CHECK.md](PHOTO_CHECK.md).

## Historical: photo-first UI redesign · 0.2.0 (4)

The user deferred model/retrieval changes and requested a complete UI redesign.
Home is search-first, technical controls move into Library/Settings sheets, and
results gain larger-photo/compact grids plus an ordered full-screen photo viewer.
Models, scoring, networking defaults and `photokit-preview-v1` cache identity are
unchanged. See [UI_REDESIGN.md](UI_REDESIGN.md) for exact layout and test boundaries.

Initial [run 35706493782](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35706493782)
compiled the redesigned app and passed all 79 core / 113 App tests (one physical
protection skip), including all 16 presentation tests. One navigation test failed:
the native Home screenshot exposed an unsolicited Photos permission dialog.
Photos observation now starts only after access is granted, not in client init.

[Run 35707292730](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35707292730)
verified that fix: all three presentation/navigation tests passed. The 12 native
review screenshots were inspected as a downscaled contact sheet; Home no longer
has the permission popup, Library offers Choose photos, and the photo grids and
normal/large-text Settings render correctly. One keyboard test received
`d eat my apple pen` rather than the injected full query. The previous assertion
ran only after submission, so it could not distinguish input loss from submission
mutation. Tests now assert each typed prefix before dismissal, with no retries or
query repair, and retain all exact post-dismissal assertions.

Final [run 35708194014](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35708194014)
at `b02357e128bc82313be48395dc5c3e9778c274eb`: **SUCCESS**.

- Core: 79 passed. App: 114 total, 113 passed, one physical-protection skip;
  all 16 presentation tests and seven real-model parity tests passed.
- UI: all seven passed (three navigation and four keyboard tests). Keyboard tests
  verified every injected prefix and exact text after Search/Done; no production
  query workaround or test skipping was introduced.
- Final 12 native screenshots were retrieved and reviewed as a 900×2720 contact
  sheet. The clean Home, reachable Library, normal/large-text Settings, three grid
  layouts and unavailable-photo state agree with the earlier visual review.
  Screenshots use empty UI or labelled synthetic test scenes, not private photos.
- Device Release: `BUILD SUCCEEDED`, iPhoneOS 18.5 SDK, arm64, unsigned, both real
  encoders included. The model version remains unchanged.
- [Device artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35708194014/artifacts/10684943653):
  IPA **709,723,454 bytes**, SHA-256
  `4517a52c2732c6b29873724b05d4c1f3a1c8a4bde7612c97cf58a4389c2c03e6`.
- Download completed with bounded-memory streaming and size/SHA-256 verification
  into ignored `build/device-download/35708194014/LocalImageIQ-iphoneos-unsigned.ipa`.
  Final local screenshots: `build/ui-review/35708194014/contact.jpg`.

Use the same Sideloadly account / effective bundle identifier to overwrite the
previous installation. Do not uninstall or clear/rebuild the index for this UI
update. Actual iPhone 15 / iOS 26.6.1 interaction and private-library results still
need device confirmation; full-screen photo gestures/sharing were implemented
and compiled, not claimed as real-photo end-to-end validation by these screenshots.

## Historical: search keyboard dismissal · 0.1.2 (3)

The user screenshot showed returned matches covered by the keyboard. The previous
search field had no FocusState management: calling search did not resign focus,
and there was no explicit dismissal control.

- The query field now has explicit focus and single-line submit semantics.
- Both keyboard Search and the page search button share the same action, which
  clears focus before requesting search, including unavailable/empty submissions.
- Keyboard toolbar Done and a focused-only navigation Done button dismiss without
  searching or clearing the query. Dragging the scroll view dismisses interactively.
- Opening a result clears focus. No networking, index, model or ranking changes;
  the `photokit-preview-v1` cache remains reusable after this update.

Four new XCUITest cases drive the actual simulator app: Search return, keyboard
Done/re-focus, navigation Done and drag dismissal. They do not grant Photos access
or fabricate a search index; the shared submit focus path is tested even when the
search state is not ready. Actual result rendering with a personal library remains
a separate device test. No local-network debug channel was added.

Validation [run 35694536774](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35694536774)
at `58f6783eba4a5fd4412b16635c34585c32ff9ed2`: **SUCCESS**.

- Core 79 passed; App 98 total, 97 passed and one physical-device protection skip.
- **All four SearchKeyboardTests passed** on the simulator (59.28 seconds), with
  actual software-keyboard interaction. No fake results or private images supplied.
- Device Release build succeeded with both models included.
- [Unsigned device artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35694536774/artifacts/10678914749):
  IPA 709,552,244 bytes; SHA-256
  `bce9d08d5a6f7cbcb341af7351bb84c03efbc3c381838c71a75f42c21c796c4f`.
- Downloaded and streaming-hash verified locally under
  `build/device-download/35694536774/LocalImageIQ-iphoneos-unsigned.ipa`.

Update over 0.1.1 using the same Sideloadly account / effective bundle identifier.
Do not uninstall or clear the existing index for this UI-only fix. Actual iOS
26.6.1 device keyboard behavior remains to be confirmed after installation.

## Historical: preview-first fix for optimized iCloud libraries · 0.1.1 (2)

The user confirmed the first device app opens and searches, but a real optimized
iCloud library indexed only 114 of 7,994 checked images. Full permission was present;
last error was PhotoKit 3164. This exposed an original-data request and misleading
error categorization, not a 114-image product limit.

The approved fix switches indexing to local-first PhotoKit preview requests,
accepts degraded single-callback images, encodes CGImage pixels directly, and only
falls back to a network-allowed preview request with explicit user permission.
Networking remains off by default. No full-original download prerequisite, no
UI layout redesign, and no photo upload. See [policy and device checklist](PREVIEW_INDEXING.md).

The active cache identity appends `photokit-preview-v1` to the unchanged paired
model version, so the first scan after updating rebuilds the image index using
the new input path. Reduced previews may change rankings; there is no claim that
all 7,994 assets are now locally accessible before a new device test.

New coverage includes 26 callback/policy tests, 20 worker/persistence/source-counter
tests, three direct-preview tensor tests and a real-model preview API parity test.
An actual compiler error in the new async Core ML call was fixed by retaining the
existing synchronous actor-isolated prediction path. A stale source-label assertion
was aligned with the accurate online-fallback wording; no numerical gate was weakened.

Final device validation: [run 35683805304](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35683805304),
source `71c56c66bf75bbaeeafe414af8d2cc4076b97d8c`: **SUCCESS**.

- Core: 79 tests passed, zero failures.
- App: 98 tests total, **97 passed, one physical-device protection test skipped**,
  zero failures. All seven real-model parity tests, 26 preview request tests and
  20 worker tests passed. Tests do not substitute for an optimized-iCloud device test.
- Device Release build: `BUILD SUCCEEDED`; same iPhoneOS/arm64 validation as before.
- [Replacement IPA artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35683805304/artifacts/10675548340),
  IPA 709,546,542 bytes, SHA-256
  `3481dbd842169caa96c6da8a1ba1f33517b09ec9232c81521a447e1e1a544ff5`.
- Downloaded with bounded-memory streaming into ignored
  `build/device-download/35683805304/LocalImageIQ-iphoneos-unsigned.ipa`; size and
  SHA-256 verified before publishing the final local filename. Old package retained.

Install this unsigned IPA with the same Sideloadly account/application identifier
over the old version. Keep network disabled for the first new scan and compare the
source/coverage counters. No promise of full-library offline coverage is made.

## Historical: first unsigned physical-iPhone IPA built

The user has Windows only, an **iPhone 15 / iOS 26.6.1**, no paid Apple membership,
and explicitly accepted Sideloadly for local signing. No third-party installer,
Apple driver, Apple login or signing certificate was installed/configured by CI.

[Run 35636586662](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35636586662)
at source `4dd504e33ced08a5444f4e67fab5bd3a74149577`: **SUCCESS**.
Model conversion and simulator tests passed again before the device build
(79 core tests; App 48 total, 47 passed, one physical-protection test skipped).

The subsequent Release build uses **iphoneos18.5 SDK / Xcode 16.4 / arm64**,
minimum iOS **17.0**. Both compiled encoders and vocabulary are bundled. The
packager verifies `CFBundleSupportedPlatforms=iPhoneOS`, `DTPlatformName=iphoneos`,
Mach-O platform IOS, arm64 architecture and a real Payload/App layout. This is
not a renamed simulator binary. Code signing is disabled; no mobile provisioning
profile or test bundle is included.

[Unsigned iPhone artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35636586662/artifacts/10656339002)
contains `LocalImageIQ-iphoneos-unsigned.ipa`, `device-build.json` and checksum file.

- IPA bytes: **709,536,954** (~710 MB).
- SHA-256: `f4027e85899914735d0d4f17fbbb727e0f4ca06c6406c7d0be7a80a862cc88a2`.
- Bundle ID: `com.example.localimageiq` (development placeholder; re-signing may
  assign a personal-account-specific identifier).
- **Unsigned / not directly installable / not yet tested on a physical iPhone.**

Follow [Windows iPhone installation](WINDOWS_IPHONE_INSTALL.md): the user signs
locally, pairs/trusts the device and enables Developer Mode as required. Passwords,
2FA codes and phone passcodes stay in the tool / Apple flow / phone, never in chat
or GitHub. Free development profiles normally expire after seven days.

## Historical: CLIP model-enabled validation passed

[Run 35634483200](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35634483200)
at source `b7983083e86b231a4d27ea8a548ce3382c2cf27b`: **SUCCESS**, with
`include_models=true` and `all_compute_units=true`. Only pinned public models and
synthetic inputs were used; no personal photos, GPS, database or videos uploaded.

- Both real encoders exported on Apple Silicon macOS using the pinned FP32 toolchain,
  compiled into the iOS App, loaded and exercised in the iOS 18.5 simulator.
- **79 core tests passed; 48 App tests total: 47 passed, 1 explicitly skipped,
  zero failures.** The skipped test needs physical-device file protection.
- All six generated/native parity tests ran. Cased WordPiece IDs/masks matched
  12 reference texts, including Chinese, accents, special tokens and truncation.
- Four generated image patterns cover RGB, non-square resizing, EXIF rotation
  and mirroring. Same-tensor inference and native preprocessing were checked
  separately; the latter passed its embedding-cosine acceptance criterion, not a
  claim that CGContext interpolation is pixel-identical to Pillow.
- CPU-only and `.all` inference tests passed on the simulator. This does not prove
  that a physical iPhone Neural Engine was used or establish real-device performance.

### Measured Python/Core ML conversion

16 image/text cases, four comparison stages per case:

| Metric | Measured |
| --- | --- |
| Minimum embedding cosine across conversion comparisons | 0.9999999999972214 |
| Maximum raw component difference | 0.00000858306884765625 |
| Maximum paired text/image cosine difference | 0.00000019307484327990565 |

Model version: `clip-pair-v1-8c7add0507b558a30b86c170c5d86767515f27e9f2944574eabee0dde8e4a09e`.
The Python parity JSON records native stages as `not-run` because it is emitted
before Xcode tests; the later XCTest result is the evidence for native parity.
These synthetic comparisons establish numerical compatibility, not search quality
on a user's real collection.

### Download and remaining boundary

[Private build artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35634483200/artifacts/10655548861):
715,390,511 bytes; embedded `LocalImageIQ-Simulator.zip`: 715,482,546 bytes.
Includes compiled encoders, simulator App, XCTest results and conversion reports.
The report was inspected using 96,764 bytes of ranged reads; the large artifact
was not loaded into this workspace/editor.

This is an **FP32 simulator build, not a signed iPhone IPA**. Model memory, speed,
heat, real PhotoKit permission flows and locked-device protection still need a
physical iPhone. Optional geography data is not bundled, so no offline location
coverage or reproduction of location-enhanced desktop demo rankings is claimed.
TestFlight / App Store submission has not happened. Text-model card declares
Apache-2.0; the pinned image-model card has no license declaration in its header.
Model redistribution review remains incomplete; do not treat the numerical report
as legal approval to distribute the package publicly.

Next: choose the authorized Apple signing / device-installation route, then validate
on device. No Apple credentials, certificates or billing settings have been requested
or changed by this workflow.

The user selected **no paid Apple membership; prefer a free route**. Apple's official
free-device-testing route uses an Apple Account / Personal Team signed in locally
to Xcode on a Mac connected to the device. Profiles expire after seven days and
need reprovisioning. The current simulator ZIP cannot be installed by renaming it
to IPA. GitHub's cloud build does not provide that physical-device connection or
replace personal signing. The user subsequently confirmed Windows-only access and
approved the third-party signing route documented above instead.
See [Apple account / Personal Team documentation](https://developer.apple.com/support/compare-memberships/).

## Historical: personal repository setup and initial validation

The user supplied `xwgnick/local-image-iq-ios` and confirmed the separate personal
account login. The API verified login `xwgnick`, private visibility and push access.
Only the isolated iOS source/configuration/documentation history was uploaded.
The original enterprise repository remains unchanged; local Git remote `personal`
selects the new repository explicitly, while `origin` still points to the old one.

GitHub's hosted Apple Silicon Mac now starts successfully. Verified milestones:

- 79 `ImageIQCore` tests compiled and passed on macOS.
- XcodeGen generated the app project; Xcode 16.4 compiled the native app and tests
  after importing PhotosUI for the limited-library picker.
- A test-only Swift type-inference timeout was fixed by splitting an expression;
  the ranking expectations and production scoring were not changed.
- XcodeGen's optional resource references still entered the copy phase when files
  did not exist. `project.yml` is now model-free; `project.models.yml` adds generated
  parity resources only after successful export in a model-enabled run.
- The App and XCTest bundle compiled and executed on the iOS 18.5 simulator.
  File-protection attributes are not exposed by that simulator filesystem:
  backup exclusion remains tested there, while the separate data-protection test
  explicitly skips on simulator and still asserts the original policy on iPhone.
  The production protection settings were not relaxed.
- The initial runs below used `include_models=false` and `all_compute_units=false`.
  The subsequent successful model-enabled run is documented above. No signing or
  TestFlight submission has been performed.

Earlier model-free validation: [run 35630122554](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35630122554),
source commit `d5cff5a90cdc15d4f67ba1328007b3a55daa9bdd`: **SUCCESS**.

- macOS package: **79 tests passed**, zero failures.
- iOS App XCTest: **48 total, 42 passed, 6 skipped, zero failures**.
  Five generated-model parity tests were skipped because this build intentionally
  has no models; one data-protection test requires a physical iPhone.
- Xcode reported `TEST SUCCEEDED`; simulator app packaging and artifact upload passed.
- [Build artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35630122554/artifacts/10653728057):
  `local-image-iq-model-free-5`, 6,178,124 bytes, containing Simulator App ZIP and
  XCTest results. Download requires access to the private repository.
- This is **not an iPhone-installable IPA**. No model inference, actual photo-library
  permission interaction, TestFlight distribution or physical-device performance
  has been validated by this model-free test run.

This earlier artifact is kept as the model-free baseline; use the newer artifact
above when a model-enabled simulator App is needed.

## Historical enterprise-account attempt

- Repository: `wengxie_microsoft/local-image-iq-ios`, API verified **private**.
- Source commit: `aeae0956e9baa536282e63b84a49f1bae7fbb543`.
- Uploaded: 47 source/configuration/documentation files only; no personal photos,
  video, databases, model weights or caches.
- [Run 35626471451](https://github.com/wengxie_microsoft/local-image-iq-ios/actions/runs/35626471451):
  dispatched once, `include_models=false`, `all_compute_units=false`.
- Result: failed **before any job step**; job `106421974495` has no executed steps.
- Annotation: **“GitHub Actions hosted runners are disabled for this repository.”**
- Repository Actions API: `enabled=true`, `allowed_actions=all`. Merely enabling
  workflows is therefore not the missing step. No configuration was changed.

GitHub documents that repositories owned by enterprise-managed user accounts
cannot use GitHub-hosted runners; organization-owned repositories can, subject to
enterprise policy. This matches the personal-namespace repository and observed
runner rejection. See [official restrictions](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-iam/understanding-iam-for-enterprises/abilities-and-restrictions-of-managed-user-accounts#github-actions).

## Original enterprise-account restriction

An enterprise-managed personal repository needs an organization-owned repository
with runner access or an approved self-hosted Mac. An ordinary personal account's
private repository is a separate option when use of that account is permitted.
Do not change visibility, billing or organization policy to bypass a restriction.
The personal repository used above was provided by the user, not created or
transferred by the assistant.

Core ML conversion and native numerical parity remain separate from the model-free
workflow. Physical-device performance, actual photo access and signing still need
validation after the simulator milestone.