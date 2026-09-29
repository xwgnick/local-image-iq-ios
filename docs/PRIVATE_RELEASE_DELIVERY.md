# Release 交付（含私有阶段历史）

## 当前（2026-09-29）：0.5.0（build 13）— SUCCESS／DELIVERED

[CI 36540269511](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36540269511)
／[job 109313762175](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36540269511/job/109313762175)，
源码 **`158c3bf661efcc688ecbe313a4f5c52a3271d803`**，**COMPLETED / SUCCESS**。
核心 **79 通过**；App **377＝376 通过／1 项既有真机文件保护模拟器跳过／0 失败**，
**214.296 秒**（wall **264.142 秒**）；UI **10 全通过／545.341 秒**。
设备 **BUILD SUCCEEDED：0.5.0 / 13、arm64 Release、未签名、SDK 18.5、Xcode 16.4、最低 iOS 17.0**。
子套件、20 actor 的 **120／252** 与原 **23／58** 门槛见 [BUILD_STATUS.md](BUILD_STATUS.md)。

- [公开 Release：ci-36540269511-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36540269511-1)，
  ID **398951411**，发布于 **2026-09-29T08:30:53Z**；**prerelease、`draft: false`、非 Latest、9 项资产已核验**，无需 GitHub 登录。
- [../build/device-download/36540269511/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36540269511/LocalImageIQ-iphoneos-unsigned.ipa)：
  asset **597693809**，**1,414,830,691 字节**，SHA-256：
  `d5ebe9881bc596f8c45b29cfdf5ed986b07e665e3a46fdf691dd09bb52a3db31`。
  **父流程实际完整流式下载并核验本地长度／SHA-256，`ipaVerifiedLocally: true`**，不是远端声明代替本地验证。
  配套 [../build/device-download/36540269511/device-build.json](../build/device-download/36540269511/device-build.json)、
  [../build/device-download/36540269511/SHA256SUMS.txt](../build/device-download/36540269511/SHA256SUMS.txt)、
  [../build/device-download/36540269511/delivery.json](../build/device-download/36540269511/delivery.json)、
  [../build/device-download/36540269511/release-fetch-7f2fdc96-50b8-4abb-9559-23083e023708.json](../build/device-download/36540269511/release-fetch-7f2fdc96-50b8-4abb-9559-23083e023708.json) 齐全。
- **7-Zip 26.03 `t` 全量解压／CRC PASS，Exit 0，Everything is Ok**：10 文件夹、24 文件，
  解压后 **1,559,424,855 字节**，压缩包 **1,414,830,691 字节**。**不验证 Sideloadly 重打包后的 IPA 或手机。**
- [../build/ui-review/36540269511/UIReview.zip](../build/ui-review/36540269511/UIReview.zip)
  已下载并校验：asset **597693697**，**3,719,566 字节**，SHA-256：
  `610189d2dabacda04fb910818f948e974d41b1973d9868d82dd4d2957bc70fe8`。
  父流程实际查看[八图青绿联系图](../build/ui-review/36540269511/teal-native-contact.jpg)（1120×1280）及
  [四图用户模式联系图](../build/ui-review/36540269511/user-mode-contact.jpg)（1340×758），共 **12 张原图，各 393×852**。
  场景为首页／就绪首页／合成网格／未授权图库浅深色，以及深色设置底部 OFF、深色未授权图库、空查看器 OFF／ON；
  **无真实 Photos／真机验证，不声称审核了其他图像**。

首轮 B **36537575789／a2e23979、UI 9/10** 保留为失败历史。第二轮仅补 `ContentView` 整行
`contentShape(Rectangle())` 与两个 sheet 导航 tint，未改测试、时间或坐标；全通过支持修复，
不构成旧 AX／根因的直接证明。普通文案／照片错误中文、根界面实际自适应、导航“完成”青绿；
系统键盘／分享遵循 OS 语言，调试原始值可能英文，不声称完全本地化。

默认 **Top 3／地点权重 0.6**、统一双列 4:5／紧凑三列间距 6／4、结果顺序保留且视觉排名移除；
20 worker、HQ224／Fast、翻译、索引／缓存不变。原 Sideloadly 账号／有效 Bundle ID **覆盖安装**，
build 10+ 有效索引与就绪语言包沿用，**不卸载、不 Clear index、不重建、不必 Index / resume**。
build 12 安装已由用户确认、此前短暂错误原因未知；**build 13 真机安装／行为仍未验证**。

公开手动标准 `macos-15`、现有权限／发布核验协议不变；本次不改源码、项目许可证、公开范围或计费，
第三方 `redistributionApproved: false`／人工审查仍未完成。未跟踪的研究／原型含公共 Unsplash 图，
**仅本地私存、未暂存，不宣称仓库全部干净**。现行公开边界见 [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md)。

## 历史：0.4.1（build 12）公开 Release 已发布，本地 IPA 已全量校验

以下“当前／本轮／工程仍是／尚未安装”等仅为 build 12 当时记录；用户后来已确认该版安装成功。
当前 build 13 交付、安装入口及验证边界以页首为准，旧包与失败证据不替代新包。

2026-09-28，用户明确选择公开仓库＋免费标准托管 runner，并再次确认既有历史中的
作者邮箱／机器路径／测试查询、历史 Actions 日志与已发布 Releases 可以公开。
同一 [xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios) 已由
GitHub API 与匿名 GET 确认为 **PUBLIC／`private: false`**。
现行公开范围、安全、费用和无项目级许可证说明见 [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md)。

- 当前 [0.4.1 / build 12 Release：ci-36515068434-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36515068434-1)
  （ID **398799791**）于 **2026-09-29T03:27:14Z** 发布，**prerelease、`draft: false`、
  非 Latest，9 项资产已核验，无需 GitHub 登录**。这是 build 12 首次完成交付，
  不是首次构建尝试。旧 build 11 Release 398009938 与旧失败 drafts 保留为历史。
- 仅手动 `workflow_dispatch`，精确仓库名且 `private == false`，只用标准 `macos-15`；
  无付费 larger／self-hosted runner、自动 push／PR 或 fork 特权触发。
  全局 `contents: read`、job `contents: write`／`actions: read` 保留，使用 `GITHUB_TOKEN`
  而非 PAT，不接收 Apple 凭据。所有源码／模型／原生／UI／设备包门槛保留。
- 发布器 preflight 和 prepublish 都要求精确目标且明确公开，拒绝私有或错误仓库。
  唯一 draft、固定白名单、身份／字节／SHA-256 核验后才发布非 Latest prerelease 的
  协议不变；失败保留 draft，无覆盖／删除。发布消息标识 **public CI**，不是第三方许可批准。
- 公开仓库标准 hosted runner 用量按 GitHub 规则免费，仍受政策、运行限制及可用性约束；
  **不重置已用私有分钟或历史累计用量**。未改预算、卡片、计费或付费限额，也未改企业 `origin`。
- 工程仍是 **0.4.1 / 12**；引擎、模型、20 worker、HQ224／Fast、翻译及缓存不变。
- [CI 36515068434](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434)
  ／[job 109235419277](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434/job/109235419277)
  已 **COMPLETED / SUCCESS**，源码 **`fac5e2d39d37730ccf45e2f8e0231124247d4cf8`**。
  核心 **79 通过**；App **370 项：369 通过、1 项既有真机文件保护模拟器跳过、0 失败**，
  **258.961 秒**（wall **288.923 秒**）；UI **9 全通过／522.447 秒**。
  GeneratedModelParity **8／170.094 秒**、DebugToolsPresentation **7／25.179 秒**、
  DebugToolsState **14／1.055 秒**已计入 App；PresentationNavigation **5／354.440 秒**、
  SearchKeyboard **4／168.007 秒**已计入 UI，不重复相加，不是手机性能测量。
- Advanced 标签 ID 作用域修正＋语义点击已通过原生验证：此前失败的
  `testClearQueryKeepsKeyboardAndSettingsAdvancedStartsCollapsed` 通过，两次展开均在滚动前
  验证唯一 `location-weight`、无 `debug-advanced` ID 的 Slider、可点击且 **60%**，
  收起／关闭调试／查询／Top 12 不变的断言保留且通过。旧视频证明已展开；父级 ID 传播
  是有力假设，旧 AX 空树不能直接证明继承。没有跳过测试、降低门槛或新增生产限制。
- 设备 **BUILD SUCCEEDED**：**0.4.1 / 12、arm64 Release、iphoneos18.5 SDK、Xcode 16.4、
  最低 iOS 17.0、未签名**。公开发布与本地全量校验已完成，**DELIVERED**，仍须用户本机
  签名，不是物理 iPhone 安装／测试通过。此前失败与本地 94 项发布器检查记录见
  [BUILD_STATUS.md](BUILD_STATUS.md)，不以旧测试或本地 mock 代替本轮原生结果。
- 不设置项目级许可证，不授予一般源码复用权；模型卡 Apache-2.0、geoBoundaries 元数据、
  Pillow MIT-CMU 源码头各自的权利不变，`redistributionApproved: false` 保留、人工审查未完成。

### 本轮下载身份与完成记录

- [../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa)：
  asset **597136564**，**1,414,818,257 字节**，SHA-256：
  `840085413cee964c7de03fa4453f89db9691ec74f8165064e3d07e432ccec03c`。
  **IPA 已实际完整流式下载，并由父流程直接核验本地长度／SHA-256**，不是只读取清单、
  远端 API digest 或报告中的声明。
- 本地同目录的 [../build/device-download/36515068434/device-build.json](../build/device-download/36515068434/device-build.json)、
  [../build/device-download/36515068434/SHA256SUMS.txt](../build/device-download/36515068434/SHA256SUMS.txt)、
  [../build/device-download/36515068434/delivery.json](../build/device-download/36515068434/delivery.json) 及
  [../build/device-download/36515068434/release-fetch-9caa6072-3f04-4462-87e7-637fe1965817.json](../build/device-download/36515068434/release-fetch-9caa6072-3f04-4462-87e7-637fe1965817.json)
  均已存在；下载记录 **`ipaVerifiedLocally: true`**。该记录是本地下载证据，不是 runner
  完成记录；本轮成功不能从历史 helper 的私有仓库检查说明推断，实际公开下载已完成。
- [../build/ui-review/36515068434/UIReview.zip](../build/ui-review/36515068434/UIReview.zip)
  已下载并校验：asset **597136471**，**3,339,409 字节**，SHA-256：
  `9fb0be72629cb43efba8716a22411ca24fdb7bfb291d89e98a9e6e19eb9e43f3`。
  父流程已实际查看[本轮用户模式联系图](../build/ui-review/36515068434/user-mode-contact.jpg)
  （**1340×758**，精确四场景、原图各 **393×852**）：Settings 底部 Show debug tools OFF、
  Maintenance／隐私仍可见；Library 连接 Photos／iCloud 可见、索引禁用、无 Details；
  空查看器 OFF 仅禁用分享，ON 时分享／Photo Check／本地预览对比均可见且禁用。
  合成空状态／未授权、不读取 Photos，**不是真机或私人图库证据，不声称其他图像已审核**。

现在可用已校验的新包，以**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装**。
已有 build 11／10 当前策略有效索引和就绪语言包沿用，**不卸载、不 Clear index、
不重建图像／地点、不必 Index / resume**，不要求诊断或指定查询。调试入口在
**Settings 最底部 → Show debug tools**，仅会话有效、重启默认 OFF；正常翻译保留。
**PENDING-DEVICE／PENDING-LICENSE-REVIEW**：本轮真机安装、交互／翻译、性能／文件保护与
第三方再分发审查仍未完成。操作见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)，
完整证据及旧失败历史见 [BUILD_STATUS.md](BUILD_STATUS.md)。

## 历史（2026-09-28，转公开前）：0.4.0（build 11）首次私有 Release 尝试成功，IPA 已下载校验

**以下全部保留为私有阶段历史**：当时的授权、登录要求、费用、83 项测试及本机 helper
说明不是现行公开 guard／下载要求。当前无需 GitHub 登录即可下载页首 build 13 新包；
本轮公开发布及全量下载已完成。以下“本轮／现在／当前”仅指历史 build 11，不能覆盖页首。

用户现已明确批准**方案 2：同一私有仓库 Release＋job 级 contents: write**。
源码 `844492b754f86d519c904da21cd80c1c814c056b` 相比原生／设备验证通过的
`0c09c46ff5edf74ffeb4a2cece2f7b9fd20a5910`，只改工作流和两个发布／测试脚本，
没有 App、索引或模型改动。发布器 **83 项本地 Node 22 mock 测试通过，CI 对应步骤也 PASS**；
本轮真实上传／发布与本地下载另有已核验证据，不以 mock 代替线上验证。
[CI 36387878343](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343)
／[job 108817040032](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343/job/108817040032)，
已 **COMPLETED / SUCCESS**，实际 `TEST SUCCEEDED`、设备 `BUILD SUCCEEDED` 和包验证通过。
这是**两次 Actions artifact 配额失败后的首次私有 Release 尝试成功**，不是整体首轮成功。

- [私有 Release：ci-36387878343-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)，
  ID **398009938**，发布于 **2026-09-28T06:55:36Z**；**prerelease、非 draft、非 Latest**。
  **9 项资产＝8 项载荷＋交付清单**全部上传并通过 API SHA-256 核验，仓库仍私有。
- [../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa)
  已实际全量下载并经父进程直接流式复验；asset **594739443**，**1,414,801,288 字节**，
  SHA-256：`6043afbe68a84edd16d1314ecf4369f308bff8d7cf676392aee5eee6a950ca71`。
  同目录设备报告、校验文件、交付清单及
  [下载记录](../build/device-download/36387878343/release-fetch-01b7433e-9d24-4c51-98ff-c2ccee92aa04.json)
  齐全，`ipaVerifiedLocally: true`，实际字节／哈希相符，无部分下载残留，所有旧本地包保留。
- 交付清单 asset **594740544**，**3,751 字节**，SHA-256：
  `4ac2e94ae8ae173d1dd4c42894cbd5ff5fed7e131e52f245b2923fcf76e17aa3`，已下载并独立校验。
  UI ZIP asset **594739319**，**3,116,697 字节**，SHA-256：
  `dddc29df265e55276ffa5dd66c4ae18de7ad53b9fbc2d51716382baa2a6f2942`，已下载校验。
  测试结果 ZIP asset **594739346**，**5,336,413 字节**，仅远端上传／API SHA-256 验证，未下载。
- 核心 **79 通过**；App **349 项：348 通过、1 项真机文件保护在模拟器跳过、0 失败**；
  32 桥接、42 状态、5 展示及 8 项 GeneratedModelParity 全部通过，独立 UI **7 通过**。
  真实 20 槽工厂 **120 次预测／252 项测量**和原 **23／58** 门槛未改且通过；子套件不重复相加。
  本轮耗时、设备／模型／Places 身份及历史见 [BUILD_STATUS.md](BUILD_STATUS.md)。

前两轮 Actions artifact 配额失败及已核验备份的 10 个旧 IPA 云端清理记录保留在
[BUILD_STATUS.md](BUILD_STATUS.md)：累计 **10,615,840,970 远端字节**，全部本地备份保留，
其余测试／证据未删。新交付不使用 Actions artifact 存储，**不声称 Actions 配额已恢复**；
不把第二轮 runner 的 **1,414,801,289 字节／fc449b…** 身份复制成新包结果。

## 历史私有阶段：授权、访问与费用

- 唯一目标是私有 `xwgnick/local-image-iq-ios`；工作流同时检查精确仓库名和私有属性，
  发布器再通过 API 验证仓库、commit 和 run／attempt 身份。
- 全局仍为 `contents: read`；只有构建 job 使用 `contents: write`、`actions: read`。
  CI 使用本次运行的 `GITHUB_TOKEN`，不新增 PAT，不保存 checkout 凭据，不接收 Apple
  密码、证书或签名材料。企业仓库不动。
- Release 继承该私有仓库的访问控制；“发布 prerelease”**不等于公开仓库、公开分发、
  App Store 或 TestFlight**，也不是 Apple 签名／证书服务。
  另一台电脑须登录 **xwgnick 或具有该私有仓库读取权限的账号**，从上述 Release 下载
  同一 IPA 并核验；工作区本地链接不会自动把文件传到另一台电脑。
- 未改变计费、套餐或付费存储设置。Release 资产不占 Actions artifact 存储配额，
  **macOS 构建分钟仍按原账号规则计量**，不声称免费或无限额度；模型／地点许可审查不变。

## 历史 build 11：构建与发布顺序

以下是本代已通过 **83 项本地 mock 测试、CI 发布器测试步骤及本轮真实成功交付**的固定
发布协议，不是待实施方案。测试／失败处理覆盖与实际成功路径分开记录，不声称每种故障都在线复现。

1. 保留全部源码、Swift 核心、公开地点包、模型导出、原生数值、App／UI 测试及设备包
   验证门槛。设备构建仍在交付前；不以 mock 测试替代原生测试。
2. 收集固定白名单文件；成功路径要求对应资产齐全，设备报告必须匹配当前工程版本、
   模型／地点报告和 IPA 实际长度／SHA-256。逐个文件必须 **小于 2 GiB**，这是
   **GitHub 的单资产限制**，不是新增任意图库、总包容量或任务时限。
3. 先创建唯一的 **DRAFT**，tag 为 `ci-<runID>-<attempt>`，绑定本次源码 SHA。
   有同名 tag／Release 即拒绝覆盖；不会删除或替换既有 Release、tag 或资产。
4. 每项流式上传，同时复核本地字节／SHA-256；上传后检查远端 ID、名称、状态、大小。
   GitHub API 有 SHA-256 digest 时核对 digest；没有时流式回读完整资产再核对。
   所有载荷验证后，生成、上传并独立校验交付清单。
5. 仅上游成功、清单／资产及身份均验证后，才将本次草稿发布为 **prerelease**，
   `make_latest: false`，不替换 Latest；并核验发布 tag 指向本次源码。

**失败不是交付**：上游失败只收集已有测试／公开报告证据，保持 DRAFT，**不上传 App
包（IPA 或模拟器 ZIP）**；没有证据时不建 Release。若上传中途失败，可能已有部分资产
甚至 IPA，但仍是未完成交付；发布器只尝试把自己创建的 Release 标为失败 DRAFT，不删
资产、不自动重传。若恢复草稿状态也无法确认，明确记录 `unknown`，不能声称已恢复。
后续获准重跑使用新的 run／attempt tag，不复用失败草稿。

## 历史 build 11：固定资产白名单

名称及源路径以 [ASSET_PATHS](../scripts/publish_release.mjs#L23-L34) 为准，
不递归打包整个工作区或 build 目录。

| 资产 | 条件／用途 |
| --- | --- |
| [UIReview.zip](../scripts/publish_release.mjs#L24) | 导出的测试截图；下载 ZIP 不等于已逐图审核。 |
| [TestResults.zip](../scripts/publish_release.mjs#L25) | 原生／UI 测试结果；本轮仅远端验证，未下载。 |
| [places-manifest.json](../scripts/publish_release.mjs#L28) | 固定公开地点来源、生成信息及哈希。 |
| [parity-report.json](../scripts/publish_release.mjs#L26)、[provenance.json](../scripts/publish_release.mjs#L27) | 请求模型时包含；导出对齐与公开来源报告，不替代原生验证。 |
| [LocalImageIQ-iphoneos-unsigned.ipa](../scripts/publish_release.mjs#L29)、[device-build.json](../scripts/publish_release.mjs#L30)、[SHA256SUMS.txt](../scripts/publish_release.mjs#L31) | 仅成功的设备构建；未签名 IPA、包身份报告、校验文件。 |
| [LocalImageIQ-Simulator.zip](../scripts/publish_release.mjs#L32) | 仅成功的非设备构建，与 IPA 分支互斥；不能装到 iPhone。 |
| [delivery.json](../scripts/publish_release.mjs#L343-L349) | 发布器生成的交付清单；不是任意额外文件上传入口。 |

云端仍只下载固定公开模型／地点来源，上传公开来源报告与生成测试证据；不上传私人
照片、GPS、数据库或视频。现有模型、20 worker、HQ224／Fast、缓存身份均不改。

## 历史 build 11：清单与完成记录的区别

- 远端 [delivery.json 清单](../scripts/publish_release.mjs#L343-L349) 绑定仓库、run ID、
  attempt、源码 SHA、Release ID／tag，以及每项载荷的 asset ID、字节数、SHA-256 和
  远端验证方式，并保留设备／模型／地点身份。清单不包含自身哈希，自身另行验证；
  它在发布前生成，内嵌 URL 可能仍是草稿 URL，不能只看 URL 判断最终发布状态。
- runner 的 [release-delivery.json 完成记录](../scripts/publish_release.mjs#L371-L375)
  保存验证完成的结果和最终 Release 状态，**不是另一个远端上传资产**。中途失败以
  脱敏日志／步骤摘要的失败阶段和已验证资产为准，不假定完成记录一定存在。
- Release 发布成功不代表整个 Actions run 已结束，也不代表 Windows 已收到 IPA。
  **只有新 CI 完成、身份一致且本地 IPA 全量长度／SHA-256 校验成功，才可报告交付完成**；
  **本轮这三项均已完成**。真机签名、安装与翻译效果仍待验证；截图只完成下述四张的有限审核。

## 历史私有阶段：本机只读下载 helper

[.git/imageiq-releases.cjs](../.git/imageiq-releases.cjs) 仅在本机，位于 Git 内部目录，
不提交仓库。接受模式、run ID 和可选 attempt（默认 **1**），远端操作全部为 GET：

| 模式 | 实际工作 |
| --- | --- |
| `report` | 核验账号／私有仓库、run／attempt／SHA、已发布 prerelease、清单和远端资产身份；不下载 IPA。 |
| `fetch` | 再下载并核验设备报告、原校验文件和 IPA；全量流式长度／SHA-256 通过后才最终定名，不覆盖已有文件。 |
| `ui-review` | 只下载并校验截图 ZIP，不解压、不加载图片，也不声称视觉审核完成。 |

helper 只通过既有 GCM 凭据读取子进程取得账号凭据；令牌留在内存中用于 API header，
不传给后续子进程、不落盘、不打印凭据／响应正文／签名 URL。GitHub 返回的签名下载
URL 请求**不带 Authorization、Cookie 或 GitHub 认证头**；CI 发布器本身不启动子进程。

本地下载记录由 helper 生成，**不是从 runner 下载的完成记录**；当前按模式生成唯一
[本地记录名](../.git/imageiq-releases.cjs#L420-L461)，避免覆盖以前的记录。只把实际
读取并核验的资产标为本地验证，`report` 中的远端声明不能算 IPA 下载证明。
设备文件和 UI ZIP 分别写入本机 build 下的设备下载／界面审核目录，按 run／attempt 隔离；
不复用旧 runner 哈希，不把部分下载当成成品。

**历史 build 11 实际审核范围**：UI ZIP 校验后，仅另外提取四张新增 `UIReview-query-translation-*` PNG，
已实际查看 [1340×758 联系图](../build/ui-review/36387878343/query-translation-contact.jpg)。
普通态原中文／英文／“使用原文”可读，缺包回退提示／设置入口可见；Settings 四控件及
屏内页脚可读但较密；大字号原文／英文／按钮可见，下方空状态延伸到屏外，不能证明整页。
其他图像未提取／查看，ZIP 内截图总数未核实；5 项展示测试不是按钮 UI 自动化。
均是假翻译／零结果场景，不是 Apple 翻译质量、系统弹窗或真机行为证据。

**历史 build 11 当时的安装步骤**：使用上述旧版已校验 IPA，原 Sideloadly 账号／有效 Bundle ID 覆盖安装，不卸载、不清库；已有 build 10
当前策略索引无需重建或续跑。Settings 准备中文 → 英文包、同意下载、确认就绪后，
搜索“身份证”，比较实际英文与“使用原文”，不保证输出 “ID card” 或提升效果。
语言包不在 IPA 中；**PENDING-DEVICE**：真实 Apple 翻译、语言包下载／同意、离线质量和延迟。
iOS 17 原文回退、检查与翻译之间的语言包移除竞态／系统提示及隐私边界保持不变，见
[QUERY_TRANSLATION.md](QUERY_TRANSLATION.md)。操作见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。