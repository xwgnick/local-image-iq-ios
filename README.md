# Local Image IQ · Native iOS

SwiftUI + PhotoKit + Core ML。独立离线 App，不是桌面网页套壳。

## 当前交付：0.5.10 / build 23

**已完成第三次完整原生验证、设备构建、发布及本地 IPA 校验；实际 iPhone 网格画质仍待确认。**最终源码 `2075334aebd5c90abf0ee70b459e5645fe878d3b`，[CI 37226908383](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37226908383)／[job 111508328530](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37226908383/job/111508328530) SUCCESS。该新 run 为 attempt 1，**不是本功能整体首轮成功**。核心 79、App 713（712 通过／1 既有 SQLite 跳过／0 失败）、UI 11 全通过；三轮记录集中在 [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)。

- 本地已校验包：[build/device-download/37226908383/LocalImageIQ-iphoneos-unsigned.ipa](build/device-download/37226908383/LocalImageIQ-iphoneos-unsigned.ipa)。完整流式长度／SHA-256 与 7-Zip 26.03 全量 CRC 均通过。
- [公开 Release：ci-37226908383-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37226908383-1)，9 项资产、已发布 prerelease；发布时间 **2026-10-04T19:35:19Z**。
- 设备包为 **arm64 Release、未签名、iOS 17+、SDK 18.5／Xcode 16.4**，仍需 Sideloadly 本机签名。

### 本版变化与下一步

- **结果网格补齐 HQ224 路径**：大尺寸本地 HQ 足够且未明确降质则结束，否则尝试按照片实际比例、短边 224 的本地 HQ；只有所有已尝试 HQ 都无可用像素才回退 Fast224。网络仍须明确允许；普通错误与取消照常传播。小图仍可显示，**HQ 名称或返回尺寸不保证清晰度**。
- **只在调试打开时显示实际取图元数据**：图片与选中来源、请求尺寸、原始返回像素、降质标志、缓存状态和尝试路线一起传递。低清回退不长期占用 HQ 缓存；没有定时重试或已显示图片自动升级。
- **原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不重建。**打开“设置 → 显示调试工具”，回到**同一搜索结果网格**，截几张模糊格子及其元数据；不要改去独立对比页取证。默认调试 OFF，普通布局保持原样。步骤见 [docs/WINDOWS_IPHONE_INSTALL.md](docs/WINDOWS_IPHONE_INSTALL.md)。

实际查看的两张原生诊断布局图是**合成夹具／占位图，不是用户 Photos 或画质验收**。大号辅助功能字体下诊断页脚可能裁切；不宣称所有无障碍布局完美。完整选择／缓存契约、原生测试范围与真机取证边界见 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)。

## 保留的行为

- 默认首批 **12 张**，到底部再追加 12；设置“每批显示”可选 3／12。同一查询只翻译、编码及全局排序一次；**完整候选 ID／向量仍留在 RAM，属于显示分页，不是有界内存或数据库分页**。见 [docs/HQ_RESULT_PAGING.md](docs/HQ_RESULT_PAGING.md)。
- 索引仅由用户手动更新；已有有效记录复用，新增／编辑照片需手动更新才改变向量。启动／自动刷新只读统计，不扫描全库或清理索引。见 [docs/MANUAL_INDEX_STARTUP.md](docs/MANUAL_INDEX_STARTUP.md)。
- 索引 HQ224／Fast 策略、20 个图像 worker、SigLIP 2 FP32／`.all`、模型及索引缓存身份不变。全屏旧离线 Fast 加载路径**未升级**，不能用全屏代替网格验收。
- B02 黑金主题及九步确定进度不变：系统 Launch Screen 仍仅静态图标；App 内慢风险／等待场景按真实完成步骤显示细条。见 [docs/STARTUP_STEP_PROGRESS.md](docs/STARTUP_STEP_PROGRESS.md)。
- 支持 Photos 全部／有限授权、语义检索、预览与分享、四国离线行政区辅助及可关闭的系统中文查询翻译；没有 OCR、后台无限索引或 App 云端检索兜底。

## 工程与构建

只将本原生 iOS 子目录作为独立仓库根；**不要上传外层工作区中的私人照片、视频、数据库或桌面缓存**。公开仓库为 [xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios)，企业仓库不动。

现有 [.github/workflows/ios.yml](.github/workflows/ios.yml) 仅手动运行，标准 `macos-15`；本版 `include_models`、`all_compute_units`、`build_device_ipa` 三项均为 `true`，保留完整模型转换／数值对齐、核心、App、UI 和设备构建门槛。**本轮未改变 CI，未新增缓存、跳过测试或更换 runner 规格。**构建耗时解释与尚未获准实施的缓存建议见 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)。

|入口|用途|
|---|---|
|[project.yml](project.yml)、[project.models.yml](project.models.yml)|XcodeGen App／测试配置及生成模型资源。|
|[docs/IMPLEMENTATION_CONTRACT.md](docs/IMPLEMENTATION_CONTRACT.md)|SigLIP 2 成对编码、768 维向量、图像预处理与本地 tokenizer 契约。|
|[docs/NATIVE_PARITY.md](docs/NATIVE_PARITY.md)|真实模型数值验证；不能用维度相同替代对齐。|
|[docs/QUERY_TRANSLATION.md](docs/QUERY_TRANSLATION.md)|iOS 18+ 真机系统翻译与独立语言包准备，iOS 17 原文回退。|
|[docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)|当前资产身份、完整测试计数、三轮失败／修正记录及旧版本账本。|

## 隐私与交付边界

照片、坐标和向量在本机处理，不上传图库；PhotoKit 网络默认 OFF，只有用户显式允许才按需联网，不要求下载整库原图。Apple 密码、验证码和证书只由用户在本机工具／Apple 流程处理，不交给聊天或 CI。免费开发签名通常 7 天到期，不是永久安装或 App Store／TestFlight 分发。

原生测试、合成截图及原始 IPA 校验**不替代真机安装、实际照片画质、覆盖率、延迟、RSS／发热和系统行为验证**。本次只检查小型 IPA 版本／LaunchScreen 元数据，没有再次全量比较模型权重。

项目未设置项目级许可证；第三方模型、地点数据及代码许可分别保留，`redistributionApproved: false` 与人工再分发审查不变。公开可下载不等于法律审核完成，当前未提交商店。公开范围见 [docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md)。

## 历史文档

[README_HISTORY_THROUGH_BUILD22.md](README_HISTORY_THROUGH_BUILD22.md) 完整保留提交 `2075334` 的 README 原文（截至 build 22），包括历次交付、失败与修正记录。归档位于仓库根目录，原相对链接保持不变；其中“当前／本轮”等仅指当时版本，现行状态以上文为准。