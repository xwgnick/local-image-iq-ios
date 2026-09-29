# 公开仓库 — 2026-09-29

## 已确认的范围

- 同一仓库 [xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios)
  于 **2026-09-28** 转为 **PUBLIC／`private: false`**，GitHub API 与匿名 GET 已确认；不是新建、迁移或重写历史。
- 用户明确选择公开仓库＋免费标准托管 runner，并再次确认接受既有历史中的作者邮箱、
  机器路径、测试查询，以及历史 Actions 日志和已发布 Releases 公开。
- 当前 [0.5.0 / build 13 Release：ci-36540269511-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36540269511-1)
  （**398951411**）已公开发布，下载不要求 GitHub 登录；完整交付身份见下文。build 12 Release 398799791 保留为历史。
  历史 [0.4.0 / build 11 Release](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)
  （**398009938**）仍为旧包。两个旧失败草稿 **398051690／398066345** 保持原状；
  转公开不会自动发布 draft，其他失败 drafts 同样不是安装入口。
- 仅这个独立 iOS 仓库公开；不上传整个父工作区。此次无历史重写、删除、企业 `origin`
  变更或计费／预算／卡片／付费额度调整；以前获批的旧 IPA 清理只是历史事实。

## 检查结果与保密边界

已检查 **277 个历史文本 blob，合计 4,653,437 字节，最大 101,959 字节**。
检查范围内未发现 NUL 二进制、图像／数据库／模型 blob，也未发现 `.env`、私钥、
令牌或带凭据 URL 的相关模式命中。**有限模式扫描不保证没有秘密或其他敏感信息**；
已知邮箱、路径和查询案例由用户确认可公开，不从历史中删除。
此结果针对 Git 历史，不表示已发布 IPA 不含模型。只在本机的 `.git` 辅助脚本未发布。
后续 CI 仍只使用固定公开模型／地点来源及生成测试夹具，不上传私人照片、GPS、数据库或视频。

**未跟踪的界面研究／浏览器原型仍仅本地私存、未暂存**，含公共 Unsplash 示意图；
不纳入本次公开提交或原生资源，不因照片来源公开就认定原型可一并发布。
上述有限历史检查不是当前全工作树审计，**不宣称整个仓库干净**；本次仅更新指定文档，不执行 Git／CI 或改变公开范围。

## 当前 CI／发布约束

- 仅 `workflow_dispatch`，精确仓库名且 `private == false`；只用标准 **`macos-15`**，
  不用付费 larger runner 或 self-hosted runner，不添加 push／PR／fork 特权触发。
- 保持全部源码、核心、地点、模型导出／数值对齐、App、UI、设备编译及包验证门槛。
  全局 `contents: read`，构建 job 可用 `contents: write`／`actions: read` 发布 Release；
  只用运行自带 `GITHUB_TOKEN`，不用 PAT，不接收 Apple 密码、证书或签名材料。
- 发布器在 preflight 和 prepublish 均要求精确目标仓库且明确公开，拒绝私有或错误仓库。
  成功资产仍先放唯一 draft，核验身份／字节／SHA-256 后才发布非 Latest 的 prerelease；
  失败证据保留 draft，不把部分上传当交付，不覆盖或删除既有资产。
  发布文字应说明这是 **public CI**，不能声称已获第三方再分发许可。
- GitHub 对**公开仓库的标准 GitHub-hosted runner 用量免费**，须符合平台使用政策、
  运行限制及可用性；这不是无限资源或必定启动的保证。公开仓库**不重置账号已用的私有
  Actions 分钟、历史累计存储用量或其他账号限制**，也不需要提高付费限额。
  参见 [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)。

## 公开源码，不授予项目级许可证

用户选择**不设置项目级许可证**，未采用 MIT 或 Apache-2.0 作为项目许可。
可见源码不等于获授一般性的复制、修改或再分发权；不能称为已按开源许可证授权的项目。
GitHub 平台条款允许的操作与第三方组件自身的许可须分别看待。

第三方权利不变：SigLIP 2 模型卡声明 Apache-2.0，geoBoundaries 来源／许可元数据与
Pillow 的 MIT-CMU 源码头须保留并分别遵守；这些声明不覆盖整个项目。
`redistributionApproved: false` 保持不变，模型／地点再分发人工审查仍未完成。
仓库、Release 已公开这一事实，或 CI 通过，都不是法律许可审查通过。

## 当前（2026-09-29）：0.5.0（build 13）公开交付完成

[CI 36540269511](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36540269511)
／[job 109313762175](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36540269511/job/109313762175)，
源码 **`158c3bf661efcc688ecbe313a4f5c52a3271d803`**，**COMPLETED / SUCCESS**。
核心 **79 通过**；App **377＝376 通过／1 项既有真机文件保护模拟器跳过／0 失败**，
**214.296 秒**（wall **264.142 秒**）；UI **10 全通过／545.341 秒**。
设备 **BUILD SUCCEEDED：0.5.0 / 13、arm64 Release、未签名、SDK 18.5、Xcode 16.4、最低 iOS 17.0**。

- [Release ci-36540269511-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36540269511-1)，
  ID **398951411**，**2026-09-29T08:30:53Z** 发布；prerelease、`draft: false`、非 Latest，**9 项资产已核验**。
- [../build/device-download/36540269511/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36540269511/LocalImageIQ-iphoneos-unsigned.ipa)
  已完整流式下载，父流程实际长度／SHA-256 核验完成，**`ipaVerifiedLocally: true`**；报告、校验文件、交付清单及下载记录齐全。
  asset **597693809**，**1,414,830,691 字节**；SHA-256：
  `d5ebe9881bc596f8c45b29cfdf5ed986b07e665e3a46fdf691dd09bb52a3db31`。
  额外 **7-Zip 26.03 全量解压／CRC PASS，Exit 0，Everything is Ok**，不验证 Sideloadly 重打包或手机。
- UI ZIP **597693697／3,719,566 字节**已下载校验，SHA-256：
  `610189d2dabacda04fb910818f948e974d41b1973d9868d82dd4d2957bc70fe8`。
  父流程实际仅查看[八图青绿联系图](../build/ui-review/36540269511/teal-native-contact.jpg)（1120×1280）和
  [四图用户模式联系图](../build/ui-review/36540269511/user-mode-contact.jpg)（1340×758），共 **12 张原图，各 393×852**。
  均为合成绘图／空状态／未授权场景，无真实 Photos／手机证据，不声称其他图像已审核。

普通文案／照片错误中文，根界面实际自适应系统深浅色，导航“完成”青绿；系统键盘／分享语言跟随 OS，
调试原始值可能英文，不声称完全本地化。默认 **前 3 张／地点权重 0.6**；统一双列 4:5／紧凑三列、
间距 6／4，仅移除视觉排名而保留顺序。20 worker、HQ224／Fast、翻译、索引／缓存不变。
原 Sideloadly 账号／有效 Bundle ID **覆盖安装**，build 10+ 当前策略有效索引和就绪语言包沿用，
**不卸载、不 Clear index、不重建、不必 Index / resume**。用户已确认 build 12 安装成功，
此前短暂错误原因未知；**build 13 尚无真机安装／行为验证**。

首轮 B **36537575789／a2e23979、UI 9/10** 保留为失败历史；第二轮仅补整行命中形状及两个 sheet 导航 tint，
未改测试／时间／坐标，全通过支持修复但不追溯证明旧 AX／根因。
详见 [BUILD_STATUS.md](BUILD_STATUS.md)、[TEAL_UI.md](TEAL_UI.md)。
本次不改源码、项目许可证、公开范围、计费或权限；第三方人工再分发审查仍未完成。

## 历史：0.4.1（build 12）首次完成公开交付

以下“工程仍为／本轮／现在／真机安装待验证”等保留 build 12 当时含义；用户后来已确认该版安装成功。
当前 build 13 的交付与未验证边界以上方为准，不以旧包或旧审核替代本轮证据。

工程仍为 **0.4.1 / build 12**。转公开不改引擎、模型、20 worker、HQ224／Fast、
翻译或索引／缓存身份；已有当前策略索引无需因此重建。

- [CI 36515068434](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434)
  ／[job 109235419277](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434/job/109235419277)
  已 **COMPLETED / SUCCESS**，源码 **`fac5e2d39d37730ccf45e2f8e0231124247d4cf8`**。
  核心 **79 通过**；App **370 项：369 通过、1 项既有真机文件保护模拟器跳过、0 失败**，
  **258.961 秒**（wall **288.923 秒**）；独立 UI **9 全通过／522.447 秒**。
  GeneratedModelParity **8／170.094 秒**、DebugToolsPresentation **7／25.179 秒**、
  DebugToolsState **14／1.055 秒**计入 App；PresentationNavigation **5／354.440 秒**、
  SearchKeyboard **4／168.007 秒**计入 UI，不重复相加，不是手机性能数据。
- Advanced 标签 ID 作用域修正＋语义点击**已通过原生验证**。此前失败的
  `testClearQueryKeepsKeyboardAndSettingsAdvancedStartsCollapsed` 现已通过：两次展开均在
  滚动前验证唯一 `location-weight`、无 `debug-advanced` ID 的 Slider、可点击且 **60%**；
  收起／关闭调试／查询／Top 12 保持不变的检查也通过。旧视频已证明展开，父级 ID 传播
  是有力假设，旧空 AX 树未直接证明继承；完整根因调查保留在构建状态，不夸大为直接证明。
- 设备 **BUILD SUCCEEDED**：**0.4.1 / 12、arm64 Release、iphoneos18.5 SDK、Xcode 16.4、
  最低 iOS 17.0、未签名**，不是物理 iPhone 安装／运行验证。
- [ci-36515068434-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36515068434-1)，
  Release **398799791**，于 **2026-09-29T03:27:14Z** 发布：**prerelease、`draft: false`、
  非 Latest，9 项资产已核验**。这是 build 12 **首次完成交付，不是首次构建尝试**。
- [../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa)
  **已完整流式下载并由父流程核验实际长度／SHA-256**，`ipaVerifiedLocally: true`，
  设备报告、校验文件、交付清单与下载记录齐全。asset **597136564**，
  **1,414,818,257 字节**；SHA-256：
  `840085413cee964c7de03fa4453f89db9691ec74f8165064e3d07e432ccec03c`。
- 本轮 UI ZIP **597136471／3,339,409 字节**已下载校验，SHA-256：
  `9fb0be72629cb43efba8716a22411ca24fdb7bfb291d89e98a9e6e19eb9e43f3`。
  只实际审核[本轮四图联系图](../build/ui-review/36515068434/user-mode-contact.jpg)
  （1340×758，原图各 393×852）：Settings 底部 OFF、Maintenance／隐私可见；Library
  Photos 连接／iCloud 可见、索引禁用、无 Details；空查看器 OFF 仅禁用分享，ON 时
  分享／Photo Check／本地预览对比均可见且禁用。**合成空状态／未授权、不读取 Photos**，
  不是私人图库或真机证据，不声称其他图像已审核。

现在可用新包，以**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装**；已有 build 11／10
当前策略有效索引及就绪语言包沿用，**不卸载、不 Clear index、不重建图像／地点、不必
Index / resume**，无需指定查询／诊断。调试在 **Settings 最底部 → Show debug tools**，
仅会话有效、重启默认 OFF；正常翻译保留。
真机安装、用户模式／系统翻译、离线质量／延迟、20 槽性能／稳定性与文件保护仍待验证；
费用设置、可见性、权限、无项目级许可证及第三方人工审查边界均不改变。

### 历史：交付前的公开 UI 失败

首轮公开 **36400923391** 与后续 **36403948150** 已实际执行原生测试，公开路线的计费启动
阻塞已解除，不代表旧私有用量重置。后者源码 `cfd2943cbec28bf02c1fe2597921cb12ffdec317`，
job **108868075667** 为 **COMPLETED / FAILURE**：App **369 通过／1 跳过／0 失败，226.129 秒**，
UI **8 通过／1 失败，509.597 秒**；设备构建跳过。**DRAFT 398126220／ci-36403948150-1**
的 6 项资产只是失败证据、无 IPA；首轮 draft **398104580／ci-36400923391-1** 同样不是交付。
视频否定“未展开／箭头未命中”的过程、先前猜测及更正详见 [BUILD_STATUS.md](BUILD_STATUS.md)。

### 历史阻塞（2026-09-28，转公开前）

旧源码 `70ad74b0f5e411ca60f741b1300545d1dbaf25c9` 的第三轮
[CI 36397742264](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264)
／[job 108848065780](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264/job/108848065780)
因账号付款／支出限额相关 annotation 在启动前失败，`steps: []`；不是存储配额或发布器 bug。
该历史结果保留，不改写为成功，**也不套用到已完成的公开 CI 36400923391／36403948150
或现已成功交付的 CI 36515068434**。

详见 [BUILD_STATUS.md](BUILD_STATUS.md)、[WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。