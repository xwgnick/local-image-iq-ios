# 初版图标 B02 与纯图标启动页

> **当前为 0.5.8 / build 21（2026-10-04，第二次整体验证 SUCCESS）**，不是首轮成功；失败修正与交付见 [BUILD_STATUS.md](BUILD_STATUS.md)。用户已批准的 [真实步骤进度](STARTUP_STEP_PROGRESS.md) 更新了下文“运行时始终只有图标”的旧约定：**系统 Launch Screen 仍静态且仅图标，图标／背景资源未改**；App 内仅在慢风险上下文或未完成到 8 秒时显示按真实完成数 / 9 推进的细条，不显示文字、转圈、流动动画或自动填充，不加最低停留或任务截止时间。相同指纹已有完整成功记录的正常快速重启仍只有图标。
>
> 原生四屏夹具／像素与状态测试已分别通过，父流程已实际查看 [四图联系图](../build/ui-review/37198392990/startup-progress-contact.jpg)；0.375 是绘制夹具，水印仅属测试，不是真实进度或耗时。现有 UI 11 项通过不等于新增实时条可见性 E2E，真机验收仍待确认。**以下 build 17／16 的发布、计数、截图和当时源码边界均保留为历史**；本注只更新现行状态与运行时展示约定，不改写旧记录，其余素材／系统静态启动及失败恢复说明按对应版本理解。

## 当前交付（2026-10-02）：0.5.4 / build 17 首轮 SUCCESS，B02 画面保留

**手动索引与启动路径调整已完成原生验证和交付。**[CI 37022941546](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37022941546)／[job 110890327401](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37022941546/job/110890327401)，源码 **`02d5bc72b4d463bf2adca50dbf1d571a93183354`**；既有个人公开仓库标准 `macos-15` 手动工作流，模型／全部计算单元／设备构建三个输入均为 `true`，**attempt 1 SUCCESS，无追加重试**。核心 **79 通过**、App **484＝483 通过／1 既有 SQLite 文件保护模拟器跳过／0 失败**、UI **10 通过**；本轮启动展示 **9**、启动状态 **15**、启动 worker **8** 均通过，已包含在 App 总数中，不重复计数。

[build 17 Release](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37022941546-1)（**401925676**，**2026-10-02T15:15:39Z**，**9 项资产、公开 prerelease、非 draft**）已发布。[本地 IPA](../build/device-download/37022941546/LocalImageIQ-iphoneos-unsigned.ipa) 已完整流式下载并校验：**1,418,481,134 字节**，SHA-256 **`51068e4916314399c0ad7bae3e0db7c33ac652691976cfd51c4ae4a241e3b071`**；7-Zip 26.03 全量归档 CRC 通过。设备包为 **arm64 Release、未签名、SDK 18.5、Xcode 16.4、最低 iOS 17.0**，仍须用户在本机签名。

- B02 系统启动画面和 App 内准备页仍**只有同一个静态图标**，无名称、阶段文字、进度条或转圈。主图像模型、文本模型和分词器仍完整准备；正常准备不可跳过，不加人为等待。仅失败时轻点图标重试、长按约一秒先进入，辅助功能恢复动作保留。
- 启动／自动刷新不枚举 PhotoKit 全库、不清理索引或解析完整地点几何；只读 SQL 聚合的是**已保存统计，不是当前可搜索数量**。搜索仍保留初始／评分前／评分后三次只读授权快照及 UI 发布前复查，不写入／prune 数据库，不承诺权限原子性或绝对零竞态。
- 实际 IPA 已核验小 manifest 的运行时元数据：**22,960 字节**，新 SHA-256 `7edb232043452d9a6f718b8a59a121fa0938dfdd54e732ed97e2be60f195b7e5`；地点版本仍为 `raycast-v1-93c9a925e35247f2`。完整几何仍为 **15,175,079 字节／2,943 要素**，SHA-256 `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4` 不变。完整解析仅由手动索引按需执行；小元数据缺失／无效不回退到完整解析。
- 模型、索引／地点缓存身份、SQLite schema 1、20 worker、HQ224／Fast 和 iCloud 规则不变。**原 Sideloadly 账号／有效 Bundle ID 覆盖安装，不卸载、不清库、不因升级重建或重跑索引**；需要纳入新增／编辑照片时才手动更新，未变化的有效向量复用，“全部重建索引”须确认且只是可选操作。

### build 17 截图范围与尚未验证的边界

[UI 截图 ZIP](../build/ui-review/37022941546/UIReview.zip) 已下载并校验：**4,253,640 字节**，SHA-256 **`afd7a841ca6c111cb124ed132062dd484a5ae64d7735bd0659f1c3aec1e9e4a3`**。父流程实际仅查看 [1340×758 四图联系图](../build/ui-review/37022941546/manual-index-contact.jpg)：

- 浅／深色合成启动图各 **393×852**，带测试水印；正式 App 无水印。**两张图各自 SHA-256 与 build 16 对应图相同**，本轮未重做启动视觉，只调整背后的工作路径。
- 真实模拟器未授权首页／图库各 **1206×2622**，展示新的手动索引操作；**不是已授权图库，没有读取 Photos**。未声称查看其他图片。

这些截图不是物理 iPhone 测试、启动视频或加速证据。**本轮没有实际 iPhone 耗时测量，也没有新增 telemetry／计时埋点**；模型／分词器仍完整准备，不承诺瞬时启动或具体提速。物理 iPhone 安装、系统启动页交接、失败手势互斥、图标缓存及真实图库性能仍待确认；不是说已执行的原生测试仍未验证。

完整行为、测试子套件及包校验见 [MANUAL_INDEX_STARTUP.md](MANUAL_INDEX_STARTUP.md)，安装见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。**以下各节保留 build 16 原始接入历史**；其中“本次未改 AppState／worker／索引”、测试数与截图只属于当时 build 16，不描述 build 17 的改动或替代其证据。

## 历史：2026-10-02，0.5.3 / build 16 首轮 SUCCESS，已交付

用户选定 `AlbumVsPhotoSearch_2026-10-01 / B02`（照片＋搜索／高级感），并明确要求：App 有此图标；打开时的加载页面仅显示这一个图标，无文字、进度条、转圈或其他装饰。

已按此前流程完成：[CI 37004642577](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37004642577)，源码 `ffbe286e9f130bc325d1a2d2e5993b6e9c240f12`，标准 macos-15 含模型／全部计算单元验证及设备构建，首轮 SUCCESS。[Release](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37004642577-1) 已发布；[本地 IPA](../build/device-download/37004642577/LocalImageIQ-iphoneos-unsigned.ipa) 已完整下载并通过 SHA-256 与全量归档 CRC 检查。未改变企业 origin、计费或发布规则。

## 素材

- [选定前景块原文件](../Resources/Branding/B02-selected.png)：676×702 RGBA，与用户选定的去外背景版字节一致。
- [系统 App Icon](../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png)：1024×1024 不透明 RGB；等比放置前景，不拉伸、不重绘金色相机／放大镜。只有原透明处以同类深灰补齐系统要求的方形，未恢复原海报式黑背景或外投影。系统负责最终图标蒙版。
- [启动图资源](../App/Assets.xcassets/LaunchLogo.imageset/Contents.json)：192pt 的 1x／2x／3x 透明 PNG，由同一前景等比导出。
- [素材来源与哈希](../Resources/Branding/manifest.json)、[离线生成与验证脚本](../scripts/build_brand_assets.py)。运行应用／构建不依赖该脚本或工作区其他设计文件，图片已放入原生项目。

## 两段启动画面

1. [LaunchScreen.storyboard](../App/LaunchScreen.storyboard)：系统静态启动页，只包含一个居中的 `LaunchLogo` UIImageView。无代码任务、无标签或进度组件。
2. [StartupContent](../App/UI/StartupView.swift)：App 根视图启动后、真正准备模型期间，同样只显示一张静态图标。

两者共享 `LaunchLogo`、192×192pt 视口、相对于整个画布居中及 `LaunchBackground` 自适应浅／深色背景。背景是承载图标的纯底色，不另加卡片、名称、阶段文案或页脚。加载时隐藏 App 状态栏，并请求自动隐藏系统覆盖元素；iOS 系统手势提示的最终行为仍受系统控制。

无最短停留时间、计时跳转、动画或新增启动超时。根入口仍以 `launchPhase == .ready` 为唯一正常首页条件，保留原 `.task { state.start() }` 与前后台处理。

## 失败恢复：画面仍只有同一个图标

- **仅在真实 `.failed` 状态**，轻点图标重试，长按约一秒先进入应用。
- 两种手势互斥，长按不同时触发重试。VoiceOver 提供相同操作和脱敏错误信息，但不渲染可见文字。
- 正常准备时没有恢复手势，不能点击跳过模型准备；状态层原有失败／前台／忙碌守卫保留。
- 明确继续进入时仍保留原错误和真实搜索校验，不将失败当成功。
- 图标自身不变色、不旋转、不叠加错误符号。此种不可见恢复操作的发现性有限，规则在此记录；不以新增可见按钮违背纯图标要求。

本次未改 `AppState`／worker 的准备逻辑、模型、20 路并发、PhotoKit、索引、SQLite、权限请求、搜索排名或翻译行为。不增加等待来展示图标。

## 验证结果与边界

- `scripts/test_branding.py`：**12 项通过**。检查 plist、storyboard 单图结构／居中尺寸、asset catalog、PNG 格式／尺寸／透明度规则、素材哈希、根入口门控以及无可见阶段文字／进度／假延时。
- `scripts/test_static.py`：**30 项既有静态测试通过**。
- `scripts/check_project.mjs --self-test` 与源码契约检查：**通过**。
- 素材生成脚本已实际运行并验证 4 个派生 PNG 与选定源文件，AppIcon 无 alpha，启动图包含透明通道。此检查不替代系统图标显示验证。
- 更新了 `StartupPresentationTests`：图像资源存在性、各启动阶段在不同大小／主题下绘制一致、失败操作守卫、辅助功能错误脱敏，以及四张原生状态截图。截图水印只存在于测试宿主，不存在于生产启动页。
- 更新真实启动 UI 测试：仍等待首页或失败；只有明确 `IMAGEIQ_REQUIRE_MODELS=0` 才能长按失败图标继续，模型必需的运行不得绕过。
- 将品牌静态检查加入现有**手动**验证流程；本轮按用户授权运行同一流程，不改变权限、计费或发布条件。

**本轮原生验证已完成：**核心 79、App 429（428 通过／1 既有跳过）、UI 10，无失败；StartupPresentationTests 9 全通过，含不同阶段的像素一致检查。设备编译通过；实际 IPA 中核验了 AppIcon 元数据、Assets.car 和编译后的 LaunchScreen.storyboardc。

已查看 [四张启动原生截图联系图](../build/ui-review/37004642577/startup-contact.jpg)，浅／深色加载与失败均只显示 B02；右上角“测试场景”仅为测试水印。相同主题下加载与失败截图字节一致。

**仍未验证：**物理 iPhone 安装、系统启动页到 SwiftUI 的真实交接、失败手势互斥的真机触摸行为、安装后的系统图标缓存及真实图库性能。截图是合成状态，不把它当成真机冷启动视频。详见 [BUILD_STATUS.md](BUILD_STATUS.md) 的 build 16 账本。