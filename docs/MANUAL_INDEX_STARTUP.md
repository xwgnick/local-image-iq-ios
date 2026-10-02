# 手动索引与冷启动边界

## 当前状态（2026-10-02）：0.5.4 / build 17 首轮 SUCCESS，已交付并完成本地校验

**手动索引改动已通过完整原生／UI 测试及设备构建，不再是待验证的本地实现。**[CI 37022941546](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37022941546)／[job 110890327401](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37022941546/job/110890327401)，源码 **`02d5bc72b4d463bf2adca50dbf1d571a93183354`**；既有个人公开仓库标准 `macos-15` 手动工作流，`include_models`／`all_compute_units`／`build_device_ipa` 全为 `true`，**attempt 1 SUCCESS，无追加重试**。核心 **79 通过**、App **483 通过／1 既有跳过／0 失败**、UI **10 通过**，详细结果见第 6 节。

[build 17 公开 Release](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37022941546-1) 已发布，[本地 IPA](../build/device-download/37022941546/LocalImageIQ-iphoneos-unsigned.ipa) 已实际完整流式下载并通过长度／SHA-256 与全量归档 CRC 检查。**手机安装、实际启动／首搜耗时及失败手势等真机行为仍待确认**；不把模拟器测试当真机验收，也不承诺瞬时启动。

使用原 Sideloadly 账号／有效 Bundle ID 覆盖安装，**不卸载、不清索引、不因升级重建或重跑 Index / resume**。已有当前策略有效记录沿用；需要纳入新增／编辑照片时才手动更新。B02 的 build 16 原始交付另保留于 [APP_ICON_AND_LAUNCH.md](APP_ICON_AND_LAUNCH.md)，其包与测试不是本轮证据。

## 1. 冷启动仍完整准备模型，但不扫描图库

- 系统静态启动页与 App 内准备页仍只显示 B02 图标；正常启动必须等模型准备完成才能进入首页，失败恢复规则不变。没有人为等待、假进度或跳过模型的捷径。
- 冷启动保留 `encoders.prepare()`：完整准备主图像模型、文本模型和分词器；不提前加载额外 19 个索引图像模型，不读取照片像素或计算照片向量，也不准备翻译语言包。
- **冷启动、普通回前台刷新、图库变化后的自动刷新均不做 PhotoKit 全库枚举、不做 reconcile／数据库清理、不读取或解析完整地点几何。**权限状态读取和已有观察机制仍保留；这不等于启动完全不接触 PhotoKit。
- 普通刷新仍使用 `inspectResources()`，而非重复完整模型准备；已就绪后回前台不重放启动页。
- 自动路径仅通过只读 SQLite 连接读取已保存的索引统计，不创建数据库、迁移或裁剪记录。首次安装没有数据库时是正常的空索引。

这里移除的是自动图库扫描和完整地点包解析，**不是取消模型准备，也不是承诺启动或搜索零等待**。

## 2. 显示的是已保存统计，不是当前可搜索数量

`storedCounts()` 使用 SQL 元数据聚合，不为了计数读取／JSON 解码所有向量。数量按模型／图像策略缓存身份统计，地点数量还检查地点版本和对应缓存记录。

- “本机已保存的索引／地点标签”不代表此刻已授权、可访问、可搜索或具有 GPS 的照片数量。
- 计数不是向量健康检查；能计数不代表向量已通过搜索时的数值校验。
- `authorizedCountKnown == false` 表示没有当前图库枚举结果，UI 显示“未扫描”，不能将默认值当成“当前图库零张”。手动索引或搜索取得的数量也是相应时点的快照，不是永久有效的实时总数。
- `indexStatisticsKnown` 单独表示保存统计是否已确认，不能与授权数量的 known flag 混用。

清除或全部重建开始时，先将 `indexStatisticsKnown` 置为 `false`。因为清除可能已经完成，而等待其返回的任务随后被取消，UI 不能继续把旧数量当真，也不能凭取消结果假定数据库一定为空。

此时显示“待刷新”，暂不按旧统计开放搜索；用户可点“刷新索引统计”，或由后续正常只读刷新重新取得实际数量。**刷新不扫描照片、不更新索引；未知统计不是永久锁死。**刷新成功后按真实保存数量恢复状态；若为空，仍须手动建立索引。

## 3. 手动更新与全部重建

模型、索引／地点缓存身份和 SQLite schema 未变，**覆盖安装 build 17 本身不需要更新或重建索引**。首次没有索引时才需建立；日常需要纳入新增／编辑照片时手动增量更新，全部重建只是可选维护操作。

### 建立／更新索引

“我的图库”提供“建立索引”或“更新索引”。只有用户显式发起索引，才执行完整授权照片枚举、修订核对、过期／不可访问记录清理及孤立地点缓存清理，并按需加载完整地点边界。

- 依据照片 **ID、revision／修改时间和当前模型＋图像输入策略缓存身份**复用已完成记录。
- 当前缓存身份下，未变化照片复用图像向量；新增或变化照片才重新请求预览并编码，缺少有效记录的照片也需要处理。不因打开 App、刷新或搜索而自动重新编码。
- 手动扫描仍核对地点／GPS；必要时更新或移除地点标签及缓存，能够复用图像向量时不为地点更新重算图像。
- 扫描前后沿用既有 reconcile／cleanup；删除、撤权、修订变化在手动更新中落实到数据库，而不是由搜索偷偷修改。
- 保留现有 **20 个图像 worker**、独立图像编码器、单个文本编码器、滑动窗口、有序提交、取消后排空旧任务及已提交记录保留的规则。
- HQ224 优先／Fast 回退、显式 iCloud 下载开关和默认关闭策略不变。更新请保持应用在前台；恢复时复用已经完成且仍有效的记录，不保证所有照片都有可用本地预览。

### 全部重建索引

“全部重建索引”必须经过明确的破坏性本地缓存确认。确认后，在既有串行任务链中**先调用原有 `clear()`，再调用原有 `index()`**，不是另建索引算法或降低并发。

清除的是本机照片搜索索引和地点缓存，不修改或删除系统相册原照片。重建期间尚未完成索引的照片不能搜索；取消保留已经提交的记录。全部重建会重新请求预览，但不保证获得更高清的图像。通常处理新增／编辑照片只需“更新索引”，不要求先清空。

## 4. 搜索只读，但仍检查当前访问范围

普通搜索不调用 reconcile、不 prune／写入数据库、不自动索引新增照片，也不加载完整地点边界。**不扫描图库的承诺仅适用于启动／刷新，不适用于真实搜索。**

搜索保留三个只读的 PhotoKit 授权照片快照检查点：

1. **初始快照**：记录权限状态、变化 generation 和当前可访问照片 ID／修订。
2. **评分前快照**：模型准备、查询编码、数据库读取后，再核对权限和完整快照是否与初始一致。
3. **评分后快照**：评分完成后再核对一次；检测到变化则拒绝这次结果，提示重新搜索，保存索引不变。

读取缓存时，`searchRecords(... accessibleIDs:)` 在**向量 decode／校验、评分和地点中心均值计算之前**按初始可访问 ID 集合过滤。已删除或不可访问行不会参与评分或地点均值，也不会因为其向量内容触发解码错误；它们仍可能留在数据库及“已保存统计”中，等待手动更新清理。

这与内容新鲜度是两个边界：

- **已编辑但仍可访问的照片，故意继续使用最后一次手动索引的旧图像／地点内容**，直到用户手动更新；不会仅因保存 revision 落后就从普通搜索中剔除。
- **新增但未索引的照片不会自动加入搜索**。加入或编辑发生在搜索过程中时，快照变化可使该次搜索失效；下一次搜索仍遵守上述手动更新规则。
- 搜索中的修订稳定性检查比较本次初始与后续快照，不要求保存的 embedding revision 已经追上当前照片。
- 评分公式、地点去重中心化、无地点中性处理和确定性排序规则不变。

worker 返回后还存在一次 actor 切换。`AppState` 在 `MainActor` 真正发布结果前，先检查任务取消／operation token 和权限，再执行 `SearchResponse.validateAccess()`：核对权限状态、图库变化 generation，以及**实际返回 ID 的当前修订／可访问性**，通过后才更新 UI 结果。

这些检查用于拒绝已观察到的过期或失去访问权的结果，**不是对 iOS 权限的原子锁，也不保证与系统权限变更之间绝对零竞态**。相关原生回归已执行通过，但不扩写为尚未完成的真机验证结论。

## 5. 小地点元数据与不变的缓存身份

- 启动、刷新、搜索和照片诊断读取小型 [../Resources/Places/places-manifest.json](../Resources/Places/places-manifest.json)，新增 `runtime` 元数据提供地点版本和覆盖说明，不读取完整坐标数组。**build 17 实际 IPA 已核验包含该元数据**；manifest 为 **22,960 字节**，新 SHA-256 为 **`7edb232043452d9a6f718b8a59a121fa0938dfdd54e732ed97e2be60f195b7e5`**。
- `runtime.schemaVersion` 为 **1**；运行时版本仍为 **`raycast-v1-93c9a925e35247f2`**，沿用完整 GeoJSON 最终字节的既有 FNV-1a 身份，不重新定义地点算法或缓存版本。
- 完整 [../Resources/Places/Places.geojson](../Resources/Places/Places.geojson) 仍为 **15,175,079 字节／2,943 个要素**；完整字节 SHA-256 **`41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`** 不变。新增的是 manifest 的运行时元数据，不是边界内容；不声称 manifest 自身哈希未变。
- 应用中只有显式手动索引需要完整 resolver：首次按需解析，随后复用已缓存 resolver。注入 resolver 时直接使用其确切元数据；小元数据本身也按 worker 缓存。
- 元数据缺失、无效或包不可用时返回 `places-unavailable`／不可用说明，**不回退到完整几何解析**。只读路径不能靠读取大包“修复”元数据。
- 打包／检查阶段核对完整字节 SHA-256 和运行时 FNV。运行时只检查小 manifest 的结构与版本格式，不重读大包验证其哈希，因此不能识别所有“格式正确但与几何不匹配”的旧 manifest。

模型权重、模型准备流程、分词／预处理、图像输入策略、模型＋图像缓存身份、地点版本和搜索／翻译逻辑均不因此改变。**SQLite 缓存 schema 仍为 1，不做数据库迁移，也不因本轮改动要求清空重建。**这里的 schema 1 指 SQLite 缓存及地点元数据，不是更改模型 manifest 的 schema。

## 6. build 17 已完成的验证与交付

### 原生测试：本轮实际执行，不借用 build 16 结果

- 核心 **79 通过**。
- App **484 项＝483 通过／1 既有跳过／0 失败**，测试 **176.486 秒**（wall **212.219 秒**）。唯一跳过仍为 SQLite 真机文件保护在模拟器的既有限制。
- 独立 UI **10 全通过／503.763 秒**：导航 **5／283.213 秒**、键盘 **5／220.550 秒**；模型必需，未绕过启动准备门控。

以下是 **App 484 项中的子套件，不是额外测试数**：

| 子套件 | 本轮结果 |
| --- | --- |
| `LaunchStateTests` | 15 通过 |
| `LaunchWorkerTests` | 8 通过 |
| `ManualIndexStateTests` | 13 通过 |
| `PlacePackMetadataTests` | 13 通过 |
| `RefreshReadinessTests` | 14 通过 |
| `PhotoIndexWorkerTests` | 29 通过 |
| `SQLitePhotoStoreTests` | 26 项：25 通过／1 既有文件保护跳过／0 失败 |
| `StartupPresentationTests` | 9 通过 |
| `GeneratedModelParityTests` | 8 通过／120.257 秒 |

此前本地品牌 **12**、静态 **30**、地点 **32** 通过，Node 源码检查及自测 **PASS**，作为静态／本地证据保留，不与上述原生计数相加。本次仅整理已取得的结果，没有重新运行测试、构建或下载。

相关源码／测试见 [../App/State/PhotoIndexWorker.swift](../App/State/PhotoIndexWorker.swift)、[../App/State/AppState.swift](../App/State/AppState.swift)、[../App/Persistence/SQLitePhotoStore.swift](../App/Persistence/SQLitePhotoStore.swift)、[../App/Places/PlacePackMetadata.swift](../App/Places/PlacePackMetadata.swift)、[../Tests/ManualIndexStateTests.swift](../Tests/ManualIndexStateTests.swift)、[../Tests/RefreshReadinessTests.swift](../Tests/RefreshReadinessTests.swift) 与 [../Tests/PlacePackMetadataTests.swift](../Tests/PlacePackMetadataTests.swift)。

### 发布与本地完整包校验

- Release **401925676**／tag **`ci-37022941546-1`**，**2026-10-02T15:15:39Z** 发布，**9 项资产、公开 prerelease、非 draft**。
- 设备构建 **0.5.4 / 17、arm64 Release、未签名、SDK 18.5、Xcode 16.4、最低 iOS 17.0**；仍须用户在本机签名。
- [已完整下载的 IPA](../build/device-download/37022941546/LocalImageIQ-iphoneos-unsigned.ipa)：asset **605869344**，**1,418,481,134 字节**，SHA-256 **`51068e4916314399c0ad7bae3e0db7c33ac652691976cfd51c4ae4a241e3b071`**。实际全量流式下载后的长度／哈希核验通过，`ipaVerifiedLocally: true`，不是只读取远端声明。
- [设备报告](../build/device-download/37022941546/device-build.json)、[交付清单](../build/device-download/37022941546/delivery.json)、[校验文件](../build/device-download/37022941546/SHA256SUMS.txt) 与 [下载记录](../build/device-download/37022941546/release-fetch-1bcda8c5-e734-4b0b-9cb8-a815559b795d.json) 齐全。
- **7-Zip 26.03 全量解压／CRC PASS**：11 文件夹、30 文件，解压后 **1,563,320,201 字节**。该结果只属于上述原始 IPA，不验证 Sideloadly 重签包或手机安装。
- 实际 IPA 的小 manifest／运行时版本及完整几何身份已核验，见第 5 节；**manifest 哈希更新，不等于几何、地点缓存身份或 SQLite schema 改变**。

### 仅四张图的审核范围

[UI 截图 ZIP](../build/ui-review/37022941546/UIReview.zip) 已下载并校验：**4,253,640 字节**，SHA-256 **`afd7a841ca6c111cb124ed132062dd484a5ae64d7735bd0659f1c3aec1e9e4a3`**。父流程实际仅查看 [1340×758 联系图](../build/ui-review/37022941546/manual-index-contact.jpg) 内四图，记录见 [审核清单](../build/ui-review/37022941546/manual-index-review.json)：

- 浅／深色启动图各 **393×852**：合成状态、带测试水印，正式启动页没有水印。两张图各自 SHA-256 与 build 16 对应图相同，纯图标启动视觉保留；变更的是背后的准备路径，不是重新设计启动画面。
- 真实模拟器运行的未授权首页／图库各 **1206×2622**：展示 build 17 新的手动索引操作，**不是已授权图库，没有读取 Photos**；不能用它证明真实图库索引操作已在手机完成。

没有把其他图片列为已审核，也没有把截图当作物理 iPhone 测试或提速证据。

## 7. 剩余边界：真机安装、性能与交互

build 17 的原生／UI 测试、设备编译和本地交付校验已完成；仍未确认物理 iPhone 安装、系统启动页交接、失败手势、真实图库权限变化／搜索发布／取消恢复及性能。**没有实际 iPhone 耗时测量，也没有新增 telemetry／计时埋点**；模型和分词器仍完整准备，不承诺具体启动秒数、加速比例、零等待或绝对零竞态。

安装沿用 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md) 的原账号／有效 Bundle ID 覆盖路线，不卸载、不清库；手动增量更新只在需要纳入新增／编辑照片时发起，全部重建可选。图标与 build 16 原始交付历史见 [APP_ICON_AND_LAUNCH.md](APP_ICON_AND_LAUNCH.md)；交付账本由主流程维护于 [BUILD_STATUS.md](BUILD_STATUS.md)。