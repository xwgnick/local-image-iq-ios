# Cloud build status — 2026-10-02

## Current preparation: 0.5.3 (build 16) — B02 初版图标与纯图标启动页

用户要求沿用既有构建方式：精确个人公开仓库 xwgnick/local-image-iq-ios，手动 ios.yml，标准 macos-15，include_models / all_compute_units / build_device_ipa 全部开启。保留全部原生／模型／设备验证门槛，不绕过测试，不使用企业 origin。

本地 12 项品牌静态检查＋30 项既有静态测试及源码契约检查通过；版本已准备为 0.5.3 / 16。尚未取得本轮远端 run ID 或原生结果，不能声称构建成功或已有可安装新包。改动见 [APP_ICON_AND_LAUNCH.md](APP_ICON_AND_LAUNCH.md)。

## Previous delivery: 0.5.2 (build 15) — 首轮 SUCCESS；旧冷启动准备页已交付，本地 IPA 与 CRC 校验完成

[Run 36560321362](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36560321362)
／[job 109379367704](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36560321362/job/109379367704)，
源码 **`39aa72e7acf2cccb2b32788fb1537dde1f83191e`**，**首轮 COMPLETED / SUCCESS**。
**PASS-NATIVE／PASS-PACKAGE／DELIVERED**；取代 build 15 的待运行／待下载检查点，不改写旧版历史。

### build 15 验证账本

| 项目 | 结果／边界 |
| --- | --- |
| Swift 核心 | 79 通过。 |
| App XCTest | 427 项：426 通过、1 项既有真机文件保护模拟器跳过、0 失败；227.312 秒，wall 250.282 秒。 |
| `LaunchStateTests` | 新增 14 全通过；0.095 秒。 |
| `LaunchWorkerTests` | 新增 8 全通过；0.115 秒。 |
| 启动展示测试 | 新增 7 全通过；0.481 秒。 |
| `GeneratedModelParityTests` | 8 全通过；156.402 秒。真实 20 actor 工厂 120 次预测／252 项测量，原 23 次预测／58 项测量及门槛不变。 |
| 独立 UI | 10 全通过；611.864 秒，实际等待冷启动门控。 |
| `PresentationNavigationTests` | 5 全通过；349.749 秒。 |
| `SearchKeyboardTests` | 5 全通过；262.115 秒。 |
| 设备构建／包 | BUILD SUCCEEDED；0.5.2 / 15、arm64 Release、未签名、iphoneos18.5 SDK、Xcode 16.4、最低 iOS 17.0。 |
| 公开发布 | Release 399087745／ci-36560321362-1；2026-09-29T11:40:49Z，draft: false、prerelease、非 Latest；9 项资产已核验。 |
| 本地 IPA | 已完整流式下载并核验实际长度／SHA-256，`ipaVerifiedLocally: true`，不是只读远端声明。 |
| 归档检查 | 7-Zip 26.03 `t` 全量解压／CRC PASS，Exit 0，Everything is Ok；10 文件夹、24 文件，解压后 1,559,639,751 字节。 |

新增 **14＋8＋7＝29 项全部通过**，App 从 398 增至 427；子套件已计入总数，不重复相加。
唯一跳过为既有真机文件保护限制。**本轮为模型必需运行，UI 实际等待准备页完成，没有绕过启动
或遇错自动“先进入应用”以通过门槛**；model-free 配置的显式继续路径不是本轮绕过手段。
测试耗时不是手机性能；归档检查不验证 Sideloadly 重打包／签名包或手机安装。

### build 15 资产身份与本地证据

- [公开 Release：ci-36560321362-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36560321362-1)，无需登录。
  IPA asset **598069416**，**1,414,873,867 字节**，SHA-256：
  `6a87f668f9c9cb78d9c29fb7688c605251e52b8268453113b200c32be530dfb6`。
- [../build/device-download/36560321362/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36560321362/LocalImageIQ-iphoneos-unsigned.ipa)
  已实际全量下载／本地核验；配套
  [../build/device-download/36560321362/device-build.json](../build/device-download/36560321362/device-build.json)、
  [../build/device-download/36560321362/SHA256SUMS.txt](../build/device-download/36560321362/SHA256SUMS.txt)、
  [../build/device-download/36560321362/delivery.json](../build/device-download/36560321362/delivery.json)、
  [../build/device-download/36560321362/release-fetch-575b5b11-b947-4b15-8804-4f579d3c9964.json](../build/device-download/36560321362/release-fetch-575b5b11-b947-4b15-8804-4f579d3c9964.json) 齐全。
- [../build/ui-review/36560321362/UIReview.zip](../build/ui-review/36560321362/UIReview.zip)
  已下载并校验；asset **598069245**，**3,932,506 字节**，SHA-256：
  `f95be6fccdd9b9bf9221ee556a4a859d6612bf63f0c4eadcc271531f7a4e438c`。

### build 15 有限视觉审核：仅四张启动页图

父流程已**实际查看 [1340×758 启动联系图](../build/ui-review/36560321362/startup-contact.jpg)**，
仅含以下四张原图，**各 393×852**：

| 场景 | 证据范围 |
| --- | --- |
| 浅色加载 | 合成 `checkingLibrary`／检查图库阶段。 |
| 深色加载 | 合成 `preparingSearch`／准备模型阶段。 |
| 浅色错误 | 合成错误页及恢复入口渲染。 |
| 深色错误 | 同一类错误页的深色渲染。 |

四图均带**合成测试水印、不读取真实 Photos**；错误图不是本轮实际模型运行时报错的截图。
错误按钮的证据为**状态契约测试＋合成渲染**，不是所有错误按钮均已在物理 iPhone 点击验证。
不声称审核了其他图片；真实 UI 10/10 与上述有限渲染审核为不同证据，不互相替代。

### build 15 启动契约、安装与剩余边界

- App 根入口在首页前显示原生 SwiftUI 准备页，不是系统静态 Launch Screen 执行任务。
  真实阶段为 `checkingLibrary`／`preparingSearch`，只有系统不定进度，**无假百分比、ETA、计时跳转**。
- 冷启动保留授权快照／修订核对、失效记录清理与地点包准备，再加载主图像模型、文本模型及分词器；
  **预热后再次核对授权／修订快照**。不加载额外 19 个索引模型、不建立索引、不算照片向量、
  不读取 Photos 像素、不联网，也不准备翻译语言包。
- 失败停在错误页，可重试或**带原错误明确继续**。准备未完成时进入后台取消，回前台先等旧任务
  排空再重新准备，旧回调不能发布到新尝试；已就绪后暖前台只做 build 14 元数据 refresh，不再显示启动页。
- **build 14 元数据／已知失败语义保留**：继续后资源检查可能重新显示就绪，并不证明先前运行时
  失败已修复或向量健康；实际搜索仍完整准备和校验。完整向量读取、数值验证、查询翻译／编码仍在
  真实搜索中执行；**不是全缓存预热、不承诺随后无等待或零延迟**，没有新增常驻全图库内存缓存。
- 模型／缓存身份、20 worker、HQ224／Fast、排名与翻译策略不变。原 Sideloadly Apple 账号／
  有效 Bundle ID **覆盖安装，不卸载、不 Clear index、不重建图像／地点、不必 Index / resume**；
  build 10+ 当前策略有效索引与就绪语言包沿用。详见 [STARTUP_SCREEN.md](STARTUP_SCREEN.md)。

**PENDING-DEVICE**：build 15 安装、真实图库、启动／首搜耗时与前后台体验尚未获真机验证。
无付费设置、CI 控制、公开范围或项目许可证变更；第三方再分发审查仍待完成。
未跟踪研究／原型仍仅本地保留、未暂存；本次收尾仅更新指定四份文档，不进行 Git／CI 或源码操作。

## HISTORY／历史：0.5.1 (build 14) — 首轮 SUCCESS；公开交付、本地 IPA 与 CRC 校验完成

以下保留 build 14 及更早版本当时的记录；其中“当前／本轮／待验证”仅指各历史阶段，当前 build 15 以页首为准。

[Run 36553434443](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36553434443)
／[job 109356825463](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36553434443/job/109356825463)，
源码 **`33a00dde0b974c4641106de5096d0b627a3436f4`**，**首轮 COMPLETED / SUCCESS**。
**PASS-NATIVE／PASS-PACKAGE／DELIVERED**；不是等待 CI 或只核验远端清单。

### build 14 验证账本

| 项目 | 结果／边界 |
| --- | --- |
| Swift 核心 | 79 通过。 |
| App XCTest | 398 项：397 通过、1 项既有真机文件保护模拟器跳过、0 失败；153.080 秒，wall 155.295 秒。 |
| `EncoderResourceInspectionTests` | 7 全通过；0.050 秒，均为新增。 |
| worker refresh 新增测试 | 8 全通过；0.052 秒。 |
| `SQLitePhotoStoreTests` | 19 项：18 通过、1 项上述既有跳过、0 失败；0.212 秒，含新增 6 项通过。 |
| `GeneratedModelParityTests` | 8 全通过；109.607 秒。真实 20 actor 工厂 120 次预测／252 项测量，原 23 次预测／58 项测量及门槛不变。 |
| 独立 UI | 10 全通过；529.584 秒。 |
| `PresentationNavigationTests`／`SearchKeyboardTests` | 各 5 全通过；分别 311.315／218.268 秒。 |
| 设备构建／包 | BUILD SUCCEEDED；0.5.1 / 14、arm64 Release、未签名、iphoneos18.5 SDK、Xcode 16.4、最低 iOS 17.0。 |
| 公开发布 | Release 399036139／ci-36553434443-1；2026-09-29T10:27:37Z，draft: false、prerelease、非 Latest；9 项资产已核验。 |
| 本地 IPA | 已完整流式下载并核验实际长度／SHA-256，`ipaVerifiedLocally: true`。 |
| 归档检查 | 7-Zip 26.03 `t` 全量解压／CRC PASS，Exit 0，Everything is Ok；10 文件夹、24 文件，解压后 1,559,429,031 字节；未提取文件。 |

新增 **7＋8＋6＝21 项全部通过**，App 从 377 增至 398；子套件已计入总数，不重复相加。
唯一跳过为既有真机文件保护限制；测试耗时不是手机性能，归档检查不验证 Sideloadly 重打包／签名包或手机。

### build 14 资产身份与有限视觉审核

- [公开 Release：ci-36553434443-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36553434443-1)，无需登录。
  IPA asset **597928214**，**1,414,832,318 字节**，SHA-256：
  `a22ba8f60be8d6fb54585e9a253f8f165453a546a45029889a57c4e91c37153f`。
- [../build/device-download/36553434443/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36553434443/LocalImageIQ-iphoneos-unsigned.ipa)
  已全量下载／本地核验；配套
  [../build/device-download/36553434443/delivery.json](../build/device-download/36553434443/delivery.json)、
  [../build/device-download/36553434443/device-build.json](../build/device-download/36553434443/device-build.json)、
  [../build/device-download/36553434443/SHA256SUMS.txt](../build/device-download/36553434443/SHA256SUMS.txt)、
  [../build/device-download/36553434443/release-fetch-912c5683-3119-456e-894f-f016c2c3dbae.json](../build/device-download/36553434443/release-fetch-912c5683-3119-456e-894f-f016c2c3dbae.json) 齐全。
- [../build/ui-review/36553434443/UIReview.zip](../build/ui-review/36553434443/UIReview.zip)
  已下载并校验；asset **597928021**，**3,722,821 字节**，SHA-256：
  `7e111edb37eff900a8e727a5b72778c1997e3f2e9673b873cd7bdc6709766b49`。
  **实际仅查看 [1340×758 用户模式联系图](../build/ui-review/36553434443/user-mode-contact.jpg) 中四张图**：
  深色设置调试 OFF、未授权图库、空查看器调试 OFF／ON。
  **未查看其他图片；合成／未授权场景不读取真实 Photos，不是真机证据**，不沿用 build 13 的 12 图审核范围。

### build 14 改动与使用边界

refresh 仅检查资源位置／小 manifest，不完整加载模型或解析分词器大文件；计数使用真正的 SQLite
聚合、按当前模型／预览策略及 geography 身份筛选，不读取／JSON 解码全库向量。
孤立地点通过精确键 **`EXCEPT` 差集＋`IN` 删除**清理，替代相关子查询反复扫描。
完整授权快照、失效记录清理、首次约 **15 MB** 地点边界包解析及 resolver 复用保留；
搜索仍完整准备、读取／验证向量并前后复查授权。**首次搜索加载是延后、不是取消**；
元数据计数不是向量健康扫描，坏向量可能被计数并显示就绪，但搜索仍按原校验报错。

UI／AppState／Photos、模型权重、输入／缓存策略、排名及 20 worker／并发不变；不增加全库内存索引，
不改计时器／后台机制，不声称彻底跳过检查、零等待或手机耗时改善。详见 [STARTUP_REFRESH.md](STARTUP_REFRESH.md)。
用原 Sideloadly Apple 账号／有效 Bundle ID **覆盖安装，不卸载、不清索引、不必 Index / resume**；
build 10+ 当前策略有效图像／地点索引及就绪语言包直接沿用。
**PENDING-DEVICE**：build 14 安装、真实图库行为与启动／首搜耗时未获真机验证。
CI／计费、公开范围与项目许可证不变，第三方再分发审查仍待完成；未跟踪研究／原型仍仅本地保留、未暂存。

## 历史：0.5.0 (build 13) — COMPLETED / SUCCESS；公开发布、本地 IPA 与 CRC 校验完成

以下保留 build 13 当时结果；“本轮／当前”等仅指该历史版本，当前交付以页首为准。

[Run 36540269511](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36540269511)
／[job 109313762175](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36540269511/job/109313762175)，
源码 **`158c3bf661efcc688ecbe313a4f5c52a3271d803`**，最终 **COMPLETED / SUCCESS**。
**PASS-NATIVE／PASS-PACKAGE／DELIVERED**；此前“run ID 未知／待验证／无新包”检查点已被取代。

### 本轮验证账本：36540269511

| 项目 | 本轮结果／边界 |
| --- | --- |
| Swift 核心 | 79 通过。 |
| App XCTest | 377 项：376 通过、1 项既有真机文件保护模拟器跳过、0 失败；214.296 秒，wall 264.142 秒。 |
| `IQStyleTests` | 6 全通过；0.040 秒。 |
| `PresentationTests` | 17 全通过；3.178 秒。 |
| `GeneratedModelParityTests` | 8 全通过；144.833 秒。真实 20 actor 工厂 120 次预测／252 项测量，原 23 次预测／58 项测量及门槛均保留。 |
| 独立 UI | 10 全通过；545.341 秒。 |
| `PresentationNavigationTests` | 5 全通过；300.442 秒。 |
| `SearchKeyboardTests` | 5 全通过；244.899 秒，含新增键盘→底部图库→返回回归。 |
| 设备构建／包 | BUILD SUCCEEDED；0.5.0 / 13、arm64 Release、未签名、iphoneos18.5 SDK、Xcode 16.4、最低 iOS 17.0。 |
| 公开发布 | Release 398951411／ci-36540269511-1；2026-09-29T08:30:53Z，prerelease、draft: false、非 Latest；9 项资产已核验。 |
| 本地 IPA | 完整流式下载，父流程已核验实际长度／SHA-256；`ipaVerifiedLocally: true`。 |
| 额外归档检查 | 7-Zip 26.03 `t` 全量解压／CRC PASS，Exit 0，`Everything is Ok`；10 文件夹、24 文件，解压后 1,559,424,855 字节，压缩包 1,414,830,691 字节。 |

App 子套件已计入 377 项，UI 子套件已计入 10 项，不重复相加；耗时不是手机性能。
没有新增跳过、放宽数值／语义断言、测试等待时间或点击坐标。归档检查**不验证 Sideloadly
重打包／签名后的 IPA，也不验证手机安装或实际运行**。

### 本轮资产身份与本地证据

- [公开 Release：ci-36540269511-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36540269511-1)
  无需 GitHub 登录。IPA asset **597693809**，**1,414,830,691 字节**，SHA-256：
  `d5ebe9881bc596f8c45b29cfdf5ed986b07e665e3a46fdf691dd09bb52a3db31`。
- [../build/device-download/36540269511/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36540269511/LocalImageIQ-iphoneos-unsigned.ipa)
  已实际全量下载并本地核验，不是只读取远端 digest／清单。配套文件齐全：
  [../build/device-download/36540269511/device-build.json](../build/device-download/36540269511/device-build.json)、
  [../build/device-download/36540269511/SHA256SUMS.txt](../build/device-download/36540269511/SHA256SUMS.txt)、
  [../build/device-download/36540269511/delivery.json](../build/device-download/36540269511/delivery.json)、
  [../build/device-download/36540269511/release-fetch-7f2fdc96-50b8-4abb-9559-23083e023708.json](../build/device-download/36540269511/release-fetch-7f2fdc96-50b8-4abb-9559-23083e023708.json)。
- [../build/ui-review/36540269511/UIReview.zip](../build/ui-review/36540269511/UIReview.zip)
  已下载并校验；asset **597693697**，**3,719,566 字节**，SHA-256：
  `610189d2dabacda04fb910818f948e974d41b1973d9868d82dd4d2957bc70fe8`。

### 本轮有限视觉审核：实际两张联系图，共 12 张原图

父流程已实际查看以下两张联系图，所含原图均 **393×852**；不是只下载未查看。

| 联系图 | 已查看场景 |
| --- | --- |
| [青绿原生八图](../build/ui-review/36540269511/teal-native-contact.jpg)，1120×1280 | 未授权首页、就绪首页、三图网格、未授权图库，各浅／深色两张；网格为合成绘图。 |
| [用户模式四图](../build/ui-review/36540269511/user-mode-contact.jpg)，1340×758 | 深色设置底部调试 OFF（维护／隐私可见）、深色未授权图库（连接／iCloud 可见、索引禁用、无详情）、空查看器调试 OFF／ON（仅分享／三个入口，均禁用）。 |

导航“完成”现为青绿，普通照片错误文案中文；实际根界面自适应系统外观。
**本轮不声称查看了其他图片；合成／未授权场景不读取真实 Photos，不是真机或私人图库验证。**
系统键盘／分享语言跟随 OS，调试原始值可能英文，不声称完全本地化。

### 使用与剩余边界

统一双列 **4:5**／紧凑三列，间距 **6／4**，仅移除视觉排名徽标，结果顺序不变。
默认 **Top 3／地点权重 0.6**、20 worker、HQ224／Fast、模型、翻译、索引／缓存均不变；
build 10+ 当前策略有效索引与就绪语言包直接沿用。原 Sideloadly 账号／有效 Bundle ID
**覆盖安装，不卸载、不 Clear index、不重建图像／地点、不必 Index / resume**。

**PENDING-DEVICE**：build 13 尚未在物理 iPhone 验证安装、界面／外观切换、真实 Photos、
翻译及性能／文件保护。用户已确认 build 12 安装成功；此前短暂 `PackageExtractionFailed`
原因未知，不归因于存储空间。**PENDING-LICENSE-REVIEW**：第三方人工再分发审查仍未完成。
项目许可证、公开范围或计费不变；未跟踪的研究／原型含公共 Unsplash
示意图，**仍仅本地私存、未暂存，不宣称整个仓库干净**。界面契约见 [TEAL_UI.md](TEAL_UI.md)。

### 历史：B 首轮失败与第二轮最小修复

- 源码 `a2e23979c1de3f211deec07e05aedabb07c3ad60`，
  [Run 36537575789](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36537575789)
  ／[job 109305061689](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36537575789/job/109305061689)，
  **FAILED，仅 UI 失败**：核心 79 通过；App 377 项＝376 通过／1 项既有跳过／0 失败，
  208.655 秒；UI 10 项＝9 通过／1 失败，495.366 秒。6 项颜色、网格、新键盘／页脚及 Advanced 回归通过。
- 唯一失败为 `testOneGlobalDebug...` 首次点击 `open-library` 后未出现图库 sheet；
  失败视频 6 帧仍在首页。首轮设备构建跳过，draft **398929880／ci-36537575789-1**
  仅失败证据、无 IPA；不改写为成功。
- 第二轮源码仅补 `ContentView` 整行 `contentShape(Rectangle())` 和两个 sheet 的
  `NavigationStack` tint；**未改测试、等待时间或点击坐标**。本轮 UI 10/10 支持修复有效，
  但不把修复成功当成旧命中区域／AX 的直接因果证明；旧 Advanced 空 AX 树也不证明 ID 继承。

## 历史：0.4.1（build 12）— SUCCESS；公开 Release 与本地 IPA 已核验

以下保留 build 12 交付记录；“本轮／新包／当前”等仅指当时 build 12。当前交付状态以页首为准。

**2026-09-29 首次完成 build 12 交付（不是首次构建尝试）**：
[Run 36515068434](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434)
／[job 109235419277](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434/job/109235419277)，
源码 **`fac5e2d39d37730ccf45e2f8e0231124247d4cf8`**，已 **COMPLETED / SUCCESS**。
原生、设备编译／包验证、公开发布、本地 IPA 全量长度／SHA-256 核验均已完成：
**PASS-NATIVE／PASS-PACKAGE／DELIVERED**。此前的进行中检查点已由此最终结果取代。

### 本轮验证账本：36515068434

| 项目 | 本轮已核验结果／边界 |
| --- | --- |
| Swift 核心 | 79 通过。 |
| App XCTest | 370 项：369 通过、1 项既有真机文件保护测试在模拟器跳过、0 失败；测试 258.961 秒，wall 288.923 秒。 |
| `GeneratedModelParityTests` | 8 通过；170.094 秒。20 槽工厂 120 次预测／252 项测量与原 23／58 门槛保留，未放宽。 |
| `DebugToolsPresentationTests` | 7 通过；25.179 秒。原生布局／渲染检查，不冒充进程内 AX 语义证明。 |
| `DebugToolsStateTests` | 14 通过；1.055 秒。 |
| 独立 UI | 9 项全部通过；522.447 秒。 |
| `PresentationNavigationTests` | 5 通过；354.440 秒，包含此前失败的 `testClearQueryKeepsKeyboardAndSettingsAdvancedStartsCollapsed`。 |
| `SearchKeyboardTests` | 4 通过；168.007 秒。 |
| Advanced 回归 | 两次展开均在任何滚动前验证唯一 `location-weight`、无 `debug-advanced` ID 的 Slider、可点击且为 60%；收起、关闭调试、查询与 Top 12 保持不变的断言均通过。 |
| 设备构建／包 | BUILD SUCCEEDED；0.4.1 / 12、arm64 Release、iphoneos18.5 SDK、Xcode 16.4、最低 iOS 17.0、未签名；不是物理 iPhone 执行。 |
| 公开发布 | Release 398799791／ci-36515068434-1，2026-09-29T03:27:14Z；prerelease、draft: false、非 Latest，9 项资产已核验。 |
| 本地 IPA | 已完整流式下载，并由父流程直接核验实际长度／SHA-256；`ipaVerifiedLocally: true`，不是远端元数据代替本地验证。 |

App 子套件已计入 370 项，两个 UI 子套件已计入 9 项，不重复相加；这些耗时不是手机性能。
既有本地 Node 22 发布器 **94 项及源码检查 PASS** 是独立记录，不代替上述本轮原生结果。
没有削弱调试功能、语义断言或数值门槛，没有新增跳过测试或生产限制。

### 本轮公开资产与本地交付证据

- [公开 Release：ci-36515068434-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36515068434-1)
  **无需 GitHub 登录**，已核验 **9 项资产**。历史 build 11 Release 398009938 不是本轮新包，
  先前失败 drafts 也不是安装入口。
- [../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa)：
  IPA asset **597136564**，精确 **1,414,818,257 字节**，SHA-256：
  `840085413cee964c7de03fa4453f89db9691ec74f8165064e3d07e432ccec03c`。
  **全量下载和本地实际字节／哈希核验已完成**，不是待下载或只完成远端验证。
- 同目录已取得 [../build/device-download/36515068434/device-build.json](../build/device-download/36515068434/device-build.json)、
  [../build/device-download/36515068434/SHA256SUMS.txt](../build/device-download/36515068434/SHA256SUMS.txt)、
  [../build/device-download/36515068434/delivery.json](../build/device-download/36515068434/delivery.json) 及
  [../build/device-download/36515068434/release-fetch-9caa6072-3f04-4462-87e7-637fe1965817.json](../build/device-download/36515068434/release-fetch-9caa6072-3f04-4462-87e7-637fe1965817.json)，
  下载记录为 **`ipaVerifiedLocally: true`**。
- [../build/ui-review/36515068434/UIReview.zip](../build/ui-review/36515068434/UIReview.zip)
  已下载并校验；asset **597136471**，精确 **3,339,409 字节**，SHA-256：
  `9fb0be72629cb43efba8716a22411ca24fdb7bfb291d89e98a9e6e19eb9e43f3`。

### 本轮有限视觉审核：仅四张用户模式图

父流程已实际查看[本轮用户模式联系图](../build/ui-review/36515068434/user-mode-contact.jpg)
（**1340×758**），包含以下精确四场景，原图**各 393×852**：

| 场景 | 实际可见范围 |
| --- | --- |
| Settings 底部 | Show debug tools 为 OFF；Maintenance 与隐私说明仍可见。 |
| Library 未授权 | 连接 Photos 入口及 iCloud 控件可见；索引按钮禁用，无 Details。 |
| 空查看器、调试 OFF | 仅分享入口可见，且禁用。 |
| 空查看器、调试 ON | 分享、Photo Check、本地预览对比均可见，且禁用。 |

均为**合成空状态／未授权、不读取 Photos**的场景，不是私人图库或物理手机证据。
**不声称其他图像已审核，也不声称已核实 ZIP 内截图总数**。这次有限视觉审核与 UI 9/9
原生自动化是两种独立证据，不能互相替代或据此声称真机已验收。

### 历史 build 12：当时使用与验证边界

现在可用已校验的 build 12 IPA，以**原 Sideloadly Apple 账号／原有效 Bundle ID 覆盖安装**。
已有 build 11／10 当前策略有效索引和就绪语言包沿用；**不卸载、不 Clear index、不重建
图像／地点，也不必 Index / resume**，无需指定查询、诊断或截图。调试入口在
**Settings 最底部 → Show debug tools**，仅会话有效、重启默认 OFF；正常翻译保留。
20 worker、HQ224／Fast、模型、翻译引擎、索引策略及缓存身份均不变。

**PENDING-DEVICE**：用户已确认 build 12 安装成功；真实手机用户模式、系统翻译／语言包同意、离线
质量／延迟、20 槽稳定性、内存／发热、Photos／GPS 覆盖和文件保护仍待验证。
**PENDING-LICENSE-REVIEW**：模型／地点人工再分发审查未完成；公开发布不是法律认证。
正式分发的图标、正式 Bundle ID、签名及 TestFlight／商店配置仍是独立事项。

## 历史：转公开与交付前的公开运行（2026-09-28～29）

下表与调查记录保留此前实际失败，不将旧结果改写为本轮成功。曾经的进行中／无新包
检查点已失效，**当前交付状态以页首为准**。

用户明确批准**公开仓库＋免费标准 runner**，并再次确认历史作者邮箱／机器路径／测试
查询、Actions 日志及已发布 Releases 可公开。同一
[xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios)
已由 GitHub API 与匿名 GET 确认为 **PUBLIC／`private: false`**；不是仅修改文档的计划。
完整控制、费用与许可边界见 [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md)。

| 项目 | 历史证据／当时边界 |
| --- | --- |
| 公开范围 | 同一独立 iOS 仓库及既有历史、历史 Actions 日志、已发布 Releases；未重写历史、删除内容或改变企业 origin。 |
| 有限历史检查 | 277 个文本 blob，共 4,653,437 字节，最大 101,959 字节；检查范围内无 NUL 二进制、图像／数据库／模型 blob，未命中 .env、私钥、令牌、带凭据 URL 相关模式。有限模式扫描不是无秘密保证；已知邮箱、路径、查询已获准公开。本机 .git helper 未发布。 |
| 当时可下载的旧包 | Release 398009938／ci-36387878343-1 为已交付 0.4.0 / build 11，转公开后无需 GitHub 登录；不是 build 12。原身份、大小和哈希不变。 |
| 旧失败证据 | Draft 398051690／398066345 保持原状；仓库公开不自动发布草稿，不作为安装入口。 |
| 工程与不变项 | 仍为 0.4.1 / 12；引擎、模型、20 worker、HQ224／Fast、翻译、索引／缓存身份不因公开转换改变。 |
| 首轮公开运行源码（历史） | f553cd7285d62171ce1d9ccf0c1f84c8b43e2fb5；下述首轮结果不转记为新运行通过。 |
| 首轮公开手动运行 | [Run 36400923391](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36400923391)／[job 108858329166](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36400923391/job/108858329166)：COMPLETED / FAILURE，仅 1 项原生 UI 测试失败。公开路线计费启动阻塞已解除，原生 App／UI 确实执行。 |
| 首轮公开 App XCTest（历史） | 370 项：369 通过、1 项真机文件保护在模拟器跳过、0 失败；217.028 秒。 |
| 首轮公开调试子套件（历史） | `DebugToolsStateTests` 14 项、`DebugToolsPresentationTests` 7 项全部 PASS，已计入 App 总数；不补写未提供的子套件耗时。 |
| 首轮公开独立 UI（历史） | 9 项：8 通过、1 失败；514.171 秒。其他 8 项包括全局开关／重启均 PASS，开关本体点击修复已验证；唯一失败是第一次 Advanced 点击后的滑块查找，不证明未展开。 |
| 第二次公开运行（历史） | cfd2943cbec28bf02c1fe2597921cb12ffdec317；[Run 36403948150](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36403948150)／[job 108868075667](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36403948150/job/108868075667)：COMPLETED / FAILURE，仅 1 项 UI 滑块查找失败。 |
| 36403948150 核心／App（历史） | 核心 79 通过；App 370 项：369 通过、1 项真机文件保护模拟器跳过、0 失败；226.129 秒。 |
| 36403948150 App 子套件（历史） | `GeneratedModelParityTests` 8 通过／156.965 秒；`DebugToolsPresentationTests` 7 通过／18.836 秒；`DebugToolsStateTests` 14 通过／0.598 秒。均已计入 App 总数。 |
| 36403948150 独立 UI（历史） | 9 项：8 通过、1 失败；509.597 秒。仍为 `testClearQueryKeepsKeyboardAndSettingsAdvancedStartsCollapsed` 的 `location-weight` 查找失败。 |
| 第二次公开失败证据 | Release 398126220／tag ci-36403948150-1，DRAFT、6 项证据资产、无 IPA；不是成功发布或安装入口。 |
| 后续修复／当时检查点 | fac5e2d39d37730ccf45e2f8e0231124247d4cf8 的 Advanced 标签 ID 作用域修正＋语义点击曾在 36515068434 中等待验证；该进行中检查点已由页首 SUCCESS／实际 App 370 与 UI 9/9／已交付结果取代。 |
| 首轮公开失败证据（历史） | 发布步骤 SUCCESS；Release 398104580／tag ci-36400923391-1，DRAFT、6 项证据资产、无 IPA。预期 tag、清单、正文 run／target 与实际元数据一致。 |
| 当时设备与交付 | 36403948150 的设备构建因 UI 门槛失败 SKIPPED，当时无 0.4.1 IPA；旧 0.4.0 是当时可下载的交付物，不是现在唯一安装包。 |

### 历史假设与更正：查找失败不等于 Advanced 没展开

首轮公开 trace：**09:20:21** 开关本体归一化 **(0.9, 0.5)** 点击后值为 **1**；
**09:20:25 第一次**点击 `debug-advanced` 整行中心后，滑块 ID 查询失败，随后
**8 次上滑**仍失败。此前“第二次展开失败”的说法已更正为第一次点击后的查找失败。

历史提交 `cfd2943cbec28bf02c1fe2597921cb12ffdec317` 仅改测试：三次展开／收起均
点击尾部 **(0.95, 0.5)**，第二次展开前重取 header、保留全部断言；但旧运行 36403948150
仍失败。三次猜测失败后已停止，**用户于 2026-09-29 重新批准根因调查**，不是无限盲改。

首轮公开失败证据的 UI ZIP asset **595016915**，精确 **27,650,839 字节**，SHA-256：
`37a68bcc6b15da775230ce198525131a4d7e07aedf6115637d2e3f94b88c908b`。
已下载并校验至 [../build/ui-review/36400923391/UIReview.zip](../build/ui-review/36400923391/UIReview.zip)。
当时仅凭 trace 推断“未展开／箭头没点中”没有视觉依据；**以下最近失败视频已推翻该假设**。

### 历史直接视频证据、AX 边界与现已通过验证的最小修复

- 从旧运行 36403948150 的 UI ZIP **仅提取精确失败测试的视频**；父流程先看
  [视频总览联系图](../build/ui-review/36403948150/advanced-video-contact.jpg)，再看
  [110–113 秒六帧联系图](../build/ui-review/36403948150/advanced-tap-contact.jpg)。
  **111.5 秒 Advanced 确实已展开，60% 滑块可见**。此时测试的
  `app.sliders["location-weight"].exists` 却为 **false**，立即盲目上滑将滑块移出视口。
  这是该失败测试的直接视觉证据，不是真机、私人照片或新修复通过证明。
- 三个小 AX bplist 仅解出 `UIApplication`、`children=[]`，**没有足够滑块 ID 信息**；
  不能用空 children 证明无滑块，也不能证明 ID 被覆盖。
- 机制假设：`debug-advanced` 原先设在包裹 Slider 的**整个 `DisclosureGroup`** 上，
  可能发生 SwiftUI 无障碍 ID 继承。新提交只将标识移到 **`Text("Advanced")` 标签**；
  不改可见 UI 内容、排序或权重逻辑。父级 ID 传播是有力的机制假设，**旧空 AX 树没有
  直接证明继承**；修复通过不能追溯地把空树当作根因实测证据。
- 测试用语义 **`button.tap()`** 代替 Advanced 坐标猜测；**两次展开均在任何滚动前**
  等待滑块存在，并要求 `location-weight` 恰好一个、无 `debug-advanced` ID 的 Slider、
  可点击且值为 **60%**。失败附真实 `app.debugDescription`、全部滑块
  ID／label／value／frame 及截图；强化断言，不新增跳过、不放宽门槛、不加任意生产限制。
- 两文件提交 **`fac5e2d39d37730ccf45e2f8e0231124247d4cf8`** 已推送 `personal`，
  对应 **36515068434／job 109235419277** 最终 **COMPLETED / SUCCESS**。
  **标签作用域修正＋语义点击已通过本轮原生 UI 9/9 验证**；两次展开的强化断言、
  收起、关闭调试、查询和 Top 12 保持不变的检查均通过。完整本轮计数与耗时见页首。

测试耗时不是手机性能；App 子套件不重复相加。本页只链接小联系图，不链接大视频或私人照片。

## 当前构建与发布控制

- 只允许 `workflow_dispatch`，精确仓库名且 `private == false`，使用标准 `macos-15`；
  无付费 larger runner、self-hosted runner、自动 push／PR 或 fork 特权触发。
- 全局 `contents: read`；构建 job 的 `contents: write`／`actions: read` 可用于 Release，
  只使用 `GITHUB_TOKEN`，不用 PAT／Apple 凭据。保留全部源码、核心、地点、模型导出／
  数值对齐、App／UI、设备编译和包验证门槛，不跳过失败断言。
- 发布器在 preflight／prepublish 两处拒绝私有或错误仓库，要求明确公开；唯一 draft、
  白名单资产、身份／字节／SHA-256 核验、成功才发布非 Latest prerelease 的协议保留。
  文案标识 public CI，不声明第三方再分发已获许可。新交付不使用 Actions artifact 存储。
- 公开仓库标准 hosted runner 用量按 GitHub 规则免费，受平台政策、运行限制及可用性约束，
  不是无限额度保证；首轮公开 job **已实际完成原生 App／UI 执行**，公开路线的计费启动
  阻塞已解除，不等于账号旧限制已清除。
  **不重置旧私有分钟、累计存储用量或账号限制**。
  未修改计费、预算、卡片或付费限额，不要求付费以恢复此次构建。
- 用户选择不设置项目级许可证；第三方模型卡 Apache-2.0、geoBoundaries 许可元数据及
  Pillow MIT-CMU 源码头不改变项目整体授权。`redistributionApproved: false` 保留，
  人工再分发审查仍未完成。

当前 build 15 **36560321362／job 109379367704** 已 **首轮 COMPLETED / SUCCESS**；全部门槛、设备构建、
公开发布、本地 IPA 全量长度／SHA-256 及额外解压／CRC 核验完成；详细身份以页首为准。
旧运行 36403948150 的失败及失败证据 draft 保留，不追溯改写为成功发布。
安装入口见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。

## Historical checkpoint (2026-09-28, before public transition): 0.4.1 (12) — billing startup failure; NO IPA

以下历史账本保留原错误、测试、包身份与当时操作边界。其“当前 HEAD／私有／需登录／
先处理计费／不重试”只指对应旧阶段，不是现在的条件；当前路线以上方和
[PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md) 为准。公开不会使旧失败变成成功。

- **第三轮已结束但未启动 job**：
  [Run 36397742264](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264)
  ／[job 108848065780](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264/job/108848065780)，
  **COMPLETED / FAILURE；STARTUP / NOT STARTED；`steps: []`**。没有执行 App／UI 测试、
  设备构建或发布。准确 annotation：

  > The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the Billing & plans section in your settings

  只能确定为**账号付款／支出限额相关的启动阻塞**，不能区分付款失败还是预算／限额问题。
  **不是 Actions artifact 存储问题，不是 Release 发布器 bug**；不自动修改计费、
  不建议自动提高限额或增加支出、不索取凭据、不追加重试。

- **第二轮已结束**：`d2174787c1bd276c9bc38e6d6d2f1efe28ef0015` 已推送个人私有仓库
  `xwgnick/local-image-iq-ios`（`personal`）。
  [Run 36396468128](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36396468128)
  ／[job 108843930321](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36396468128/job/108843930321)
  已 **COMPLETED / FAILURE**，仅 2 项原生 UI 测试因同一整行点击未命中开关、等待 ON
  失败；App 全部通过（除既有 1 项真机文件保护模拟器跳过）。设备构建 **SKIPPED，无 IPA**。
  发布器**失败证据 draft 路径 SUCCEEDED**，不是普通成功 Release 或设备交付。
- **当前 HEAD／第三轮**：`70ad74b0f5e411ca60f741b1300545d1dbaf25c9` 已提交并推送，
  相比第二轮仅新增 UI 测试行内归一化 **(0.9, 0.5)** 点击修复；全部用户 App 代码与
  第二轮 App 测试通过的版本相同。坐标依据已捕获的实际行／开关本体位置，但**第三轮
  未启动，新点击修复未执行验证，不能声称全部 9 项 UI 通过**。App 370／UI 9 仅为
  待运行测试规模；第二轮不含这项点击修复。
- **首轮已结束**：源码 `2af11f6d759bcf7c021c20d73878cf4e5376dac4`，
  [Run 36394279080](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36394279080)
  ／[job 108836892722](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36394279080/job/108836892722)，
  **FAILED**。失败涉及展示测试的进程内 AX 读取、UI 测试点中整行标签而非开关本体，
  以及失败证据 Release 的身份检查，**不是 Actions 存储配额问题**。设备构建跳过，无 IPA。
- **实现范围**：全部调试界面由 Settings 底部唯一 **Show debug tools** 开关控制，
  每次启动 OFF、仅会话有效。`AppState` 标志及检查执行入口守卫、查看器 `onReceive`
  实时响应均纳入；可选状态的旧调用无 `AppState` 时不显示调试。关闭收起照片检查／
  本地比较 sheet，清除报告／问题，弱引用注册的活动预览取消；不取消索引／搜索／
  语言包准备，不改变查询／结果／权重／模型／缓存。普通功能与完整边界见
  [USER_MODE.md](USER_MODE.md)，不是全 App 本地化重做。
- **兼容性**：索引 API、模型、Photos 取图、翻译引擎无改动；20 worker、HQ224／Fast
  及缓存身份不变。0.4.0 或 0.3.4 已有当前策略有效索引无需迁移、清库或重建。
- **交付契约不变**：同一私有 Release，不用 Actions artifact 存储；全局
  `contents: read`，job `contents: write`／`actions: read`，不增加权限／凭据。
  build 12 **未交付**，尚无设备编译成功、新 IPA 或本地下载校验证据；下方 build 11 包
  及哈希仅是历史身份。首轮预期 tag `ci-36394279080-1` 不是有效安装入口。

### 首轮验证账本：36394279080／2af11f6d

以下仅为首轮实际结果，不转记为修复源码通过；App 子套件已计入 370 项，耗时不是手机性能。

| 项目 | 首轮已知结果／边界 |
| --- | --- |
| 原生 App XCTest | 370 项、1 跳过；25 个断言失败全部来自 7 项 `DebugToolsPresentationTests`，不是 25 项测试失败；原生测试失败。 |
| `DebugToolsStateTests` | 14 项全部通过，0.140 秒。 |
| 展示失败原因 | 进程内 AX 读取对全部元素都返回零，包括普通控件；不能把这种读取失败当成调试门控隐藏了正常界面的证据。 |
| 独立 UI | 9 项中 2 项失败、7 项通过；`row.tap()` 点中整行中心的标签区域而非右侧开关，两项点击后值均为 0，等待 ON 失败。此前“视口移动”根因猜测已撤回。 |
| 其他回归 | 其余回归通过；不补写未提供的单项计数、耗时或数值极值。 |
| 设备构建／IPA | 设备构建 SKIPPED；无 build 12 IPA，不是已编译但未下载的设备包。 |
| 失败证据上传 | 6 项资产已上传并核验至 Release 398051690；后续身份检查失败，无 IPA、未交付。 |

### 首轮 UI 根因更正：整行中心不是开关本体

父流程已下载并校验既有首轮失败 UI ZIP：asset **594867187**，**28,595,052 字节**，
SHA-256：`6e38218ebb4d0d59eddcb4668c319f8337a5b027aacce99b7beabbf826e10082`。
**当时仅读取两份 debugDescription 文本，没有查看图片**。

- AX 中 `show-debug-tools` 对应**整行**：x **20**、y **730.3**、宽 **362**、高 **44**。
- 右侧实际开关本体是另一个元素：x **313**、y **737**、宽 **51**、高 **31**。
- `row.tap()` 点整行中心，即约 **(201, 752.3)**，落在标签区域，不在开关本体内；
  两项失败测试点击后值都仍为 **0**，并非已经开启后因 Form 插入行而丢失 ON 状态。
- 因此撤回此前“视口移动导致失败”的根因猜测。首轮 `AppState` 相关的 14 项
  `DebugToolsStateTests` 已全部通过，**未观察到生产开关失效**；不据此宣称真机已验证。

当前 HEAD 已提交／推送**一处 UI 测试点击修复**：在已识别整行内点击归一化坐标
**(0.9, 0.5)**，该位置命中右侧开关本体。原有滚动／重新获取元素／等待值的处理仍保留，
无需撤回；但它本身不能修复点中标签的问题。**第二轮不含新点击修复，仍有相同的两项
UI 失败；第三轮已因账号计费阻塞在启动前失败，当时新修复尚未执行验证**。

### 首轮 Release 异常：资产已核验，但严格身份检查失败

首轮失败证据 Release ID **398051690** 的 **6 项资产上传／核验已完成**。随后更新
draft 状态的 PATCH **未显式传入 tag**，触发 GitHub 对未发布 Release 的行为：
`tag_name` 变为 **`untaged-e8f3a293686e58364ecc`**，不再匹配预期的
`ci-36394279080-1`。实际 API 回读为 **`draft: true`、无 IPA**。

原发布器日志状态为 **`unknown`**，原因是严格身份检查失败；不能因此把已回读的
draft 状态说成未知，也不能把六项证据上传说成成功发布。该问题**不是 Actions 配额**。
修复源码已推送不代表这个既有 draft 已修复或发布；该旧 draft 保留原状。

第二轮**失败证据 draft 路径已 SUCCEEDED**，显式 tag 修复已在线上这条路径验证，
首轮发布器 bug 已解决；不代表首轮既有 draft 被追溯修复，也不是普通成功 Release 发布。

### 第二轮已验证的修复与结果（不含当前 HEAD 的点击修复）

- **原生展示测试**：改用公开 UIKit 的真实行布局、渲染像素非空白及同一 host 的
  **OFF → ON → OFF** 稳定性检查。不再依赖首轮全零的进程内 AX 读取；这些断言只
  证明原生视觉行为，**不声称验证了 AX 语义，也不表示 App 没有 AX**。这是测试方法
  的边界；真实 Settings／Library 的语义断言仍由跨进程 XCUI 明确覆盖，未删除或削弱。
- **UI 测试**：保留滚动／视口变化后重新获取开关并等待目标值的处理，不复用变化前
  的元素；仍验证 ON／OFF、普通控件、调试项及重启后的会话重置。这不是首轮点击
  位置根因的修复；行内 **(0.9, 0.5)** 点击改动已提交／推送，**不属于第二轮**。
- **唯一 App 运行时修正**：查看器 Combine 订阅忽略未变化的值，避免重复订阅回放
  引发反复清空 nil 的反馈，令响应幂等。正常看图、搜索、索引逻辑没有改动；核心、
  模型、翻译及缓存身份不变。
- **发布器**：自己发起的每次 PATCH 均显式携带 `tag_name`（`run.tag`）及
  `target_commitish`（运行源码 SHA），保留严格 tag／SHA 身份检查，不接受错 tag
  作为成功。模拟上述真实 GitHub 行为的回归已加入，本地 **88 项 Node 测试 PASS**
  （此前 **83**）；第二轮另已验证线上失败证据 draft 路径成功，不以 mock 替代线上证据，
  不将该路径成功说成普通成功 Release 发布。

| 第二轮项目 | 实际结果／边界 |
| --- | --- |
| 源码／运行 | d2174787c1bd276c9bc38e6d6d2f1efe28ef0015；run 36396468128／job 108843930321，COMPLETED / FAILURE；仅两项原生 UI 失败，不含当前 HEAD 的点击修复。 |
| App XCTest | 370 项：369 通过、1 项真机文件保护在模拟器跳过、0 失败；130.279 秒。 |
| `DebugToolsPresentationTests` | 7 项全部通过，已计入 App 总数；本轮精确耗时未提供，不补写。 |
| `DebugToolsStateTests` | 14 项全部通过，已计入 App 总数；本轮精确耗时未提供，不沿用首轮 0.140 秒。 |
| 独立 UI | 9 项：7 通过、2 失败；319.699 秒。两项仍是整行点击未命中开关，等待 ON 失败，与首轮同一根因。 |
| 原生与跨进程语义 | 原生视觉验证通过不等于 XCUI 语义验证全部通过；语义断言仍保留。默认 Settings 仍滚动检查普通控件，单一视口只有一个 Show debug tools 开关，不声称整页只有一个开关。 |
| 数值门槛 | 真实 20 槽工厂 120 次预测／252 项测量和旧 23／58 全部保留、未削弱；包含在已通过 App 测试中，不补写未提供的子套件耗时或数值极值。 |
| 失败证据发布器 | 步骤 SUCCESS；Release 398066345／tag ci-36396468128-1 仍为 DRAFT、无 IPA。显式 tag 修复在失败证据路径有效，首轮发布器 bug 已解决；不是普通成功 Release 发布。 |
| 截图 | UI ZIP 已下载并校验；仅提取四张用户模式合成图，父流程已实际查看 1340×758 联系图，范围及边界见下文。 |
| 设备／交付 | 设备构建 SKIPPED，无 build 12 IPA；未交付／未完成本地校验，真机验证待完成。 |

App 子套件不重复相加，测试耗时不是手机性能。**未削弱调试功能、语义断言或数值门槛，
未新增跳过测试**；唯一既有跳过仍是真机文件保护的模拟器限制。

### 第二轮失败证据与有限视觉审核：36396468128

第二轮 **Release 398066345／tag `ci-36396468128-1`** 保留为 **DRAFT、无 IPA**，
发布器步骤 **SUCCESS**；这是已保存的失败证据，不是安装入口，也不修复首轮旧 draft。
UI ZIP asset **594909127**，精确 **32,920,094 字节**，SHA-256：
`59e77bd362d1ed25a38b5c06a2b11df2f512b09e2c52b09eeed6e0031c4530d7`。
已下载并校验至 [../build/ui-review/36396468128/UIReview.zip](../build/ui-review/36396468128/UIReview.zip)。

仅提取以下四张 `UIReview-user-mode-*` 图，父流程已实际查看
[1340×758 联系图](../build/ui-review/36396468128/user-mode-contact.jpg)：

| 已审核附件名 | 实际可见范围 |
| --- | --- |
| UIReview-user-mode-settings-default | Settings 底部 Show debug tools 为 OFF；Maintenance 与隐私说明仍可见。 |
| UIReview-user-mode-library-default | 连接 Photos 入口及 iCloud 控件可见，索引按钮禁用；没有 Details。 |
| UIReview-user-mode-viewer-default | 空查看器、调试 OFF；仅分享入口可见。 |
| UIReview-user-mode-viewer-debug | 空查看器、调试 ON；分享、照片检查、本地预览对比三入口均可见且禁用。 |

这是合成空状态／未授权场景，空查看器不读取 Photos；**不是私人照片、真实图库或真机
证据，也不能证明开关语义点击成功**。其他 ZIP 图片未查看，不声称总数或全部审核。
当前 HEAD 只改 UI 测试，App 源码与第二轮相同，因此上述有限视觉结论适用于当前 App
的相同场景，**不是第三轮的新产物或新运行验证**，也不代替待验证的 9 项 UI 测试。

### 历史第三轮结论与当时操作边界：启动前失败，不重试

当前 HEAD **70ad74b0f5e411ca60f741b1300545d1dbaf25c9** 的第三轮
**36397742264／108848065780** 已 **COMPLETED / FAILURE**。先前 dispatch 的 HTTP 204
仅表示请求被接受；最终 job 未启动、`steps: []`。App **370**／UI **9** 均未执行，
没有设备构建、IPA 或发布步骤结果，不能把第二轮通过项记成第三轮通过。

账号所有者需要手动查看 GitHub **Settings → Billing & plans** 的付款及支出限额状态；
当前不代改计费、不追加重试、不要求提供任何凭据。继续使用已有 **0.4.0 / build 11**，
不安装新版。只有计费阻塞解决、后续新运行通过测试和设备构建，才进入既有私有 Release
上传、新 IPA 下载及长度／SHA-256 核验；这些是后续交付条件，**不是已启动任务或交付承诺**。
核验完成后按 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md) 覆盖更新；正常行为、
20 worker、翻译、模型及索引策略不变，已有当前策略索引不清库、不重建、不必 Index / resume。

## Historical: 0.4.0 (11) — SUCCESS; private Release published, local IPA verified

以下保留 build 11 的完整历史；“本轮／新包／现在”只指对应旧版本。其测试、截图、
Release 与本地 IPA 校验均不能作为 build 12 的结果，当前状态以上方为准。

用户现已明确批准**方案 2：同一私有仓库 Release＋job 级 contents: write**，不改公开
可见性或计费。新源码 **`844492b754f86d519c904da21cd80c1c814c056b`** 相比已通过
原生／设备验证的 `0c09c46ff5edf74ffeb4a2cece2f7b9fd20a5910`，仅修改
[工作流](../.github/workflows/ios.yml)、[发布器](../scripts/publish_release.mjs)和
[发布器测试](../scripts/test_publish_release.mjs)，没有 App／索引／模型改动。

- **本轮完成**：
  [Run 36387878343](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343)
  ／[job 108817040032](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343/job/108817040032)，
  源码为上述 `844492b754f86d519c904da21cd80c1c814c056b`，已 **COMPLETED / SUCCESS**。
  实际 `TEST SUCCEEDED`、iPhoneOS `BUILD SUCCEEDED` 和包验证通过；这是**两次 Actions
  artifact 配额失败后的首次私有 Release 尝试成功**，不是 build 11 总体首轮成功。
- **实际发布身份**：[ci-36387878343-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)，
  Release ID **398009938**，发布于 **2026-09-28T06:55:36Z**；**prerelease、非 draft、非 Latest**。
  仓库仍私有，**9 项资产＝8 项载荷＋交付清单**全部上传并通过 API SHA-256 核验。
  新 IPA 已全量下载及父进程直接流式复验，**DELIVERED，仍须本机签名**。
- **发布器验证**：本地 **83 项 Node mock 测试全部通过，CI 对应步骤也 PASS**；本轮真实
  上传／发布和下载已另行核验，不用 mock 代替线上证据。使用官方 SHA-256
  已核验的 Node **22.23.3**；系统 Node **18.0** 的初次测试因缺少 `t.after` 失败，
  属运行时不兼容，不是发布器代码失败。工作流使用 Node 22。
- **新交付契约**：精确私有仓库 guard，全局 `contents: read`，构建 job
  `contents: write`／`actions: read`，仅用运行自带 token，无 PAT／Apple 凭据。
  原生门槛全保留；唯一 DRAFT → 白名单流式上传／远端字节和哈希验证 → prerelease，
  不设为 Latest，不覆盖／删除既有 Release、tag 或资产。上游失败仅 DRAFT 证据、无
  App 包；部分上传不是交付。详见 [PRIVATE_RELEASE_DELIVERY.md](PRIVATE_RELEASE_DELIVERY.md)。
- 新交付不占 Actions artifact 存储配额；计费设置不动，macOS 分钟仍按原规则计量，
  不承诺免费。**只是交付路线改变，不声称 Actions 配额恢复**。

### 本轮实际测试与交付（36387878343）

以下是本轮结果，不借用前两轮；App 子套件已计入 349 项，不重复相加，耗时不是手机性能。

| 项目 | 本轮已核验结果 |
| --- | --- |
| Swift 核心 | 79 通过。 |
| App XCTest | 349 项：348 通过、1 项真机文件保护在模拟器跳过、0 失败；108.139 秒。 |
| `AppleQueryTranslationBridgeTests` | 32 通过；0.310 秒。 |
| `QueryTranslationStateTests` | 42 通过；0.404 秒。 |
| `QueryTranslationPresentationTests` | 5 通过；0.438 秒；不是按钮 UI 自动化。 |
| `GeneratedModelParityTests` | 8 通过；81.423 秒。真实 20 槽工厂完成 120 次预测／240 项归一化比较＋12 项张量测量＝252 项；原 23 次预测／58 项测量同样通过，门槛未改。 |
| 独立 UI 测试 | 7 通过；199.344 秒。 |
| 原生／设备构建、发布 | TEST SUCCEEDED、BUILD SUCCEEDED；包验证通过，9 项 Release 资产全部上传并通过 API SHA-256 核验。 |

### 本轮设备包身份与已完成的本地复验

- **0.4.0 / build 11、iphoneos18.5、arm64 Release、未签名、Xcode 16.4、最低 iOS 17.0**；
  真机专用翻译分支已编译，但不是物理 iPhone 运行证据。
- 同一 FP32／**768 维 SigLIP 2**，`modelVersion`：
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。
  Places **2,943 要素／15,175,079 GeoJSON 字节**；GeoJSON SHA-256：
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`；地点清单 SHA-256：
  `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`。
- [../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa)
  已完整下载；asset **594739443**，**1,414,801,288 字节**，SHA-256：
  `6043afbe68a84edd16d1314ecf4369f308bff8d7cf676392aee5eee6a950ca71`。
  **不是第二轮 runner 的 1,414,801,289 字节／fc449b… 包**。
- 同目录的 [device-build.json](../build/device-download/36387878343/device-build.json)、
  [SHA256SUMS.txt](../build/device-download/36387878343/SHA256SUMS.txt)、
  [delivery.json](../build/device-download/36387878343/delivery.json) 和
  [release-fetch-01b7433e-9d24-4c51-98ff-c2ccee92aa04.json](../build/device-download/36387878343/release-fetch-01b7433e-9d24-4c51-98ff-c2ccee92aa04.json)
  均已取得；下载记录 `ipaVerifiedLocally: true`。父进程已直接流式复验实际长度／SHA-256
  一致，**不是只读取远端声明或等待复验**；无部分下载残留，所有旧本地包保留。

| 其他已核验资产 | asset ID | 精确字节数 | SHA-256 | 本地状态 |
| --- | --- | --- | --- | --- |
| 交付清单 | 594740544 | 3,751 | `4ac2e94ae8ae173d1dd4c42894cbd5ff5fed7e131e52f245b2923fcf76e17aa3` | 已下载并校验；不是地点清单。 |
| UI 截图 ZIP | 594739319 | 3,116,697 | `dddc29df265e55276ffa5dd66c4ae18de7ad53b9fbc2d51716382baa2a6f2942` | 已下载并校验，仅提取／审核四张新增翻译图。 |
| 测试结果 ZIP | 594739346 | 5,336,413 | 远端 API SHA-256 已核验，本页不补写未提供的值。 | 仅远端上传／验证，未下载。 |

另一台电脑可登录 **xwgnick 或具有该私有仓库读取权限的账号**，从上述 Release 获取
同一 IPA 并核验；不是公开下载。安装步骤见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。

### 前两轮历史：真实配额错误，不是新 Release 路线的结果

- **首轮**：源码 `7b63e3539cdd34a2c7593b5f3431775af72e2dda`，
  [Run 36382669765](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36382669765)
  ／[job 108801470042](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36382669765/job/108801470042)
  最终 **FAILED**。失败步骤仅 **Upload UI／Keep evidence**，均为产物存储配额问题；
  不是原生测试失败。错误：`Failed to CreateArtifact: Artifact storage quota has been hit.`
  GitHub 提示用量每 **6–12 小时**重新计算。
- **第二轮源码**：`0c09c46ff5edf74ffeb4a2cece2f7b9fd20a5910`，补充准确的语言包竞态
  UI 提示，并将设备构建移到**首次 artifact 上传之前**；没有跳过测试或放宽门槛，
  版本仍为 **0.4.0 / build 11**。
- **第二轮最终结果**：个人仓库 `xwgnick/local-image-iq-ios`（`personal`）的
  [Run 36383757627](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36383757627)
  ／[job 108804722901](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36383757627/job/108804722901)
  已 **COMPLETED / FAILURE**。原生 `TEST SUCCEEDED`、iPhoneOS `BUILD SUCCEEDED`、
  包验证 **SUCCESS**；仅 **Upload UI／Keep evidence** 两项因同一 artifact 配额失败。
  **IPA 上传因 UI 上传失败而 SKIPPED**，不是设备构建或打包失败。
- **第二轮 BLOCKED-DELIVERY**：artifacts API 返回 `[]`。设备报告／IPA 身份仅来自 **job 日志中的
  runner 本地产物**，没有上传产物 ID，没有本地新 IPA／下载后报告／完整下载校验；
  UI 截图也未取回或视觉审核。该实际阻塞促成了后续已获批的私有 Release 路线。

### build 11 翻译实现与不变项（新交付提交未改 App）

- 系统翻译仅 **iOS 18+ 真机**，iOS 17／模拟器不支持时用原文；最低系统仍 17。
  本轮设备报告确认 **Xcode 16.4／iphoneos18.5、arm64 Release、未签名**；真机专用
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
  不打进 IPA；本轮 IPA 实测 **1,414,801,288 字节**，约 **1.4 GB**，语言包大小未测量。

### build 11 前两轮历史验证账本

以下仅为前两轮历史；本轮 **36387878343／844492b** 的实际通过与交付证据见上，
不把下表结果记作本轮结果。
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
  新包／本地报告链接，也不假定 runner 结束后仍能取回该包。以上仅为第二轮历史身份，
  **不得用作 844492b 新运行的包身份或下载校验值**。

### 截图与系统翻译的证据边界

状态／展示使用假服务；桥接测试覆盖真实服务的 **session-free** continuation／host
交接，不调用真实系统翻译。展示测试托管真实 SwiftUI 视图、假翻译／零照片结果并加
TEST 水印，仍构造 Photos 包装并读授权，不是零 PhotoKit API；模拟器若已有读照片
权限等条件不符可跳过，前两轮与本轮这五项实际均通过，**不是按钮 UI 自动化**。
本轮截图 ZIP 已下载并校验；仅提取以下**四张新增附件**并实际查看
[1340×758 联系图](../build/ui-review/36387878343/query-translation-contact.jpg)。
其他图像未提取／查看，ZIP 中截图总数未核实。

| 已审核附件名 | 场景 | 实际可见范围 |
| --- | --- | --- |
| UIReview-query-translation-translated | 普通翻译态，393×852 | 原中文、实际有效英文及“使用原文”可读。 |
| UIReview-query-translation-missing-pack | 缺包回退，393×852 | 回退提示及设置入口可见。 |
| UIReview-query-translation-settings-language-pack | Settings，393×852 | 四个控件可见；页脚在屏内且可读，排版较密。 |
| UIReview-query-translation-translated-accessibility-large | 大字号，375×667 | 原文、英文及“使用原文”可见；下方空状态延伸到视口外，不是整页可见性证明。 |

前两轮图像仍未取回／审核，不能用本轮审核改写历史。没有实际点击／滚动验收，
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

**授权更新**：此前“实际阻塞后再商讨”的阶段已结束；用户现已明确批准同仓库私有
Release 及上述 job 写权限，首次 Release 尝试已成功交付。**不包含公开仓库、计费修改或进一步
删除授权**；其余旧产物、其他仓库及本地备份不动。旧 Actions artifacts 是历史证据，
不是未来交付路线；本次并未因文档更新再触发 CI 或执行下载。

### 历史 build 11 当时的操作：使用已校验 IPA 签名安装

**新包已完整下载并复验，可用于本机签名**。用上方本地 IPA 或私有 Release 同一包，原 Sideloadly
账号／有效 Bundle ID 覆盖安装；已有 build 10 当前策略索引不卸载、不清库、不重建。
Settings → 中文搜索增强 → 简体中文 → 英文 → 下载离线语言包并同意，确认就绪后搜索
身份证，对比实际英文与“使用原文”，不保证译为 “ID card” 或提升效果；
可选下载后关闭全部网络验证该手机当次离线行为。
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

### 历史 build 10 源码实现与未改变的边界

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

### 历史验证账本：build 10 实际执行结果

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
这只是可能解释，未确认全部警告原因，也不是生产 drain 失败证据。
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
complete. Physical-phone performance remains unmeasured.

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
| Windows local Node checks | Reported PASS; not native proof. |
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
| User-side signing/install; physical-phone speed, memory/heat, file protection and GPS coverage | PENDING-DEVICE — no phone result; no additional diagnostic task required. |
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
not build 6.

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
  device App and IPA resource gates passed.
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
| Python static checks | 30 passed, reported for this change. Static checks are not model export or native parity. |
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