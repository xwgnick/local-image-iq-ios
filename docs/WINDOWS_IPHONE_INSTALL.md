# Windows → iPhone 安装（免费账号）

用户设备：**iPhone 15 / iOS 26.6.1**，只能使用 Windows；已同意使用
**Sideloadly**。这是第三方个人测试安装路线，不是 TestFlight、App Store 或
苹果提供的 Windows 版 Xcode。此前版本已在该手机安装、打开并使用；每个新版本
的界面与实际图库行为仍需在手机上确认。

## 当前：0.5.7（build 20）— 黑金主题首轮 SUCCESS，可选择覆盖安装

**[本地已校验 IPA](../build/device-download/37134037707/LocalImageIQ-iphoneos-unsigned.ipa)** · [公开 Release：ci-37134037707-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37134037707-1)（**402586668**）。IPA asset **608102465**，**1,418,554,047 字节**，SHA-256 **`161d8227129b744490ee40c709e780c6bf4dfc9a674ded89e01343f58f2c14d9`**；已完整流式下载并核验长度／哈希，7-Zip 全量 CRC PASS，`ipaVerifiedLocally: true`。[下载记录](../build/device-download/37134037707/release-fetch-055a1b45-0b9b-4ced-bf66-e1fbda52da44.json) 与配套报告已核验。本机无需重下；另一台电脑从 Release 下载后核对同一长度／哈希。

[CI 37134037707](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37134037707)／[job 111234786439](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37134037707/job/111234786439)，源码 `a7d32dd66077b167f1df95e9186bc8722b2ad923`，沿用个人公开仓库完整 `macos-15` 手动流程，`include_models`／`all_compute_units`／`build_device_ipa` 均为 `true`，**attempt 1 SUCCESS，无 CI 改动或重试**。核心 **79**、App **532＝531 通过／1 既有 SQLite 跳过／0 失败**、UI **11 全通过**，CPU 参考及全部模型对齐保留。设备 **arm64 Release、未签名、iOS 17+、SDK 18.5／Xcode 16.4**；9 项资产于 **2026-10-03T16:08:47Z** 发布，prerelease、非 draft／Latest。完整账本见 [BUILD_STATUS.md](BUILD_STATUS.md)。

1. **是否现在安装由用户选择。**安装时仍用**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不重建**；沿用下方第 1–5 节签名步骤，不照做历史迁移／清库步骤。
2. 正常使用即可；普通页面跟随系统深浅色，原本固定深色的查看器／诊断页仍固定深色。需要时可在深浅主题下查看首页、图库和设置，**本轮仅换主题，不要求启动测速、反复重启或追加诊断截图**。

父流程实际仅查看 [1008×1548 六图联系图](../build/ui-review/37134037707/black-gold-contact.jpg)：深浅色首页已启用搜索、授权状态图库／更新按钮、设置开关 ON，均为 **393×852 原生注入状态夹具**，不是私人 Photos 或真机。**build 20 手机安装／外观与实际使用仍待验收**；公开下载、原生通过与原包 CRC 不等于重签包或物理 iPhone 已通过。

生产图标／启动资源与源码未改；浅色启动 PNG 与 build 19 字节相同，深色仅右上测试水印背景 `[319,69,386,97]` 随 `IQStyle.muted` 换色，不是生产图标变化。build 19 并行准备／全部就绪门控及计时、FP32／`.all`、20 worker、手动索引、模型／索引／地点缓存身份均保留，照片未作修改。主题与审核边界见 [BLACK_GOLD_THEME.md](BLACK_GOLD_THEME.md)。**以下 build 19 及更早段落全部为历史，旧测速要求不是本轮安装前提。**

## 历史（2026-10-03）：0.5.6（build 19）— 首轮 SUCCESS，可覆盖安装；真机待验

**[本地已校验 IPA](../build/device-download/37047342399/LocalImageIQ-iphoneos-unsigned.ipa)** · [公开 Release：ci-37047342399-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37047342399-1)（402078025）。原始 IPA **1,418,554,098 字节**，SHA-256 `adbefa8524b5521c1a00b58419b9f277bd2278f968f8ca98cc639fff7afecc38`；完整流式下载、实际哈希及 7-Zip 26.03 全量 CRC 通过，`ipaVerifiedLocally: true`。[下载记录](../build/device-download/37047342399/release-fetch-99209550-b1dd-46a4-8588-0a49dfef19f8.json) 与配套报告齐全。本机无需重下；另一台电脑从 Release 下载，核对同一长度／哈希。

[CI 37047342399](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37047342399) 首轮完整 macos-15 手动流程 SUCCESS，源码 `382452945f80eda35174407890abf5b518e47994`：核心 **79**、App **527（526 通过／1 既有 SQLite 跳过）**、UI **11 全通过**，CPU 参考／全部模型对齐保留。包为 **arm64 Release、未签名、iOS 17+、SDK 18.5／Xcode 16.4**；9 项资产于 **2026-10-02T18:59:53Z** 发布，prerelease、非 draft／Latest。公开下载和原包校验不等于免签安装或手机已验证；详见 [BUILD_STATUS.md](BUILD_STATUS.md)。

1. 用**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不重建**；签名步骤见下方第 1–5 节。
2. 等纯图标准备完成，先正常查询一次，确认已有索引仍可搜索。
3. 打开 **设置 → 显示调试工具 → 诊断信息 → 启动耗时**，截图版本、总耗时与三条并行任务的时长／完成状态／开始偏移；只有一屏放不下才补第二张。不必先开调试再启动，也不需为测速反复重启或清数据。

三项准备并行但仍全部就绪后才进首页，不转嫁到首搜；FP32／`.all`、模型与缓存身份、手动索引及 20 个索引 worker 不变。父流程已查看 [六附件联系图](../build/ui-review/37047342399/timing-contact.jpg)：两张实际计时截图字节相同（三分支已同屏），**只有一次模拟器记录 4.554 秒**；四张合成图不是手机测量。不能与 build 18 手机 **15.981 → 4.559 秒、随后多次约 5 秒**基线直接比较，不承诺快 3 秒；build 19 手机性能及峰值内存待验证。完整范围见 [LAUNCH_TIMING.md](LAUNCH_TIMING.md)。以下旧版包及当时操作仅保留历史，不照做旧迁移／清库步骤。

## 历史（2026-10-02）：0.5.5（build 18）— 启动耗时诊断版，首轮 SUCCESS

**[本地已校验 IPA](../build/device-download/37031320019/LocalImageIQ-iphoneos-unsigned.ipa)** · [公开下载页](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37031320019-1)。原始 IPA 1,418,525,487 字节，SHA-256 `88fc52f0a9e957bc267fac02c396e4b0e3dade0f45d070eef5ffbcab5bda589f`；实际完整下载、哈希和全量 CRC 通过。核心 79、App 505（504 通过／1 既有跳过）、UI 11，无失败。设备 arm64 Release／未签名／iOS 17+，模型必需未绕过；本轮[验证账本](BUILD_STATUS.md)。

使用**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不因测速重建**。进入首页后：**设置 → 打开“显示调试工具” → 展开“诊断信息” → 启动耗时**。截图总耗时、最慢阶段与列表，一屏不够分两张。记录在启动时自动产生，不用先开调试，普通前台刷新不覆盖。

只有测量和页面变化，仍保留纯图标启动及用户手动索引。计时不含系统进程启动／准备入口前初始化／首页首帧，不是手机点击到显示全程；本次仅有模拟器观察，真实 iPhone 的数值待截图。详见 [LAUNCH_TIMING.md](LAUNCH_TIMING.md)。

## 历史（2026-10-02）：0.5.4（build 17）— 首轮 SUCCESS，手动索引版已交付

- [公开 Release：ci-37022941546-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37022941546-1)（**401925676**），**2026-10-02T15:15:39Z** 发布，**9 项资产、prerelease、非 draft**，无需登录。
- [本地已校验 IPA](../build/device-download/37022941546/LocalImageIQ-iphoneos-unsigned.ipa)：asset **605869344**，**1,418,481,134 字节**，SHA-256 **`51068e4916314399c0ad7bae3e0db7c33ac652691976cfd51c4ae4a241e3b071`**。已实际完整流式下载并核验长度／哈希，`ipaVerifiedLocally: true`，本机无需再次下载；[设备报告](../build/device-download/37022941546/device-build.json)、[交付清单](../build/device-download/37022941546/delivery.json)、[校验文件](../build/device-download/37022941546/SHA256SUMS.txt)、[下载记录](../build/device-download/37022941546/release-fetch-1bcda8c5-e734-4b0b-9cb8-a815559b795d.json) 齐全。
- **7-Zip 26.03 全量解压／CRC PASS**：11 文件夹、30 文件，解压后 **1,563,320,201 字节**。只验证原始 IPA，不验证 Sideloadly 重签后的包或手机安装。
- [CI 37022941546](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37022941546)／[job 110890327401](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37022941546/job/110890327401)，源码 **`02d5bc72b4d463bf2adca50dbf1d571a93183354`**，**attempt 1 SUCCESS，无追加重试**。既有个人公开仓库标准 `macos-15` 手动流程，模型／全部计算单元／设备构建均为 `true`。核心 **79 通过**、App **484＝483 通过／1 既有 SQLite 真机文件保护模拟器跳过／0 失败**、UI **10 全通过**；完整计数及耗时见 [MANUAL_INDEX_STARTUP.md](MANUAL_INDEX_STARTUP.md)。设备 **arm64 Release、未签名、SDK 18.5、Xcode 16.4、最低 iOS 17.0**。
- B02 纯图标启动画面保留，主图像／文本模型和分词器仍完整准备。启动／自动刷新不扫描全库、不清理数据库或读取完整地点几何；真实搜索仍有初始／评分前／评分后三次只读授权快照。**没有实际 iPhone 启动／首搜耗时，不承诺瞬时启动或具体提速**。

**用原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装，不卸载、不 Clear index、不因升级重建，也不必 Index / resume。**模型、索引／地点缓存身份和 SQLite schema 不变，已有当前策略有效记录沿用。需要纳入新增／编辑照片时才到“我的图库”手动“更新索引”；未变化的有效记录复用，“全部重建索引”可选、须确认，不是升级前提。签名步骤见下方第 1–5 节。

父流程实际仅查看 [1340×758 四图联系图](../build/ui-review/37022941546/manual-index-contact.jpg)：浅／深色合成启动图各 **393×852**，带测试水印；真实模拟器未授权首页／图库各 **1206×2622**，展示新手动索引操作，**不是已授权图库，没有读取 Photos**。两张启动图各自 SHA-256 与 build 16 对应图相同；不扩大为其他图片已审核或真机已测试。**本轮手机安装、系统启动交接、失败手势及性能仍待确认**；原生测试和包校验已经完成，不是待构建状态。

下列版本段落保留历史包身份、测试和当时操作；其中“当前／本轮”、旧启动检查或迁移要求不描述 build 17。现行操作以本节和第 1–5 节为准，不照做旧迁移／清库测速。

## 历史（2026-10-02）：0.5.3（build 16）— B02 图标与纯图标启动页，已交付

- [公开 Release：ci-37004642577-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37004642577-1)，无需登录。
- [本地已下载 IPA](../build/device-download/37004642577/LocalImageIQ-iphoneos-unsigned.ipa)：**1,418,464,962 字节**，SHA-256 `1e5f1fe7329563dd7e60c83d42a19d327109e548c90cc5f22d582e1ec3ab187c`。已流式全量核验哈希并通过 7-Zip 全量归档 CRC 检查，不必再次下载。
- [CI 37004642577](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37004642577) 首轮 SUCCESS：核心 79、App 429（428 通过／1 既有跳过）、UI 10；设备包为 arm64 Release、未签名、iOS 17+，Xcode 16.4／SDK 18.5。
- 已打包用户选定 B02 系统图标与静态启动画面；真正准备模型时也只显示图标，不显示文字／spinner。仅失败时轻点图标重试，长按约一秒先进入；正常准备不可跳过。

用**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装，不卸载、不 Clear index、不重建索引**。模型、索引身份及语言包策略未改，已有有效数据沿用。签名操作同下方原步骤。

本轮尚未获物理 iPhone 安装／行为确认；不要把原生模拟器测试或 CRC 通过当成手机已验证。系统图标／启动截图缓存可能需要后续真机确认，不能因此建议先卸载清数据。完整证据见 [BUILD_STATUS.md](BUILD_STATUS.md)，[四张启动原生截图](../build/ui-review/37004642577/startup-contact.jpg) 中的“测试场景”水印不在正式 App 内。

## 历史（2026-09-29）：0.5.2（build 15）— 已交付并本地校验

- [公开 Release：ci-36560321362-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36560321362-1)
  （**399087745**），**2026-09-29T11:40:49Z** 发布；**9 项资产已核验，非 draft、prerelease、非 Latest**，无需登录。
- 本机已备好 [../build/device-download/36560321362/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36560321362/LocalImageIQ-iphoneos-unsigned.ipa)：
  asset **598069416**，**1,414,873,867 字节**；SHA-256：
  `6a87f668f9c9cb78d9c29fb7688c605251e52b8268453113b200c32be530dfb6`。
  **已完整流式下载并核验实际长度／哈希，`ipaVerifiedLocally: true`**；设备报告、校验文件、交付清单及
  [下载记录](../build/device-download/36560321362/release-fetch-575b5b11-b947-4b15-8804-4f579d3c9964.json) 齐全。
  本机无需再次下载；另一台电脑从该 Release 下载后核对同一长度／哈希。
- **7-Zip 26.03 `t` 全量解压／CRC PASS，Exit 0，Everything is Ok**：10 文件夹、24 文件，
  解压后 **1,559,639,751 字节**。只验证上述原始本地 IPA，不验证 Sideloadly 重打包／签名后的包或手机。
- [CI 36560321362](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36560321362)
  ／[job 109379367704](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36560321362/job/109379367704)，
  源码 **`39aa72e7acf2cccb2b32788fb1537dde1f83191e`**，**首轮 SUCCESS**；核心 **79 通过**，
  App **427＝426 通过／1 既有真机文件保护模拟器跳过／0 失败**，**227.312 秒**（wall **250.282 秒**）。
  新增启动测试 **29 全通过**，GeneratedModelParity **8／156.402 秒**全通过，20 actor **120／252**
  与原 **23／58** 门槛保留；UI **10 全通过／611.864 秒**（导航 **5／349.749**、键盘 **5／262.115 秒**）。
  本轮模型必需，UI 实际等待启动门控、没有绕过。设备 **BUILD SUCCEEDED：0.5.2 / 15、arm64 Release、
  未签名、SDK 18.5、Xcode 16.4、最低 iOS 17.0**。

**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装，不卸载、不 Clear index。**
build 10+ 当前策略有效图像／地点索引与就绪语言包沿用，**不重建、不必 Index / resume**；签名步骤见下方第 1–5 节。

冷启动会先在 **App 内、首页前**显示准备页，按真实 `checkingLibrary`／`preparingSearch` 阶段
检查图库、加载主图像／文本模型及分词器，随后复查授权／修订快照；**不加载额外 19 个索引模型、
不建立索引、不算照片向量、不读取 Photos 像素、不联网**。不定进度没有假百分比、ETA 或计时跳转。
失败可重试或带错误“先进入应用”；准备未完成时后台取消，回前台先排空再重新准备。
已就绪后切回 App 仍只做 build 14 元数据 refresh，**不重放启动页**。

明确继续后的轻量资源检查可能重新显示就绪，**不证明已知运行时错误消失或向量健康**；实际搜索
仍完整准备／校验，读取向量、翻译与编码查询。不是全缓存预热，**不保证随后无等待或零延迟**。
模型、缓存身份、20 worker、HQ224／Fast、排名与翻译策略均不变。

UI ZIP 已下载校验；父流程**实际仅查看
[1340×758 启动联系图](../build/ui-review/36560321362/startup-contact.jpg) 中四图（各 393×852）**：
浅色检查图库、深色准备模型、浅／深色错误页，均有合成测试水印、不读取 Photos。
错误页是合成渲染，**不是实际模型运行时报错截图**；按钮有状态契约／渲染覆盖，不声称全部真机点击已验证。
其他图片未审核；build 15 真机安装、启动／首搜耗时与前后台体验仍未验证。
详见 [STARTUP_SCREEN.md](STARTUP_SCREEN.md) 与 [BUILD_STATUS.md](BUILD_STATUS.md)。
无付费设置、CI 控制、公开范围或项目许可证变更；未跟踪研究／原型仍仅本地保留、未暂存。

## HISTORY／历史：0.5.1（build 14）— 已交付并本地校验，可签名覆盖安装

以下保留 build 14 及更早版本当时的记录；其中“当前／本轮／待验证”仅指各历史阶段，现行 build 17 以页首为准。

- [公开 Release：ci-36553434443-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36553434443-1)
  （**399036139**），**2026-09-29T10:27:37Z** 发布；**9 项资产已核验，非 draft、prerelease、非 Latest**，无需登录。
- 本机已备好 [../build/device-download/36553434443/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36553434443/LocalImageIQ-iphoneos-unsigned.ipa)：
  asset **597928214**，**1,414,832,318 字节**；SHA-256：
  `a22ba8f60be8d6fb54585e9a253f8f165453a546a45029889a57c4e91c37153f`。
  **已完整流式下载并核验实际长度／哈希，`ipaVerifiedLocally: true`**；配套报告／清单／校验文件／下载记录齐全。
  **7-Zip 26.03 `t` 全量解压／CRC 检查通过，Exit 0，Everything is Ok**：10 文件夹、24 文件，
  解压后 **1,559,429,031 字节**；未提取文件，不代表签名后的包或手机已验证。本机无需再次下载。
- [CI 36553434443](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36553434443)
  ／[job 109356825463](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36553434443/job/109356825463)，
  源码 **`33a00dde0b974c4641106de5096d0b627a3436f4`**，**首轮 SUCCESS**；核心 **79 通过**，
  App **398＝397 通过／1 既有真机文件保护模拟器跳过／0 失败**，UI **10 全通过**。
  设备 **BUILD SUCCEEDED：0.5.1 / 14、arm64 Release、未签名、SDK 18.5、Xcode 16.4、最低 iOS 17.0**。

**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引。**
build 10+ 当前策略有效图像／地点索引与就绪语言包直接沿用，**不必 Index / resume**；签名步骤见下方第 1–5 节。
“正在检查图库”仍在核对授权照片及缓存变化，不是重新编码；完整授权快照、清理及首次约 15 MB 地点包解析保留。
本版把完整模型／分词器加载延后到搜索等实际操作，计数只查 SQLite 元数据，不再为数量解码全库向量；
**并非彻底跳过或零等待**。首次搜索仍完整准备／校验向量；坏向量可能被计数并显示就绪，但搜索仍报错。
UI／AppState／Photos、模型权重、输入／排名／并发策略不变，无需诊断或指定查询。
本轮仅实际查看四张用户模式图的联系图，**未看其他图片、无真实 Photos／build 14 真机验证或手机耗时**；
详见 [STARTUP_REFRESH.md](STARTUP_REFRESH.md) 和 [BUILD_STATUS.md](BUILD_STATUS.md)。
CI／计费、项目许可证与公开范围不变，未跟踪研究／原型仍仅本地保留、未暂存。

## 历史：0.5.0（build 13）— 已交付并本地校验，可签名覆盖安装

以下保留 build 13 当时包身份与验证范围；“本轮／当前”等仅指该历史版本，现行交付以页首为准。

- [公开 Release：ci-36540269511-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36540269511-1)
  （**398951411**）发布于 **2026-09-29T08:30:53Z**，**prerelease、`draft: false`、非 Latest，9 项资产已核验**，无需 GitHub 登录。
- 本工作区已备好
  [../build/device-download/36540269511/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36540269511/LocalImageIQ-iphoneos-unsigned.ipa)：
  asset **597693809**，**1,414,830,691 字节**；SHA-256：
  `d5ebe9881bc596f8c45b29cfdf5ed986b07e665e3a46fdf691dd09bb52a3db31`。
  **完整流式下载、父流程实际长度／哈希核验完成，`ipaVerifiedLocally: true`**，配套报告、校验文件、
  交付清单及下载记录齐全。本机不需再次下载；另一台电脑从 Release 下载并核对相同长度／哈希。
- **7-Zip 26.03 全量解压／CRC 测试另已通过**：Exit **0**，`Everything is Ok`，10 文件夹、
  24 文件，解压后 **1,559,424,855 字节**，压缩包 **1,414,830,691 字节**。
  这只验证上述本地原始 IPA，**不验证 Sideloadly 重打包／签名后的 IPA 或手机**。
- [CI 36540269511](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36540269511)
  ／[job 109313762175](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36540269511/job/109313762175)，
  源码 **`158c3bf661efcc688ecbe313a4f5c52a3271d803`**，**COMPLETED / SUCCESS**。
  核心 **79 通过**；App **377＝376 通过／1 项既有真机文件保护模拟器跳过／0 失败**，
  **214.296 秒**（wall **264.142 秒**）；UI **10 全通过／545.341 秒**，含新增键盘／底部图库回归。
  设备 **BUILD SUCCEEDED：0.5.0 / 13、arm64 Release、未签名、SDK 18.5、Xcode 16.4、最低 iOS 17.0**。

**使用原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装，不卸载、不 Clear index。**
build 10+ 当前策略有效索引与就绪语言包沿用，**不重建图像／地点、不必 Index / resume**；
直接正常搜索／看图，不要求诊断或指定查询。默认 **Top 3／地点权重 0.6**、20 worker、
HQ224／Fast、翻译、索引／缓存不变。签名步骤仍见下方第 1–5 节。

B 界面为实际自适应灰底／青绿，普通文案与照片错误中文，导航“完成”青绿；统一双列 4:5／
紧凑三列、间距 6／4，隐藏视觉排名但保留顺序。系统键盘／分享语言跟随 OS，调试原始值可能英文，
不声称完全本地化。本轮实际仅审核两张联系图中的 **12 张合成／未授权截图**，没有真实 Photos／
手机验证；详细范围和首轮 B 的 UI 9/10 失败历史见 [BUILD_STATUS.md](BUILD_STATUS.md)、[TEAL_UI.md](TEAL_UI.md)。

**build 13 尚未获真机安装／行为确认。** 用户已确认 build 12 安装成功；之前短暂的
`PackageExtractionFailed` 原因未知，不能归因于存储空间。项目许可证、公开范围或计费不变；
未跟踪的研究／原型因含公共 Unsplash 示意图仍仅本地私存、未暂存，不宣称仓库全部干净。

## 历史：0.4.1（build 12）— 已交付，IPA 已校验且用户确认安装成功

以下保留 build 12 包身份与安装说明；“本轮／新包／当前”等仅指当时 build 12。当前交付以页首为准。

2026-09-28，同一仓库已确认 **PUBLIC／`private: false`**。用户已确认既有历史、
Actions 日志及已发布 Releases 公开；详见 [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md)。

- **另一台电脑无需 GitHub 登录**：打开
  [0.4.1 / build 12 Release：ci-36515068434-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36515068434-1)
  （ID **398799791**）。发布于 **2026-09-29T03:27:14Z**，**prerelease、`draft: false`、
  非 Latest，9 项资产已核验**；这是 build 12 首次完成交付，不是首次构建尝试。
- **本工作区的新包已就绪**：
  [../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa)。
  asset **597136564**，精确 **1,414,818,257 字节**；SHA-256：
  `840085413cee964c7de03fa4453f89db9691ec74f8165064e3d07e432ccec03c`。
  **已完整流式下载并由父流程核验实际长度／SHA-256，`ipaVerifiedLocally: true`**；
  同目录设备报告、校验文件、交付清单及下载记录齐全，不需要在本工作区再次下载。
  另一台电脑下载后须核验同一长度／哈希；工作区链接不会自动传送文件。
- [CI 36515068434](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434)
  ／[job 109235419277](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434/job/109235419277)，
  源码 **`fac5e2d39d37730ccf45e2f8e0231124247d4cf8`**，已 **COMPLETED / SUCCESS**。
  核心 **79 通过**，App **370 项：369 通过、1 项既有真机文件保护模拟器跳过、0 失败**
  （**258.961 秒**，wall **288.923 秒**）；UI **9 全通过／522.447 秒**。
  Advanced 标签 ID 作用域修正＋语义点击已通过原生验证，完整套件耗时与失败历史见
  [BUILD_STATUS.md](BUILD_STATUS.md)，不把旧 AX 空树当成 ID 继承的直接证据。
- 设备 **BUILD SUCCEEDED**：**0.4.1 / 12、arm64 Release、iphoneos18.5 SDK、Xcode 16.4、
  最低 iOS 17.0、未签名**。仍需 Sideloadly 本机签名，公开下载不等于免签安装，
  编译本身不等于真机测试；用户现已另行确认 build 12 安装成功，其他真机行为仍待验证。
- **现在可覆盖安装 build 12**：使用原 Sideloadly Apple 账号／原有效 Bundle ID；已有
  build 11／10 当前策略有效索引及就绪语言包沿用，**不卸载、不 Clear index、不重建
  图像／地点，也不必 Index / resume**。正常搜索／看图，不要求指定查询或诊断。
- 本轮已校验 UI ZIP，只实际审核[四场景联系图](../build/ui-review/36515068434/user-mode-contact.jpg)
  （1340×758，原图各 393×852）：Settings 底部 OFF／Maintenance／隐私可见；Library
  Photos 连接／iCloud 可见、索引禁用、无 Details；空查看器 OFF 只有禁用分享，ON 时
  分享／照片检查／本地预览对比均可见且禁用。合成空状态／未授权、不读取 Photos，
  不是真机证据，不声称其他图像已审核。

公开转换不改模型、20 worker、HQ224／Fast、翻译或索引策略；项目不设置项目级许可证，
第三方再分发审查仍未完成。公开下载这一事实不等于一般复用授权或法律许可批准。
标准 `macos-15` 公开 runner 免费但受平台规则约束，不重置旧用量；计费、权限及可见性不再调整。
当前签名步骤见下方第 1–5 节；build 11 旧包及先前失败仅作历史。完整验证账本见
[BUILD_STATUS.md](BUILD_STATUS.md)。

## 历史检查点（2026-09-28，转公开前）：0.4.1（build 12）— 第三轮未启动，无新包

以下版本历史保留当时错误、校验值和步骤；“私有／需登录／先查计费／不重试”是旧阶段
条件，**不适用于当前公开下载**。现行已交付入口以页首为准，
不要重复历史查询、诊断或迁移步骤。

[第三轮 CI 36397742264](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264)
／[job 108848065780](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264/job/108848065780)
已 **COMPLETED / FAILURE**，job **STARTUP / NOT STARTED，`steps: []`**。准确 annotation：

> The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the Billing & plans section in your settings

现有证据只能确定为**账号付款／支出限额相关的启动阻塞**，不能判断是付款失败还是预算／
限额问题；**不是 Actions artifact 存储问题，也不是 Release 发布器 bug**。账号所有者
需要手动查看 GitHub **Settings → Billing & plans** 的付款及限额状态。不自动修改计费、
不建议自动提高限额或增加支出、不索取凭据，也不追加重试。**继续使用现有 0.4.0 / build 11**；
第三轮没有运行测试、设备构建或发布，没有可安装的新包。

第二轮源码 `d2174787c1bd276c9bc38e6d6d2f1efe28ef0015` 已推送同一 `personal` 私有仓库。
[CI 36396468128](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36396468128)
／[job 108843930321](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36396468128/job/108843930321)
已 **COMPLETED / FAILURE**，仅两项原生 UI 测试仍因整行点击未命中开关、等待 ON 失败，
与首轮是同一根因。App **370 项：369 通过、1 项真机文件保护在模拟器跳过、0 失败
（130.279 秒）**；展示 **7 项**、状态 **14 项**全部通过且已计入总数，精确子套件耗时
未提供，不补写。独立 UI **9 项：7 通过、2 失败（319.699 秒）**。

当前 HEAD **`70ad74b0f5e411ca60f741b1300545d1dbaf25c9`** 已提交并推送，相比第二轮
仅新增 UI 测试的行内 **(0.9, 0.5)** 点击修复；用户 App 代码与第二轮 App 测试通过时
相同。位置依据已捕获的实际行／开关本体坐标，但**第三轮未启动，修复未执行验证，
不能声称 9 项 UI 全通过**。App **370**／UI **9** 只是待运行规模；第二轮不含这项点击修复。

首轮源码 `2af11f6d759bcf7c021c20d73878cf4e5376dac4` 的
[CI 36394279080](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36394279080)
／[job 108836892722](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36394279080/job/108836892722)，
已 **FAILED**，不是 Actions 配额问题：App **370 项、1 跳过**，仅 7 项展示测试产生
**25 个断言失败**，进程内 AX 对所有元素（包括普通控件）读到零；14 项状态测试全部
通过（**0.140 秒**）。UI **9 项中 2 项失败**：已下载校验的首轮失败 UI ZIP 中，两份
debugDescription 文本显示 `show-debug-tools` 标识整行，`row.tap()` 点中行中心的标签，
未命中右侧开关本体，两项点击后值均仍为 **0**。**此前“视口移动”的根因猜测已撤回，
未观察到生产开关失效**；其余回归通过。仅检查文本、未查看图片，坐标及证据身份见
[BUILD_STATUS.md](BUILD_STATUS.md)。

**首轮、第二轮设备构建均 SKIPPED，没有 build 12 IPA**。
失败证据 **6 项资产已上传并核验至 Release 398051690**，但随后更新 draft 状态的
PATCH 漏传 tag，使 GitHub 将未发布 Release 的 `tag_name` 改为
`untaged-e8f3a293686e58364ecc`。实际回读 **`draft: true`、无 IPA**；原发布器日志
状态为 `unknown`，严格身份检查失败。**证据不是安装包，也不等于成功发布。**
`ci-36394279080-1` 仅为首轮预期 tag，不能当作下载入口；本次未修复或发布该远端 draft。

**第二轮发布器的失败证据 draft 路径 SUCCEEDED**，显式 tag 修复已在该真实路径验证，
首轮发布器 bug 已解决；不是普通成功 Release 发布，不代表首轮旧 draft 已修复，
更不是新 IPA 就绪。第二轮 **Release 398066345／tag `ci-36396468128-1`** 仍为
**DRAFT、无 IPA**，发布器步骤 **SUCCESS**，不能作为安装入口。

第二轮 UI ZIP（asset **594909127**，**32,920,094 字节**）已下载并校验至
[../build/ui-review/36396468128/UIReview.zip](../build/ui-review/36396468128/UIReview.zip)，
SHA-256：`59e77bd362d1ed25a38b5c06a2b11df2f512b09e2c52b09eeed6e0031c4530d7`。
仅提取四张用户模式图，父流程已实际查看
[1340×758 联系图](../build/ui-review/36396468128/user-mode-contact.jpg)：Settings 底部开关 OFF，
Maintenance／隐私说明可见；Library 连接入口、iCloud 控件可见，索引禁用、无 Details；
空查看器 OFF 时只有分享入口，ON 时分享／照片检查／本地预览对比均可见且禁用。
这些是合成空状态／未授权场景，**不是私人 Photos 或真机照片，不证明开关语义点击成功**。
其他 ZIP 图片未查看，不声称总数或全部审核。当前 App 源码未变，第二轮的有限视觉结论
适用于相同场景，**但不是第三轮产物或新运行验证**。

继续现有私有 Release 路线，仓库权限不变，不从 Actions artifact 交付新包；
**build 12 未交付／未完成本地校验**。
下方 build 11 的下载链接／字节数／哈希只属于旧包，不能作为 build 12 安装证明。

### 历史检查点的操作：当时保留旧版，等待后续交付

1. **现在不安装新版，继续用现有 0.4.0**。账号所有者先检查上述 Billing & plans；
  当前不自动改计费、不追加 CI。只有阻塞解决、后续新运行通过测试和设备构建后，才进入
  私有 Release 上传、新 IPA 下载和长度／SHA-256 核验；这不是已启动或排队的新任务。
2. 届时确认 Release／设备报告为 **0.4.1 / build 12**，并完成对应新包核验后再签名；
  当前不提供或猜测新包链接。仍需用 Sideloadly 本机签名。
3. 用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**；**不卸载、不清库、不重建索引**。
  已有 **0.4.0 或 0.3.4 当前策略有效索引**无需迁移，也不用为了升级点 Index / resume。
4. 已有当前策略索引／就绪语言包直接沿用，打开 App 正常搜索／看图即可；
  不要求诊断、重新准备已有语言包、测试指定查询或重复旧截图流程。
  升级到 build 12 后，需要调试时才到 **Settings 最底部 → Show debug tools**；每次启动默认 OFF，
  只在本次会话有效，不保存。页脚提醒：隐藏工具**不会重置先前调整的权重等设置**。

普通模式仍保留 Photos 权限、Ready／数量／进度、缺预览／读取失败友好提示和 iCloud
显式许可；Settings 的结果数量、中文增强／语言选择／准备、Maintenance Refresh／
Clear 确认，以及搜索的英文提示／“使用原文”都可正常使用。关闭调试只收起诊断界面、
清理临时报告／问题并取消活动预览，不取消索引／搜索／语言包准备，也不改查询／结果／缓存。

第二轮已包含的修复集中在测试与发布器：原生展示改用公开 UIKit 的真实行布局、非空白渲染像素及
**OFF → ON → OFF** 稳定性检查，**不是 AX 语义证明**；真实 Settings／Library 语义
仍由跨进程 UI 测试明确断言，未削弱。不使用进程内 AX 是测试方法的边界，**不表示 App
没有 AX**。原有滚动／重新获取开关再等待值的处理仍保留，但不解决误点标签。
当前 HEAD 的点击修复已提交／推送，按捕获坐标定位右侧开关本体；**不在第二轮中，第三轮
未启动，修复尚未执行验证**。
唯一 App 运行时小改动是查看器 Combine 忽略未变化的值，避免回放触发反复清空 nil；
该改动已包含在第二轮通过的 App 代码中，此后未再改 App。正常看图、搜索、索引逻辑及
20 worker／HQ224／Fast／模型／翻译／缓存不变，未削弱调试功能，未新增跳过测试，
既有 1 项真机文件保护跳过不变。

发布器每次自身 PATCH 显式传入 `run.tag` 与运行源码 SHA，并保留严格身份检查；
模拟真实 GitHub 行为的本地发布器测试为 **88 项 PASS（此前 83 项）**，第二轮另已验证
失败证据 draft 路径成功，不据此宣称普通成功发布。第三轮未执行 App **370（349＋14＋7）**／
UI **9**；第二轮四张用户模式合成图已按上述范围审核，不代替点击语义或真机验证。
详见 [USER_MODE.md](USER_MODE.md)、[BUILD_STATUS.md](BUILD_STATUS.md)。以上为转公开前
历史检查点，不是当前安装要求；build 11 及更早记录保留如下。

## 历史：0.4.0（build 11）— 私有 Release 已发布，本地 IPA 已校验，可签名安装

以下保留 build 11 当时的包身份与步骤；“现在／新包／无需等待”仅指 build 11，
不是 build 12 已就绪。当前升级无需照做历史诊断或迁移步骤，以上方为准。

用户已明确批准**方案 2：同一私有仓库 Release＋job 级 contents: write**，不改公开
可见性或计费。新源码 `844492b754f86d519c904da21cd80c1c814c056b` 相比已通过
原生／设备验证的 `0c09c46ff5edf74ffeb4a2cece2f7b9fd20a5910`，仅改工作流和两个
发布／测试脚本，没有 App、索引、模型改动；发布器 **83 项本地 Node 22 mock 测试通过，
CI 对应步骤也 PASS**。
[CI 36387878343](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343)
／[job 108817040032](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343/job/108817040032)，
已 **COMPLETED / SUCCESS**，实际 `TEST SUCCEEDED` 和设备 `BUILD SUCCEEDED`。
这是**两次 Actions artifact 配额失败后的首次私有 Release 尝试成功**，不是整体首轮成功。
**新 IPA 已完整下载并校验**，不是旧 build 10 包。

### 已备好的 build 11 安装包：本机与另一台电脑

- **本工作区**：[../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa)。
  已实际全量下载，父进程直接流式复验长度／SHA-256 一致，`ipaVerifiedLocally: true`；
  设备报告、校验文件、交付清单及下载记录齐全，无部分下载残留，所有旧本地包保留。
- **另一台 Windows 电脑**：打开
  [旧版 Release：ci-36387878343-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)。
  发布当时私有，须登录有读取权限的账号；**2026-09-28 转公开后不再要求 GitHub 登录**。
  下载同一未签名 IPA，核验以下长度／SHA-256 后再签名；本地工作区链接不会自动传送文件。
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

### 历史 build 11 当时的安装步骤

当时本工作区的 build 11 新包已经就绪；以下不是当前版本的升级要求。

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

### 历史 build 10 当时的安装步骤

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

### 历史 build 9 当时的诊断步骤

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
  需要重新索引，**不会删除系统相册的照片**。这是当时的可选测速，不是覆盖安装前提。

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
[构建记录](BUILD_STATUS.md)。

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

**当前升级目标 0.5.4 / build 17 已完成交付、本地哈希及 CRC 校验，可执行下方签名／安装步骤**。
使用页首 CI 37022941546 对应的新包和哈希，不用历史 build 16 及更早包或失败 draft 代替。
先前失败与修复过程见 [BUILD_STATUS.md](BUILD_STATUS.md)，不再是等待安装的阻塞。

## 1. 安装工具（由你操作）

从 [Sideloadly 官方网站](https://sideloadly.io/) 下载 Windows 64-bit 版本，
不要从镜像站、网盘或所谓“免签平台”获取。安装器的 UAC／管理员确认由你处理。
若这是受管理的工作电脑，先确认允许安装第三方签名工具和 Apple 设备驱动。

首次设置另一台 Windows 电脑时，保留官网 Windows 下载入口的 **Before you install**
步骤：按 Sideloadly 官方要求安装 **网页版（非 Microsoft Store 版）iTunes 和 iCloud**，
不要只取 Sideloadly 安装器而跳过前置组件。按官方提示补齐 Apple Mobile Device 驱动，
必要时重启电脑，再打开 iTunes、连接已解锁手机并完成信任。资源管理器能看到手机
不等于 Apple 驱动／配对已就绪；不必开启 iCloud Photos 或同步私人照片。
**不要未经确认卸载已有的 iTunes、Apple Devices 或 iCloud**；版本冲突按工具实际
提示排查，已可用的电脑不因本次 App 升级重新安装这些组件。

Sideloadly 自己的 [隐私声明](https://sideloadly.io/privacy) 声称 Apple 凭据只发送
给 Apple；这只是开发者声明，不是本项目对工具的安全审计。首次使用需要接受
这个第三方工具的信任边界；不向任何聊天、GitHub Secrets 或本项目脚本提供密码。

## 2. USB 连接手机

1. 用支持数据传输的 USB-C 线连接 iPhone 和这台 Windows，解锁手机。
2. 在手机弹窗选择“信任此电脑”，手机密码仅在手机上输入。
3. 等 Sideloadly 中的设备列表显示你的 iPhone。没有识别时先排查驱动／线缆，
   不反复提交 Apple 登录。

## 3. 签名安装已交付的 build 17

1. 使用已完整下载并校验的
  [../build/device-download/37022941546/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/37022941546/LocalImageIQ-iphoneos-unsigned.ipa)，
  Release／设备报告为 **0.5.4 / build 17**。另一台电脑从
  [ci-37022941546-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37022941546-1)
  下载，并按页首 **1,418,481,134 字节／SHA-256** 核验后再拖进 Sideloadly。
  公开 Release 单独提供 IPA，无需 GitHub 登录或解压外层 Actions ZIP；**不解压或修改 IPA 的 Payload**。
2. 选择已连接的 iPhone，使用原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，
   不卸载、不清索引；Apple Account 必须是本人有权使用的账号。
3. 点击 Start；密码及双重认证仅由你在工具／Apple 登录流程中手动输入。
   如工具明确要求普通密码或 App 专用密码，以当前官方说明为准，不互相替代试错。
4. 不启用 dylib 注入、插件或其它改包功能。首次签名可能需要调整开发用 Bundle ID；
   保持之后重签所用账号／标识一致，不随意删除旧 App 以免丢失其本地索引。

历史 **0.5.3 / build 16、0.5.2 / build 15** 及更早包身份与下载入口保留在本页历史章节，不是本次新包，
不要求回退或重装旧版。

## 4. 手机上完成信任

- 如提示“未受信任的开发者”，在“设置 → 通用 → VPN 与设备管理”找到自己的
  开发者身份并信任，只信任你刚使用的账号，不安装陌生企业描述文件。
- iOS 16+ 开发测试通常需要“设置 → 隐私与安全性 → 开发者模式”，开启后按系统
  要求重启和确认。菜单暂时不出现时，先完成一次配对／开发签名安装再检查。
- 若遇到账户或设备管理政策禁止开发者模式，停止并确认政策，不绕过设备管理。

## 5. 覆盖安装 build 17 后：沿用已有索引，需要新内容时才手动更新

**build 17 原生测试、设备构建、发布与本地校验均已完成，用户侧签名／安装及真机运行尚未确认**。
用户已确认 build 12 安装成功，此前短暂错误原因未知，不归因于空间；不是 build 17 安装证明。
已有 build 10+ 当前策略有效索引／就绪语言包时，覆盖安装后直接正常搜索／看图，
**不卸载、不 Clear index、不因升级重建图像或地点，不必 Index / resume**。
模型、索引／地点缓存身份和 SQLite schema 1 不变。实际 IPA 中地点运行时版本仍为
`raycast-v1-93c9a925e35247f2`，完整几何哈希未变；更新的是小 manifest 的运行时元数据，
不是使旧索引失效的迁移。完整字节数／哈希见 [MANUAL_INDEX_STARTUP.md](MANUAL_INDEX_STARTUP.md)。
不要求重新下载语言包、测试“身份证”或其他指定查询、
断网验证、诊断或截图；这些都不是升级或正常使用的前置任务。尚缺语言包且需要中文增强时，
可自行在设置中准备；已有语言包无需重做，原文搜索仍可使用。照片联网默认 OFF，
仅按需要显式允许，不因升级改变。

冷启动只显示 B02 静态图标，无阶段文字、进度条或转圈；完成主图像／文本模型及分词器准备后进入首页。
**启动／自动刷新不枚举全库、不清理索引或解析完整地点几何**，只读保存统计，不是重新索引。
仅失败时轻点图标重试、长按约一秒带错误先进入；正常准备不可跳过。
准备未完成的前后台切换会取消、排空后重新准备，已就绪则仅轻量刷新、不重放启动页。
完整向量读取和查询翻译／编码仍在真实搜索时执行；搜索保留初始／评分前／评分后三次只读授权快照，
在解码和评分前过滤不可访问照片，并在 UI 发布前再复查，不写入／prune 数据库。
后续资源元数据就绪不等于已知运行时错误已修复；没有实际 iPhone 耗时测量，不承诺瞬时启动或后续零等待。

**索引更新不是升级步骤**：要让新增／编辑照片反映到搜索中时，才到“我的图库”点“更新索引”，保持 App 在前台。
未变化的有效记录会复用，仅新增、变化或缺少有效记录的照片需要编码；手动扫描负责过期／不可访问记录清理。
未手动更新前，新增照片不会自动加入搜索，仍可访问的已编辑照片继续使用旧向量；已删除／不可访问照片由搜索只读过滤。
“全部重建索引”须明确确认，只是可选维护，不要求先清空再更新。首次没有索引才需“建立索引”；
清除／重建取消后若统计显示“待刷新”，可用“刷新索引统计”只读恢复，不会扫描照片或偷偷更新索引。

调试工具仅在需要时从**设置最底部的调试工具开关**打开；**每次启动默认 OFF**，
仅当前会话有效。关闭会隐藏诊断界面、清理临时报告／问题并取消活动预览，
**保留先前调整的权重**，不取消索引／搜索／语言包准备，不重置查询／结果／模型／缓存。
更早模型／输入策略尚未迁移的情况才参考历史迁移；不因本次手动索引／启动路径更新重做历史流程。

## 隐私与模型许可不因本次更新而放宽

照片、坐标和向量仍在本机处理，不上传图库；应用不扫描未授权照片。PhotoKit
网络默认关闭，只有用户主动开启后才可按需访问 iCloud；不会要求下载整库原图。
系统语言包准备是独立的用户同意流程，不改变上述开关；原文／译文在设备上处理，
不上传到 App 服务器，无 App 云端兜底。系统可能收集不含原文／译文的使用及性能指标；
“本地翻译”不等于系统绝无任何网络活动；检查与翻译之间语言包被移除时仍可能出现系统
下载提示，完整边界见 [QUERY_TRANSLATION.md](QUERY_TRANSLATION.md)。
Apple 凭据仍只由用户在本机签名工具／Apple 流程处理，不交给聊天或 CI。

共享 SigLIP 2 模型卡声明 Apache-2.0，导出流程复制实际存在的模型卡／LICENSE／NOTICE
证据，并保留 `redistributionApproved:false` 及人工许可审查。复制许可证、数值测试
通过或个人签名成功，都不是公开分发的法律认证。地点包的来源／年份／许可记录已随包
保存，同样不能代替再分发许可审查。B02 App 图标已打包；正式发布还需正式 Bundle ID、
签名及 TestFlight／商店配置，当前未提交商店。

## 免费账号的限制

开发描述文件通常 **7 天**失效，需要通过电脑重新签名刷新；这不是永久安装。
通常每台设备最多同时 3 个免费开发应用，App ID 创建也有限制。Sideloadly 提供
自动刷新功能，但是否启用常驻服务／Wi-Fi 刷新由你决定，本项目不会偷偷安装。
TestFlight / App Store 分发仍是另一条需要相应开发者资格的路线。

当前只准备自己的开发测试程序，不越狱、不绕过付费、不使用来历不明的证书。
参考：[Sideloadly FAQ](https://sideloadly.io/faq) ·
[Apple Personal Team 限制](https://developer.apple.com/support/compare-memberships/)。