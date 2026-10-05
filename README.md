# Local Image IQ · Native iOS

SwiftUI + PhotoKit + Core ML + 系统 Vision。独立原生 App，以本机检索为主，不是桌面网页套壳。

## 当前交付：0.7.0 / build 25

**DELIVERED：已完成原生验证、设备构建、发布及本地 IPA 校验；真机行为仍待验证。**最终源码 `45e58ba5aceb9331b15ed39a4504f143618d5f75`，[CI 37295461425](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37295461425)／[job 111715497281](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37295461425/job/111715497281) SUCCESS。该新 run 为 attempt 1，**是本功能整体第二次原生验证，不是首轮成功**；首轮仅因新增测试辅助函数不接受 throwing closure 失败，随后一行 `rethrows` 修正只改测试，两轮间 App 生产代码不变。核心 79 通过；App 974（973 通过／1 既有 SQLite 物理保护测试跳过／0 失败）；UI 13 全通过。新增六组 119 项 App 测试全部通过，其中 4 项实际调用 Vision 识别合成图；详细耗时、失败账本及验收边界见 [docs/PHOTO_TEXT_SEARCH.md](docs/PHOTO_TEXT_SEARCH.md)。

- 本地已校验包：[build/device-download/37295461425/LocalImageIQ-iphoneos-unsigned.ipa](build/device-download/37295461425/LocalImageIQ-iphoneos-unsigned.ipa)。完整下载 **1,418,904,925 bytes**，全文件流式长度／SHA-256 与 7-Zip 26.03 全量 CRC 均通过。
- [公开 Release：ci-37295461425-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37295461425-1)，ID `403616561`，9 项资产、prerelease、非草稿；发布时间 **2026-10-05T10:55:25Z**。
- 设备包为 **arm64 Release、未签名、iOS 17+、SDK 18.5／Xcode 16.4**，仍需 Sideloadly 本机签名。

### 本版变化与下一步

- **设置 → 照片文字 →「文字搜索增强」**：默认 OFF，明确选择后持久保存。开启后再点「**更新文字索引**」，保持前台；只开开关不索引、不请求 Photos 权限，启动与搜索也不自动 OCR。系统 Vision 识别中英文，文字匹配与图片排序实验性融合，不保证所有查询都改善。
- **复用有效的当前图片索引**，不重新编码已有有效图片向量。新增／编辑照片须先手动更新图片索引，再更新文字索引；文字更新可暂停，回前台不会自动续跑。像素、权限、敏感文字保存及 RRF 限制见 [docs/PHOTO_TEXT_SEARCH.md](docs/PHOTO_TEXT_SEARCH.md)。
- **原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不为升级重建。**安装步骤见 [docs/WINDOWS_IPHONE_INSTALL.md](docs/WINDOWS_IPHONE_INSTALL.md)。旧版网格画质诊断与限制见 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)，默认调试仍 OFF。
- **build 24 基线保留**：结果多选／批量分享／收藏／系统相册操作，日期／相册／图片类型筛选，以及只用缓存图片向量的「找相似」。原功能契约、三轮验证历史和截图限制仍见 [docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)，不以本轮 OCR 夹具替代其真实 Photos 操作验收。

已实际查看最终 [两张原生文字索引夹具拼图](build/ui-review/37295461425/photo-text-contact.jpg)：黑金设置页开关 ON、合成计数 12／8／3，未授权注入使更新按钮禁用；进度页为 12／24（50%），显示暂停入口。顶部 TEST 是测试水印，不是生产 UI；这些是合成汇总状态，不是实际照片 OCR 质量或性能证据。

## 保留的行为

- 默认首批 **12 张**，到底部再追加 12；设置“每批显示”可选 3／12。同一查询只翻译、编码及全局排序一次；**完整候选 ID／向量仍留在 RAM，属于显示分页，不是有界内存或数据库分页**。见 [docs/HQ_RESULT_PAGING.md](docs/HQ_RESULT_PAGING.md)。
- 索引仅由用户手动更新；已有有效记录复用，新增／编辑照片需手动更新才改变向量。启动／自动刷新只读统计元数据，不扫描全库、做 OCR 或清理索引；轻量读取也不是瞬时启动保证。见 [docs/MANUAL_INDEX_STARTUP.md](docs/MANUAL_INDEX_STARTUP.md)。
- 索引 HQ224／Fast 策略、20 个图像 worker、SigLIP 2 FP32／`.all`、768 维向量、模型／索引版本及离线地点缓存身份不变。全屏旧离线 Fast 加载路径**未升级**，不能用全屏代替网格验收。
- B02 黑金主题及九步确定进度不变：系统 Launch Screen 仍仅静态图标；App 内慢风险／等待场景按真实完成步骤显示细条。见 [docs/STARTUP_STEP_PROGRESS.md](docs/STARTUP_STEP_PROGRESS.md)。
- 支持 Photos 全部／有限授权、语义检索、预览与分享、四国离线行政区辅助及可关闭的系统中文查询翻译；新增手动、可关闭的本机 OCR，没有后台无限索引或 App 云端检索兜底。本版仅新增照片文字搜索，未扩展为近重复整理、标签／评分或保存查询。

## 工程与构建

只将本原生 iOS 子目录作为独立仓库根；**不要上传外层工作区中的私人照片、视频、数据库或桌面缓存**。公开仓库为 [xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios)，企业仓库不动。

现有 [.github/workflows/ios.yml](.github/workflows/ios.yml) 仅手动运行，标准 `macos-15`；本版 `include_models`、`all_compute_units`、`build_device_ipa` 三项均为 `true`，保留完整模型转换／数值对齐、核心、App、UI 和设备构建门槛。**本轮未改变 CI，未新增缓存、跳过测试或更换 runner 规格。**构建耗时解释与尚未获准实施的缓存建议见 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)。

|入口|用途|
|---|---|
|[project.yml](project.yml)、[project.models.yml](project.models.yml)|XcodeGen App／测试配置及生成模型资源。|
|[docs/IMPLEMENTATION_CONTRACT.md](docs/IMPLEMENTATION_CONTRACT.md)|SigLIP 2 成对编码、768 维向量、图像预处理与本地 tokenizer 契约。|
|[docs/NATIVE_PARITY.md](docs/NATIVE_PARITY.md)|真实模型数值验证；不能用维度相同替代对齐。|
|[docs/QUERY_TRANSLATION.md](docs/QUERY_TRANSLATION.md)|iOS 18+ 真机系统翻译与独立语言包准备，iOS 17 原文回退。|
|[docs/PHOTO_TEXT_SEARCH.md](docs/PHOTO_TEXT_SEARCH.md)|build 25 OCR 契约、两轮原生结果、交付资产与未验证项。|
|[docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)|build 24 功能契约、最终交付证据、三轮原生验证历史与未验证项。|
|[docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)|build 25 及历次交付的资产、测试与失败／修正账本。|

## 隐私与交付边界

照片、坐标、向量及 OCR 在本机处理，App 不自动上传图库；PhotoKit 网络默认 OFF，只有用户显式允许才按需联网，不要求下载整库原图，也不保证全部照片离线可用。原始 OCR 正文可能敏感，保存在受系统文件保护、排除备份的本机独立数据库；关闭增强或撤回照片权限**不会自动擦除旧文字**，但无权限照片不参与搜索。用户主动分享会把临时渲染 JPEG（非原图／RAW／Live Photo 原资源）交给所选接收方；主动收藏／相册命令会修改系统 Photos 元数据，不改原图像素、不删除原照片。Apple 密码、验证码和证书只由用户在本机工具／Apple 流程处理，不交给聊天或 CI。免费开发签名通常 7 天到期，不是永久安装或 App Store／TestFlight 分发。

原生测试、合成截图及完整 IPA 长度／SHA-256／CRC 校验**不替代真机安装、实际照片画质、覆盖率、延迟、RSS／发热和系统行为验证**；包完整性也不是实际 Photos 操作或分享质量的证明。

项目未设置项目级许可证；第三方模型、地点数据及代码许可分别保留，`redistributionApproved: false` 与人工再分发审查不变。公开可下载不等于法律审核完成，当前未提交商店。公开范围见 [docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md)。

## 历史文档

[README_HISTORY_THROUGH_BUILD22.md](README_HISTORY_THROUGH_BUILD22.md) 完整保留提交 `2075334` 的 README 原文（截至 build 22），包括历次交付、失败与修正记录。归档位于仓库根目录，原相对链接保持不变；其中“当前／本轮”等仅指当时版本，现行状态以上文为准。

0.5.10 / build 23 的 HQ224 交付与三轮验证历史见 [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md) 和 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)。

0.6.0 / build 24 的结果工具交付与三轮原生验证历史见 [docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)；作为保留基线，不代表本版 OCR 的交付状态。