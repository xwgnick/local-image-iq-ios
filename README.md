# Local Image IQ · Native iOS

SwiftUI + PhotoKit + Core ML。独立离线 App，不是桌面网页套壳。

## 当前交付：0.6.0 / build 24

**VERIFIED：已完成第三次完整原生验证、设备构建、发布及本地 IPA 校验；真机行为仍待验证。**最终源码 `ba18307f0d17ed3554487ad31b7fc6c0662fae5f`，[CI 37281481114](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37281481114)／[job 111670359062](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37281481114/job/111670359062) SUCCESS。该新 run 为 attempt 1，**是本功能整体第三次原生验证，不是首轮成功**。核心 79 通过；App 855（854 通过／1 既有 SQLite 物理测试跳过／0 失败）；UI 12 全通过。三轮历史、耗时、资产身份与验收边界见 [docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)。

- 本地已校验包：[build/device-download/37281481114/LocalImageIQ-iphoneos-unsigned.ipa](build/device-download/37281481114/LocalImageIQ-iphoneos-unsigned.ipa)。完整下载 **1,418,824,951 bytes**，流式长度／SHA-256 与 7-Zip 26.03 全量 CRC 均通过。
- [公开 Release：ci-37281481114-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37281481114-1)，ID `403520360`，9 项资产、prerelease、非草稿；发布时间 **2026-10-05T08:41:51Z**。
- 设备包为 **arm64 Release、未签名、iOS 17+、SDK 18.5／Xcode 16.4**，仍需 Sideloadly 本机签名。

### 本版变化与下一步

- **搜索结果 →「选择」**：多选已显示照片，批量分享、加入／取消收藏、加入已有系统相册或新建并加入；批量工具栏仅在选择模式出现，默认保持简洁黑金界面。
- **搜索框下 →「筛选」**：按拍摄日期、系统相册与图片类型筛选；应用后生效，取消草稿不改变结果。
- **照片查看器 →「找相似」**：以该照片已缓存的图像向量检索，排除种子本身并应用当前筛选；不重新编码、不自动索引。
- 分享是**临时渲染 JPEG**，不是原图／RAW／Live Photo 原资源导出。收藏与相册操作会在用户明确下令后写入 Photos 元数据；不能称整个 App 永远只读，也没有自动整理或删除照片。
- **原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不重建。**手动索引、每批 12 张、HQ224、启动与模型路径不变；安装步骤见 [docs/WINDOWS_IPHONE_INSTALL.md](docs/WINDOWS_IPHONE_INSTALL.md)。旧版网格画质诊断与限制见 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)，默认调试仍 OFF。

已实际查看最终 [5 张原生夹具拼图](build/ui-review/37281481114/search-tools-contact.jpg)：最大字号标题已成为全宽两行，最终测量无横向溢出。但普通字号截图底部 TEST 水印与最下方操作行重叠，**完整工具栏可点击性未充分验证**；大字号部分结果控件在滚动折叠线下，不是完整无障碍证明。截图均为合成状态／未授权占位，不能替代真实 Photos 写入、有限授权变化、AirDrop、导出画质、内存或设备验收。

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
|[docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)|build 24 功能契约、最终交付证据、三轮原生验证历史与未验证项。|
|[docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)|build 24 及历次交付的资产、测试与失败／修正账本。|

## 隐私与交付边界

照片、坐标和向量在本机处理，App 不自动上传图库；PhotoKit 网络默认 OFF，只有用户显式允许才按需联网，不要求下载整库原图。用户主动分享会把临时 JPEG 交给所选接收方；主动收藏／相册命令会修改系统 Photos 元数据，不改原图像素、不删除原照片。Apple 密码、验证码和证书只由用户在本机工具／Apple 流程处理，不交给聊天或 CI。免费开发签名通常 7 天到期，不是永久安装或 App Store／TestFlight 分发。

原生测试、合成截图及完整 IPA 长度／SHA-256／CRC 校验**不替代真机安装、实际照片画质、覆盖率、延迟、RSS／发热和系统行为验证**；包完整性也不是实际 Photos 操作或分享质量的证明。

项目未设置项目级许可证；第三方模型、地点数据及代码许可分别保留，`redistributionApproved: false` 与人工再分发审查不变。公开可下载不等于法律审核完成，当前未提交商店。公开范围见 [docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md)。

## 历史文档

[README_HISTORY_THROUGH_BUILD22.md](README_HISTORY_THROUGH_BUILD22.md) 完整保留提交 `2075334` 的 README 原文（截至 build 22），包括历次交付、失败与修正记录。归档位于仓库根目录，原相对链接保持不变；其中“当前／本轮”等仅指当时版本，现行状态以上文为准。

0.5.10 / build 23 的 HQ224 交付与三轮验证历史见 [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md) 和 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)。