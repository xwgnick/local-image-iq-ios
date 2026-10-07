# Local Image IQ · Native iOS

SwiftUI + PhotoKit + Core ML + 系统 Vision。独立原生 App，以本机检索为主，不是桌面网页套壳。

## 当前交付：0.11.0 / build 30

**DELIVERED：已实现确认的双主功能布局、文字开关、0.80阈值设置与首次自动分组／结果复用。**最终源码 `911337669b8645d8829356d66062aac98e0dd0bd`，[CI 37613875842](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37613875842)／[job 112767437741](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37613875842/job/112767437741) SUCCESS。原生、设备构建和本地包校验完成，真机体验仍待验证。

- 底部 **照片搜索 / 相似清理** 同级大入口，默认搜索；切页保留已完成结果、草稿与滚动位置。隐藏页及弹层背后的控件不会继续暴露在辅助功能树中。
- 搜索框下“筛选”旁的 **照片文字** 开关，右侧精确说明 **“用照片里的文字进行搜索”**。开关默认OFF、持久保存；开启不自动OCR，建立／更新文字索引仍需用户另行点击。
- 清理滑杆仅在设置，默认 **0.80**、范围0.50–0.99，偏好持久保存；修改只提示手动重新分组，不自动扫描。
- 首次进入清理且已具备权限、图片索引及模型就绪条件时自动分组一次；之后复用完成结果（包括零组）。重启后核验本机派生缓存再恢复，不重新算照片对。相关照片／授权／阈值／索引内容变化时提示手动更新，不只比较数量。
- 恢复仍有元数据和源图片向量BLOB指纹读取，**不是瞬时／零I/O承诺**；不推理、不读取照片像素、不自动建立图片或文字索引。新照片需先手动更新图片索引，才能参与分组。

**最终安装包：**[build/device-download/37613875842/LocalImageIQ-0.11.0-build30-iphoneos-unsigned.ipa](build/device-download/37613875842/LocalImageIQ-0.11.0-build30-iphoneos-unsigned.ipa) · [公开 Release ci-37613875842-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37613875842-1)。**1,419,516,143 bytes**；全文件SHA-256 `ce60322197c84855c19e10687c8e388f6a208a6a7b794a887318fcab9b44131b`；7-Zip26.04全量CRC通过。

最终 **Core79、App1439（1438通过／1既有SQLite跳过）、UI14全部通过**。新增143项App测试；共四轮原生验证，含真实隐藏页／弹层AX缺陷修复及错误工具栏测试测量修正，不声称首轮成功。完整账本与恢复成本见 [docs/PRIMARY_NAVIGATION_GROUP_REUSE.md](docs/PRIMARY_NAVIGATION_GROUP_REUSE.md)。已实际查看 [四张原生主界面预览](build/ui-review/37613875842/primary-navigation-review.jpg)：搜索OFF／ON、清理及设置；合成统计和无权限占位不是私人照片或真实分组准确率证据，也不宣称与HTML效果图逐像素一致。

沿用原Sideloadly账号／有效Bundle ID覆盖安装，**不卸载、不清索引、不重建**。模型／索引／OCR身份、搜索两列与12张分页、清理五列、明确选择并确认后的系统删除及B02启动保持。真实iPhone恢复耗时、内存和系统删除尚未验收。

## 上版交付记录：0.10.0 / build 29

**DELIVERED：组总览、五列组内浏览、滑动多选及删除恢复提醒已完成原生构建、发布和本地校验。**最终源码 `2d3d9f86131d1134e8c91b215122b0c38e711262`，[CI 37557999448](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37557999448)／[job 112588591510](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37557999448/job/112588591510) SUCCESS；真机触摸体验、帧率与实际删除仍待验证。

- **紧凑组总览**：每组最多30张均匀抽样小图、10列／最多3行，标明全部数量。它只是封面，**不限制组内照片数**；首组有几百张也不会全部展开挤走后续组。
- **点小图放大进入对应组并定位**：已加载图片以固定栅格作缩放，未加载时直接定位；组内每排5张方形照片、2pt间距。标题按实际内容高度占位，不再留大块空白。返回总览保留滚动位置，目前返回没有反向缩放。
- **滑动多选**：组内点“选择”，横向起拖连续勾选或取消，支持跨行、回拖和上下边缘自动滚动；纵向起拖仍滚动。松手后一次离开主线程的批量核验再提交，其他组选择保留；不会自动删除或留一张。
- **30天恢复说明已先核实Apple官方文档**：普通删除通常进入系统“照片”的“最近删除”，可在30天内恢复；提前永久删除不可恢复，共享图库仅添加者能恢复，期限以系统显示为准。确认前、成功后均提醒，不能替代备份或视为本App撤销保证。
- 最终 **Core79、App1296（1295通过／1既有SQLite跳过）、UI14全部通过**；新增58项App测试，含300张大组、缩放／请求隔离、连续选择及原生标题布局。整体8轮、其中第5和第8轮成功；第5轮审图后再修标题空白，前期失败与修正完整保留于 [docs/SIMILAR_GROUP_BROWSER.md](docs/SIMILAR_GROUP_BROWSER.md)，不声称首轮成功或全部仅修测试。

**最终安装包：**[build/device-download/37557999448/LocalImageIQ-0.10.0-build29-iphoneos-unsigned.ipa](build/device-download/37557999448/LocalImageIQ-0.10.0-build29-iphoneos-unsigned.ipa) · [公开 Release ci-37557999448-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37557999448-1)。**1,419,369,106 bytes**；实际全文件SHA-256 `ff67a694d6f0393dc7c4bf1e8f4661c26b73885cc3613a68dd9291dd6510425f`，7-Zip26.04全量CRC通过。仍需原Sideloadly账号／有效Bundle ID覆盖安装，**不卸载、不清索引、不重建**。

已实际查看 [三张原生布局预览](build/ui-review/37557999448/similar-group-browser-review.jpg)：总览300张首组、五列紧凑详情及选择状态。均为TEST合成像素，第三张是控制器夹具而非完整页面，不是真实手指注入、私人照片或手机帧率证据。模型／索引／OCR／缓存身份、搜索加速与普通搜索两列／12张分页均未改；五列仅用于本次清理组内浏览。删除系统照片可能经iCloud同步，即使本App预览网络关闭。

## 上版交付记录：0.9.1 / build 28

**DELIVERED：完整原生验证、设备构建、发布、本地 SHA-256 和 CRC 校验完成；用户手机的约 5 秒停顿／退回首页现象仍待验证。**最终源码 `bf68aba44b0452debb547020eaacdfb2cf5d4f0f`，[CI 37506745432](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37506745432)／[job 112417231223](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37506745432/job/112417231223) SUCCESS。

- **相似照片清理阈值扩大到 0.50–0.99**，步长 0.01、默认 0.96；低于 0.90 提示可能只是场景相近。调整后手动点“重新分组”，不自动勾选或删除；组内每两张均须达标。
- 分组结果发布前的逐张主线程核验改为**离开主线程的一次批量元数据核验**，返回后仍有轻量权限／版本检查；原三次完整图库快照保留。计算结束显示“正在核验照片访问”，不把计算进度当作整个操作已完成。
- **Core79、App1238（1237通过／1既有跳过）、UI14全部通过**，新增23项 App 测试。整体经历四轮：前两轮仅新增滑杆手势测试失败；第三轮清理已通过但一个旧筛选再次打开测试失败；第四轮同源码完整通过。没有跳过或放宽测试，也不能说已修复旧筛选失败的根因。完整记录见 [docs/SIMILAR_CLEANUP_THRESHOLD_UPDATE.md](docs/SIMILAR_CLEANUP_THRESHOLD_UPDATE.md)。
- 本地已校验安装包：[build/device-download/37506745432/LocalImageIQ-0.9.1-build28-iphoneos-unsigned.ipa](build/device-download/37506745432/LocalImageIQ-0.9.1-build28-iphoneos-unsigned.ipa)；[公开 Release ci-37506745432-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37506745432-1)，**1,419,256,255 bytes**，SHA-256 `868e491928c09be03626823eb0938468abe0973b4806b152f8c25671c3ea1177`。仍是需本机重签的 arm64 Release 未签名包。
- 沿用原 Sideloadly 账号／有效 Bundle ID **覆盖安装，不卸载、不清索引、不重建**。可依次试 0.85／0.80／0.75，但低阈值不保证有组，也不保证是可替代的重复照片。删除前逐张核对；删除的是系统 Photos 资产，可能经 iCloud 同步。

已查看 [原生宽阈值预览](build/ui-review/37506745432/similar-threshold-review.jpg)：黑金清理页、0.75阈值、低阈值提示与空结果说明；0组／39候选为合成夹具，不是实际图库结果。已改正源码中已知的主线程阻塞路径，**没有证明它就是用户退回首页的原因，也没有宣称真机现象已消失**。用户已反馈 build27 搜索明显变快，本版保留搜索加速；该反馈没有数值，不代表真机10×已建立。

## 上版交付记录：0.9.0 / build 27

**DELIVERED：原生验证、设备构建、发布和本地 IPA 校验完成；真机搜索 10× 目标尚未验证。**最终功能源码 `ca5422c9473fed58a938120e3643c6de4f19e47c`，[CI 37468042819](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37468042819)／[job 112283955268](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37468042819/job/112283955268) **SUCCESS**。该 run 为 attempt 1，是本功能**整体第四轮验证；第三轮也已成功，不是四次失败**。前三轮生产代码相同、只修测试；第四轮依据初步冷路径基准修改批量缓存装包／解包、地点去重及 Double 矩阵构建。完整账本见 [docs/SEARCH_ACCELERATION.md](docs/SEARCH_ACCELERATION.md)。

> **首搜冷建有明显回退，未达到冷路径加速目标：**最终 DEBUG 模拟器合成基准中，首次 SQLite 建缓存 **19.863 s**，同查询原路径 **11.944 s**，即耗时约 **1.66 倍**（加速比 **0.6013×**）。同进程驻留后，3 个不同查询中位数 **13.352 s → 0.198 s，67.6×**；新 worker 的 binary 首读 **5.713 s，2.0908×**，不是真实进程重启。**收益只证明合成 warm 检索组件，不代表所有搜索、首图或手机端到端 10×。**夹具没有真实模型／翻译／OCR／照片像素／UI 发布及分页检查，冷路径继续优化仍待完成。

- **Core 79 通过；App 1215 = 1214 通过／1 既有 SQLite 物理保护跳过／0 失败**，测试耗时 **324.087 s**、墙钟 **349.439 s**；新增搜索相关 **149** 项全通过。Generated **8／121.399 s**，保留完整 **20 actor、CPU／`.all`** 真实模型数值对齐；UI **14／945.081 s** 全通过，但本功能**没有新增真实导航 UI 端到端测试**。
- 本地已校验包：[build/device-download/37468042819/LocalImageIQ-0.9.0-build27-iphoneos-unsigned.ipa](build/device-download/37468042819/LocalImageIQ-0.9.0-build27-iphoneos-unsigned.ipa)，资产 **615633249**，**1,419,250,307 bytes**；全文件流式 SHA-256：`71e72cc990d46f396e310d1e8db255a5deb0b2654381408a7daf02ebfa0b0637`；**7-Zip 26.03 CRC PASS**（11 个目录、30 个文件，解压总计 **1,566,761,261 bytes**）。
- [公开 Release：ci-37468042819-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37468042819-1)，ID **404761088**，**9 项资产、prerelease、非草稿**，发布于 **2026-10-06T13:40:41Z**。设备包为 **arm64 Release、未签名、iOS 17+、SDK 18.5／Xcode 16.4**；小条目确认版本 **0.9.0／27**、Launch Screen 保留、768 维模型身份和地点 hash 不变，**未做完整模型权重逐字节比较**。

### 本版变化与使用

- **加速默认开启，直接正常搜索即可**：复用有效旧图片向量，增加独立 binary 派生缓存、驻留 Double 矩阵与图库元数据快照；不重新编码、不改推理／翻译、精度或缩略图质量，仍全候选排序、首批 12 张。没有隐藏启动预热、FP16、ANN、GPU 搜索、缩小范围或先出 1 张的替代方案。
- 首个数据库／授权 scope 的首次搜索需建缓存；进入后台排空任务后释放驻留内存，回前台下一次搜索即使命中 binary 也要重新读取并建矩阵，**不是每次打开都约 0.2 s**。连续搜索换不同查询，才是在观察正常 warm 复用；真实翻译和查询编码仍可能成为耗时下限。
- **原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不为升级重建。**可只正常搜索感受速度；若需数字，再开 **设置 → 显示调试工具 → 诊断信息 → 搜索耗时**。用“使用原搜索作对照”开关，对同一查询、相同设置分别比较两条路径，并把首次准备与 warm 分开；隐藏调试会恢复默认加速。完整测量边界见 [docs/SEARCH_ACCELERATION.md](docs/SEARCH_ACCELERATION.md)，安装步骤见 [docs/WINDOWS_IPHONE_INSTALL.md](docs/WINDOWS_IPHONE_INSTALL.md)。

已查看 [原生计时页预览](build/ui-review/37468042819/search-performance-review.jpg)（370×758，来自一张 393×852 原生截图）：**0.300／0.400 s、8000 候选及内存驻留均为 TEST 合成值，不是性能实测**；底部分段需滚动，未据此宣称整页或实际诊断入口导航已验收。“到首张缩略图”是首次可用图片回调，不保证 HQ 或已显示到屏幕。

## 保留的行为

- 默认首批 **12 张**，到底部再追加 12；设置“每批显示”可选 3／12。同一查询只翻译、编码及全局排序一次；**完整候选 ID／向量仍留在 RAM，属于显示分页，不是有界内存或数据库分页**。见 [docs/HQ_RESULT_PAGING.md](docs/HQ_RESULT_PAGING.md)。
- 索引仅由用户手动更新；已有有效记录复用，新增／编辑照片需手动更新才改变向量。启动／自动刷新只读统计元数据，不扫描全库、做 OCR 或清理索引；轻量读取也不是瞬时启动保证。见 [docs/MANUAL_INDEX_STARTUP.md](docs/MANUAL_INDEX_STARTUP.md)。
- 索引 HQ224／Fast 策略、20 个图像 worker、SigLIP 2 FP32／`.all`、768 维向量、模型／索引版本及离线地点缓存身份不变。全屏旧离线 Fast 加载路径**未升级**，不能用全屏代替网格验收。
- B02 黑金主题及九步确定进度不变：系统 Launch Screen 仍仅静态图标；App 内慢风险／等待场景按真实完成步骤显示细条。见 [docs/STARTUP_STEP_PROGRESS.md](docs/STARTUP_STEP_PROGRESS.md)。
- 支持 Photos 全部／有限授权、语义检索、预览与分享、四国离线行政区辅助及可关闭的系统中文查询翻译；保留手动、默认 OFF 的本机 OCR，没有后台无限索引或 App 云端检索兜底。build 26 的手动相似照片分组、并排对比与确认后的系统删除继续保留，不是像素级重复检测；build 24 的多选／分享／收藏／系统相册／筛选／找相似也保留，未新增标签／评分或保存查询。契约见 [docs/SIMILAR_PHOTO_CLEANUP.md](docs/SIMILAR_PHOTO_CLEANUP.md)、[docs/PHOTO_TEXT_SEARCH.md](docs/PHOTO_TEXT_SEARCH.md) 和 [docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)。

## 工程与构建

只将本原生 iOS 子目录作为独立仓库根；**不要上传外层工作区中的私人照片、视频、数据库或桌面缓存**。公开仓库为 [xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios)，企业仓库不动。

现有 [.github/workflows/ios.yml](.github/workflows/ios.yml) 仅手动运行，标准 `macos-15`；本版 `include_models`、`all_compute_units`、`build_device_ipa` 三项均为 `true`，保留完整模型转换／数值对齐、核心、App、UI 和设备构建门槛。**本轮未改变 CI，未新增 CI 缓存、跳过测试或更换 runner 规格。**构建耗时解释与尚未获准实施的缓存建议见 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)。

|入口|用途|
|---|---|
|[project.yml](project.yml)、[project.models.yml](project.models.yml)|XcodeGen App／测试配置及生成模型资源。|
|[docs/IMPLEMENTATION_CONTRACT.md](docs/IMPLEMENTATION_CONTRACT.md)|SigLIP 2 成对编码、768 维向量、图像预处理与本地 tokenizer 契约。|
|[docs/NATIVE_PARITY.md](docs/NATIVE_PARITY.md)|真实模型数值验证；不能用维度相同替代对齐。|
|[docs/QUERY_TRANSLATION.md](docs/QUERY_TRANSLATION.md)|iOS 18+ 真机系统翻译与独立语言包准备，iOS 17 原文回退。|
|[docs/SEARCH_ACCELERATION.md](docs/SEARCH_ACCELERATION.md)|build 27 最终交付、四轮验证、冷建回退／warm 基准及真机未验证边界。|
|[docs/PRIMARY_NAVIGATION_GROUP_REUSE.md](docs/PRIMARY_NAVIGATION_GROUP_REUSE.md)|build 30 双主导航、主页文字开关、0.80设置、首次自动分组与持久复用。|
|[docs/SIMILAR_GROUP_BROWSER.md](docs/SIMILAR_GROUP_BROWSER.md)|build 29 组总览／五列浏览／滑动选择／恢复提醒、完整验证及最终交付。|
|[docs/SIMILAR_CLEANUP_THRESHOLD_UPDATE.md](docs/SIMILAR_CLEANUP_THRESHOLD_UPDATE.md)|build 28 阈值扩展、异步批量发布核验、四轮测试与交付边界。|
|[docs/SIMILAR_PHOTO_CLEANUP.md](docs/SIMILAR_PHOTO_CLEANUP.md)|build 26 清理／系统删除契约、三轮原生记录、最终交付与未验证项。|
|[docs/PHOTO_TEXT_SEARCH.md](docs/PHOTO_TEXT_SEARCH.md)|build 25 OCR 契约、两轮原生结果、交付资产与未验证项。|
|[docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)|build 24 功能契约、最终交付证据、三轮原生验证历史与未验证项。|
|[docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)|build 30 及历次交付的资产、测试与失败／修正账本。|

## 隐私与交付边界

照片、坐标、向量及 OCR 在本机处理，App 不自动上传图库；PhotoKit **预览读取**网络默认 OFF，只有用户显式允许才按需联网，不要求下载整库原图，也不保证全部照片离线可用；该开关**不控制系统 iCloud 照片同步，包括删除同步**。原始 OCR 正文可能敏感，保存在受系统文件保护、排除备份的本机独立数据库；关闭增强、撤回照片权限或删除系统照片**不会立即自动擦除旧文字**，但无权限／已删除照片不参与搜索。用户主动分享会把临时渲染 JPEG（非原图／RAW／Live Photo 原资源）交给所选接收方；主动收藏／相册命令会修改系统 Photos 元数据，不改原图像素。索引更新／清除索引本身不删除系统照片，**相似照片清理则在勾选、应用确认后请求删除系统 Photos 资产，最终由系统控制**；不能对新版作无条件“不删除原照片”承诺。新版权限用途文案已说明确认删除及可能同步，并从 IPA 的小体积权限配置条目核验。Apple 密码、验证码和证书只由用户在本机工具／Apple 流程处理，不交给聊天或 CI。免费开发签名通常 7 天到期，不是永久安装或 App Store／TestFlight 分发。

原生测试、合成截图及完整 IPA 长度／SHA-256／CRC 校验**不替代真机安装、实际照片画质、覆盖率、延迟、RSS／发热和系统行为验证**；包完整性也不是实际 Photos 操作或分享质量的证明。**未执行真实 Photos 删除测试，未删除用户私人照片**；真实清理准确率、系统确认、iCloud 删除同步及写操作仍待真机验证。

项目未设置项目级许可证；第三方模型、地点数据及代码许可分别保留，`redistributionApproved: false` 与人工再分发审查不变。公开可下载不等于法律审核完成，当前未提交商店。公开范围见 [docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md)。

## 历史文档

[README_HISTORY_THROUGH_BUILD22.md](README_HISTORY_THROUGH_BUILD22.md) 完整保留提交 `2075334` 的 README 原文（截至 build 22），包括历次交付、失败与修正记录。归档位于仓库根目录，原相对链接保持不变；其中“当前／本轮”等仅指当时版本，现行状态以上文为准。

0.5.10 / build 23 的 HQ224 交付与三轮验证历史见 [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md) 和 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)。

0.6.0 / build 24 的结果工具交付与三轮原生验证历史见 [docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)；作为保留基线，不代表本版搜索加速的交付状态。

### 0.7.0 / build 25（历史交付）

**DELIVERED：已完成原生验证、设备构建、发布及本地 IPA 校验；真机行为仍待验证。**最终源码 `45e58ba5aceb9331b15ed39a4504f143618d5f75`，[CI 37295461425](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37295461425)／[job 111715497281](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37295461425/job/111715497281) SUCCESS。该新 run 为 attempt 1，**是本功能整体第二次原生验证，不是首轮成功**；首轮仅因新增测试辅助函数不接受 throwing closure 失败，随后一行 `rethrows` 修正只改测试，两轮间 App 生产代码不变。核心 79 通过；App 974（973 通过／1 既有 SQLite 物理保护测试跳过／0 失败）；UI 13 全通过。新增六组 119 项 App 测试全部通过，其中 4 项实际调用 Vision 识别合成图；详细耗时、失败账本及验收边界见 [docs/PHOTO_TEXT_SEARCH.md](docs/PHOTO_TEXT_SEARCH.md)。

- 历史本地包：[build/device-download/37295461425/LocalImageIQ-0.7.0-build25-iphoneos-unsigned.ipa](build/device-download/37295461425/LocalImageIQ-0.7.0-build25-iphoneos-unsigned.ipa)，**1,418,904,925 bytes**；2026-10-06 增加带版本名的本地副本，全文件 SHA-256 与原包相同，未重新编译、打包或签名，原包及 CRC／下载记录保留。命名脚本当时通过 **104 项本地发布测试和打包命名自检**，未另触发原生 CI。
- [历史 Release：ci-37295461425-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37295461425-1)，ID **403616561**，9 项资产、prerelease、非草稿；**2026-10-05T10:55:25Z** 发布，远端资产仍保留旧名称，未改历史发布。
- 当时已实际查看 [两张原生文字索引夹具拼图](build/ui-review/37295461425/photo-text-contact.jpg)：黑金设置页开关 ON、合成计数 12／8／3，未授权注入使更新按钮禁用；进度页为 12／24（50%），显示暂停入口。顶部 TEST 是测试水印，不是生产 UI；这些是合成汇总状态，不是实际照片 OCR 质量或性能证据。

### 0.8.0 / build 26（历史交付）

**DELIVERED：已完成原生验证、设备构建、发布及本地 IPA 校验；真机行为仍待验证。**最终功能源码 `f873b2c77ac03c9ca65e2126de1790f24de6ff3b`，[CI 37373137157](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37373137157)／[job 111975016644](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37373137157/job/111975016644) 整体 **SUCCESS**。该新 run 为 **attempt 1，但属于本功能整体第三轮原生验证，不是首轮成功**。第一轮仅测试夹具类型推断编译失败；第二轮有最大字体滚动测试的两条断言失败，以及新增 UI 测试阈值实际 0.98、要求 0.99 的失败。第三轮包含**生产滑杆整数刻度映射修正**，不能统称为仅改测试；三轮分组算法与删除逻辑未改。完整失败历史和修正边界见 [docs/SIMILAR_PHOTO_CLEANUP.md](docs/SIMILAR_PHOTO_CLEANUP.md)。

- **Core 79 通过；App 1066 = 1065 通过／1 既有 SQLite 物理保护跳过／0 失败**，测试耗时 **272.777 s**、墙钟 **282.346 s**；新增清理相关 **92** 项全通过。真实模型 Generated **8／143.619 s**，保留完整 **20 actor、CPU／`.all`** 数值对齐；UI **14／922.270 s** 全通过。分项耗时见功能文档。
- 本地已校验包：[build/device-download/37373137157/LocalImageIQ-0.8.0-build26-iphoneos-unsigned.ipa](build/device-download/37373137157/LocalImageIQ-0.8.0-build26-iphoneos-unsigned.ipa)。这是**首次实际远端发布即带版本名的 IPA**，不是 build 25 的本地改名副本。资产 ID **613657795**，**1,419,110,911 bytes**；全文件流式 SHA-256：`2f05a081f9987db820c3c8f21b89efbbeefa65762ad789b6c35d2700cf1b737b`；**7-Zip 26.03 CRC PASS**（11 个目录、30 个文件，解压总计 1,566,268,285 bytes）。
- [公开 Release：ci-37373137157-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37373137157-1)，ID **404106453**，**9 项资产、prerelease、非草稿**；发布时间 **2026-10-05T21:34:51Z**。
- 设备包为 **arm64 Release、未签名、iOS 17+、SDK 18.5／Xcode 16.4**，仍需 Sideloadly 本机签名。远端成功后首次本地下载被旧文件名校验误拒；本地兼容旧名／版本名并通过回归后已下载校验，**不是远端打包失败或 CI 重跑**。

发布命名继续核对 App 实际版本、工程版本、报告与校验文件；当时 **104 项 Node 测试、30 项静态检查、12 项品牌检查通过**，原有门槛不变。历史发布和资产保留。

#### build 26 功能与使用记录

- **首页搜索框下方 →「相似照片清理」→ 手动「开始分组」**：打开不自动扫描，不自动删除或更新索引。组按张数降序；默认 **0.96**，范围 **0.90–0.99**、步长 **0.01**。仅复用当前完整 revision 有效的图片向量，**不重新编码、不用 OCR**；包含当前授权且有效索引覆盖的隐藏照片。每组任意两张都须达标，不沿相似链合并；贪心不重叠分组不穷举全部极大团，也不保证找全或 100% 正确，阈值不是重复概率。
- 各组并列，无自动勾选或推荐保留者；可全选整组，但确认会额外警告该组不留照片。勾选／对比标记**不立即删除**；点「删除 N 张」捕获选择、应用确认后才交给 PhotoKit／系统处理。**删除的是系统 Photos 资产**：通常进入「最近删除」，不是永久删除或恢复保证；Live Photo 按整个资产操作，iCloud 可能同步删除，**不受预览网络开关控制**。契约与限制见 [docs/SIMILAR_PHOTO_CLEANUP.md](docs/SIMILAR_PHOTO_CLEANUP.md)。
- **设置 → 照片文字 →「文字搜索增强」**：默认 OFF，明确选择后持久保存。开启后再点「**更新文字索引**」，保持前台；只开开关不索引、不请求 Photos 权限，启动与搜索也不自动 OCR。系统 Vision 识别中英文，文字匹配与图片排序实验性融合，不保证所有查询都改善。
- **复用有效的当前图片索引**，不重新编码已有有效图片向量。新增／编辑照片须先手动更新图片索引，再更新文字索引；文字更新可暂停，回前台不会自动续跑。像素、权限、敏感文字保存及 RRF 限制见 [docs/PHOTO_TEXT_SEARCH.md](docs/PHOTO_TEXT_SEARCH.md)。
- **原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不为升级重建。**模型、图片向量／索引及 OCR 缓存身份不变，清理功能无需重索引；要纳入新增／编辑照片才手动更新图片索引。安装步骤见 [docs/WINDOWS_IPHONE_INSTALL.md](docs/WINDOWS_IPHONE_INSTALL.md)。旧版网格画质诊断与限制见 [docs/HQ224_DISPLAY_VERIFICATION.md](docs/HQ224_DISPLAY_VERIFICATION.md)，默认调试仍 OFF。
- **build 24 基线保留**：结果多选／批量分享／收藏／系统相册操作，日期／相册／图片类型筛选，以及只用缓存图片向量的「找相似」。原功能契约、三轮验证历史和截图限制仍见 [docs/SEARCH_RESULT_TOOLS.md](docs/SEARCH_RESULT_TOOLS.md)，不以清理或 OCR 合成夹具替代其真实 Photos 操作验收。

当时已实际查看最终 [三张原生清理夹具拼图](build/ui-review/37373137157/similar-cleanup-contact.jpg)（1008×758）：黑金页显示 **3 组／9 张**、选中 **3 张**及删除按钮，默认 **0.96** 滑块现处正确约 **2/3** 位置；首组仅部分可见，其余需滚动。列表是未授权占位／合成状态，对比页是注入红蓝像素、当前两张完整适配，**不是私人照片或用户缩放手势证据**。该版新增 UI 已验证真实入口、未授权开始禁用、无自动扫描、物理拖动 **0.96 → 0.99** 及搜索词保留，**没有实际删除对话框／系统删除端到端验证**。最大字体往返滚动测试通过；不代表手机性能、真实重复判断质量或 Photos 写操作已验证。