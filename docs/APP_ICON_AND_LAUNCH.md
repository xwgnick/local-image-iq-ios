# 初版图标 B02 与纯图标启动页

## 状态：2026-10-02，0.5.3 / build 16 首轮 SUCCESS，已交付

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