# 高质量结果缩略图与滚动分页

## 现行覆盖说明：0.5.10 / build 23

**build 23 已交付，第三次完整原生验证 SUCCESS；实际手机网格画质仍待确认。**[CI 37226908383](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37226908383)／[job 111508328530](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37226908383/job/111508328530)，最终源码 **`2075334aebd5c90abf0ee70b459e5645fe878d3b`**。新 run attempt 1 不等于整体首轮成功；三轮生产文件未变，完整测试修正历史仅见 [BUILD_STATUS.md](BUILD_STATUS.md)。

**下方第 1–8 节全部保留为 build 22 历史，尤其旧第 2 节“大 HQ 可读即停止／缺失就转 Fast”与旧缓存描述已经被以下规则取代，不能据此解释 build 23。**现行完整契约见 [HQ224_DISPLAY_VERIFICATION.md](HQ224_DISPLAY_VERIFICATION.md)。

|现行网格规则|build 23 行为|
|---|---|
|本地候选|先按 tile 像素目标请求大尺寸 HQ；足够覆盖且 `degraded != true` 才结束，否则再尝试实际照片宽高比、短边 224 的 HQ224。HQ224 使用 `.current`／`.aspectFit`／`.fast` resize／`.highQualityFormat`，与独立对比的 HQ224 请求契约相同。|
|候选选择|先选未明确降质的 HQ，再比较按方向校正的像素覆盖率；同分保留较早候选。小尺寸／降质 HQ 仍可显示，不因尺寸不足直接改选 Fast。|
|联网与兜底|当前 HQ 仍不足／明确降质且用户 opt-in 时，才尝试联网大尺寸 HQ，不保证更清晰。只有所有已尝试 HQ 阶段都无可用像素，才请求本地 Fast224。普通错误／权限错误／取消即使此前有可用候选也照常传播。|
|缓存与元数据|只有已知 HQ 阶段、`degraded != true` 且方向覆盖率 ≥ 1 才可复用缓存；来源未知、Fast、覆盖不足或明确降质不缓存。降质标志未知不等于来源未知：前者仍可能满足缓存条件，但不证明画质。图片及不可变实际选中元数据一起缓存，命中时保留原记录，不伪装成本次新请求。|
|刷新边界|低清仍可显示但不永久占用 HQ 缓存；没有自动重试、轮询或定时器，已显示图片只在下一次真实请求时重新评估，不是实时自动升级。|

**分页与索引不变**：默认首批 12／续批 12，设置 3／12；查询按需翻译、编码、全局排序各一次，后续公开同一排序前缀。完整候选 ID／向量仍在 RAM，不是有界内存或数据库分页。逐页校验及无关诊断取消保留图库的行为继续保留；手动索引、索引 HQ224／Fast、20 worker、FP32／`.all`、schema／缓存身份、九步启动条和全屏旧离线 Fast 加载均未改。

当前核心 **79**、App **713（712 通过／1 既有 SQLite 跳过／0 失败）**、UI **11 全通过**；全部 CPU／`.all`／20 actor 门槛保留，未改原标准 `macos-15` 流程、三项全 true 输入、缓存配置或 runner 规格。[公开 Release ci-37226908383-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37226908383-1) 于 **2026-10-04T19:35:19Z** 发布，9 项资产、prerelease；[../build/device-download/37226908383/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/37226908383/LocalImageIQ-iphoneos-unsigned.ipa) 已完整流式核验及全量 CRC PASS。

**原 Sideloadly 账号／原有效 Bundle ID 覆盖，不卸载、不清索引、不重建。**设置开启“显示调试工具”后回到**同一搜索结果网格**，只截几张模糊格子的实际选中来源、请求尺寸、原始返回像素、降质是／否／未知、缓存命中与路线；不要用独立对比页或全屏作网格取图证明。默认调试 OFF，普通外观保持原样；页脚开关不额外加载，大号辅助功能字体可能裁切页脚。已看过的两张原生诊断布局图是合成占位场景，**没有用户 Photos 画质确认**，尺寸达标也不等于锐利。安装见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。

## 历史基线：0.5.9 / build 22

以下第 1–8 节的“本轮／本路径／当前”均指 build 22 当时实现与证据；不作 build 23 现行策略或本次重新测试的声明。分页机制沿用，但旧图像选择策略已被页首覆盖说明取代。

**0.5.9 / build 22 当时第三次整体验证 SUCCESS，原生测试、设备构建、发布及本地 IPA 校验完成；当时真机仍待验收。**[CI 37208795156](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37208795156)／[job 111455534540](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37208795156/job/111455534540)，最终源码 **`2c05008a74f3ec4df170de1b2fc1fb79a0bcec84`**；这是新 run 的 attempt 1，不是该功能首轮成功。完整历史见 [BUILD_STATUS.md](BUILD_STATUS.md)。

## 历史 build 22 · 1. 用户行为（分页机制沿用）

- 搜索默认先显示 **12 张**；滑到当前列表底部，再追加 **12 张**，直到全部候选显示完。最后不足一批则全部追加；空结果、不足 12 张及恰好 12 张不会生成多余页。
- 设置保留 **3 张 / 12 张**选项，但标签已改为“**每批显示**”。`resultLimit` 现在是显示批量，不是旧 Top-K 总结果上限；修改后清空当前结果，下次显式搜索生效。
- 同一会话只追加既有全局排序的前缀，保留查询、翻译结果、既有照片顺序和分数，不重置滚动容器或跳回顶部。继续往下显示的是候选，不代表都相关；没有新增分数阈值，负分也不被截掉。

## 历史 build 22 · 2. 结果缩略图（选择策略已被 build 23 取代）

路径为 `PhotoThumbnailView` → `PhotoThumbnailCache` → `PhotoLibraryClient.thumbnailImage` → `DisplayThumbnailLoader`，仅用于结果网格。

- 请求使用 `PHImageManager.requestImage`、`.aspectFill`、`.current`；HQ 使用 `.highQualityFormat` 与 `.exact`，Fast 回退使用 `.fastFormat` 与 `.fast`。
- 目标像素为实际 tile 几何尺寸乘 `displayScale`，**宽高分别向上取整**。默认两列、4:5 网格，在宽 393 pt、左右各 20 pt、列间距 6 pt 的 iPhone 布局下：tile 为 **173.5 × 216.875 pt**，3× 请求 **521 × 651 px**。这不是所有设备固定尺寸；紧凑网格、横屏或布局变化会改变请求。结果 tile 不再依赖固定 480×480；缓存接口的旧调用默认值仅为兼容保留。
- `.exact` 和目标像素都是**请求规格，不保证最终返回分辨率或真实细节**。Photos 可能仅提供较小本地资源；可读的小图仍接受，`isDegraded == false` 也不是足够清晰的证明。加载器不自行放大、裁切或重新编码；SwiftUI 按 tile 边界填充并裁切显示。

|照片网络开关|仅在资源缺失时按顺序尝试|
|---|---|
|`false`（默认）|本地 HQ → 本地 Fast|
|`true`（用户明确开启）|本地 HQ → 联网 HQ → 本地 Fast|

本地 HQ 成功即停止，即使开启联网也不继续升级。回退只针对无图、不可读像素、云端缺失提示或 Photos 3164（需要网络）等资源缺失；**可读像素优先于云端标志／3164**。本地 HQ/Fast 接受一次性的降级回调；联网 HQ 忽略临时降级结果，等待最终回调或取消，不增加人为截止时间。

**普通错误、权限错误和取消优先于图像，不得被 Fast 或其他阶段掩盖**；真实网络错误也不会伪装成资源缺失。各阶段串行，首次终态回调生效，重复／迟到回调不能替换结果；取消会取消对应 Photos 请求，并阻止继续回退和发布。

本路径不调用原始数据接口，也不请求 `PHImageManagerMaximumSize`。但开启网络不等于能保证 Photos 只下载目标大小的缩略图字节；系统底层取用何种资源不由该尺寸参数保证。

源码：[../App/Photos/DisplayThumbnailLoader.swift](../App/Photos/DisplayThumbnailLoader.swift)、[../App/UI/PhotoViews.swift](../App/UI/PhotoViews.swift)、[../App/Photos/PhotoLibraryClient.swift](../App/Photos/PhotoLibraryClient.swift)。

## 历史 build 22 · 3. 缓存与其他路径（现行缓存资格见页首）

- 缓存键包含 asset ID、**索引中保存的 revision + 当前照片 revision**（修改／创建时间）、请求像素宽高、网络开关及图库 `changeGeneration`。另有缓存自身 generation token，`clear()` 后的旧请求不能重新填入缓存。
- 命中缓存前、异步加载后都检查权限、当前 revision、图库 generation 与清空 token；客户端还在首次请求、各回退阶段和返回前核对授权状态／revision／generation，拒绝过期结果。
- 照片已编辑但尚未手动更新索引时，仍可用**旧 embedding 搜索、当前 `.current` 像素显示**。两种 revision 不要求相等；加载显示图不重做索引、不写数据库。
- `NSCache` 按解码像素的 `bytesPerRow × height` 记 cost；这是内存核算，**没有设置 count/cost 上限或任意像素、字节、容量天花板**，不是固定内存预算或 RSS 保证。
- **全屏旧 `displayImage` 未改变**：仍是离线 Fast／联网 HQ、`.aspectFit` 与 `.fast` resize；全屏当前页仍请求 `PHImageManagerMaximumSize`。不要把本轮网格 HQ 改善描述为全屏也已升级。
- **旧索引 HQ224 输入策略、模型及缓存身份未改变**；显示 HQ 不是索引 HQ224 的替代。本轮不要求清索引或重建，手动索引策略仍保留。

源码：[../App/Photos/PhotoThumbnailCache.swift](../App/Photos/PhotoThumbnailCache.swift)、[../App/Photos/PhotoLibraryClient.swift](../App/Photos/PhotoLibraryClient.swift)、[../App/UI/PhotoGallery.swift](../App/UI/PhotoGallery.swift)、[../App/Photos/IndexingImage.swift](../App/Photos/IndexingImage.swift)。

## 历史 build 22 · 4. 全局排一次，按需显示（机制沿用）

`AppState.search()` 只解析／按需翻译查询一次，只调用一次 worker，传入 **`limit: Int.max`**。worker 对当前可访问且索引身份有效的完整候选集编码查询、计算全局地点中心与精确分数，再统一排序一次；沿用既有分数公式和 UTF-8 asset ID 同分排序，没有按页重新去均值、重新打分、截断或增加筛选阈值。

`ResultPages.response` 持有**完整 `[SearchHit]`**，其中 `IndexedPhoto` 仍携带图像向量和可能存在的地点向量；全部候选 ID／向量仍保留在 RAM，`results` 只是逐渐增长的可见前缀。**这是显示分页，不是有界内存分页，也不是服务端分页、数据库游标／分批读取。** 排序和页校验不请求照片像素；tile 按 SwiftUI 布局需求加载，不全图库预加载像素。懒布局可能预创建邻近 tile，不承诺只有屏幕内 tile 才会发图像请求。

分页由列表末尾 1 pt 的 `ResultPageBoundary` 发送命名滚动坐标系下的几何 preference；仅当 `minY < viewportHeight && maxY > 0`，即边界与可见视口相交时请求下一批，**不是 LazyVGrid cell 的 `onAppear`**。事件携带会话 UUID 与当时已显示数量；`loadMoreResults` 核对前台、非忙碌、同会话、数量精确匹配及尚有余项，拒绝重复、旧会话和错误边界事件。全部显示后移除边界。

`ContentView` 保存最近的边界几何；忙碌期间拒绝追加，**`isBusy` 从忙碌变回 idle 时重新检查该边界是否仍与视口相交**，再调用同一分页入口，仍受前台、session／已显示数量守卫。这样初次结果发布或无关诊断结束后，即使几何 preference 没有再次变化，也不会漏掉可见边界；不靠离屏 `onAppear`、定时器或重新查询补页。

源码：[../App/State/AppState.swift](../App/State/AppState.swift)、[../App/UI/ResultPageBoundary.swift](../App/UI/ResultPageBoundary.swift)、[../App/UI/ContentView.swift](../App/UI/ContentView.swift)、[../Packages/ImageIQCore/Sources/ImageIQCore/VectorSearch.swift](../Packages/ImageIQCore/Sources/ImageIQCore/VectorSearch.swift)。

## 历史 build 22 · 5. 发布前校验与会话失效（机制沿用）

1. **初次 worker：**捕获授权状态和图库 generation，完整枚举当前授权照片；在解码向量、地点去均值及打分前过滤不可访问 ID。保留打分前、打分后两次完整快照复核，加上最初快照，共三次完整枚举。搜索只读，不删除或重写旧索引。
2. **首屏与续页：**跨 actor 后在 MainActor 同步调用 `SearchResponse.validatePageAccess`；全局检查授权状态与图库 generation，但 revision 查询只针对**本次将公开的 ID**。首屏验证前 12 个，后续只验证新增 12 个／最后余项；空首屏也做全局校验。不是每一页重查完整结果的所有 revision。
3. PhotoKit 通知到达时先同步增加 `changeGeneration`，再排 MainActor 回调；所以即使界面通知尚未处理，已收到的变化也能使页校验失败。页校验前后复查授权／generation，失败则清空整个结果会话与缩略图缓存并要求重新搜索，不保留混合新旧页。
4. 新查询、图库查询编辑、地点权重／每批数量／中文搜索开关变化、后台、刷新、图库变化，以及手动索引或清索引都会清除 continuation、结果、选择与已完成查询信息。**不能把所有取消都当成图库失效**：`AppState.cancel()` 仅在已有分页且 activity 为 idle／search 时清除分页；取消无关照片诊断或翻译准备保留底层图库的查询、结果、选择、分页 session 与候选总数。诊断关闭／诊断页查询编辑仍拒绝迟到报告，不等于编辑图库查询。旧异步任务继续受取消和 operation token 检查；返回前台刷新不会复活旧页。第二次验证发现的正是该取消作用域回归，第三次已修正并通过既有测试。

这些是应用层失效检查，**不是 Photos／OS 原子快照或绝对零竞态保证**：系统变化尚未发出通知，或发生在最后检查之后，仍有不可原子锁住的窗口。未公开 ID 的 revision 不逐页全量轮询；不能宣称所有系统变化瞬间都已被应用观察到。

源码：[../App/State/PhotoIndexWorker.swift](../App/State/PhotoIndexWorker.swift)、[../App/State/AppState.swift](../App/State/AppState.swift)、[../App/Photos/PhotoLibraryClient.swift](../App/Photos/PhotoLibraryClient.swift)。

## 历史 build 22 · 6. 三次整体验证与实际通过账本

|整体验证|run／job／完整源码 SHA|实际结果|
|---|---|---|
|第一次|[37206371854／111448298055](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37206371854/job/111448298055)；`a54648dcb5d1edf30ac0dedd2ba246adbaa33dfa`|FAILED：`DisplayThumbnailLoaderTests` 的嵌套 `[[Reply]]` 类型推断导致测试编译失败。|
|第二次|[37206758430／111449431771](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37206758430/job/111449431771)；`9a49844e968810aa43a558fef6333878b840bb4a`|FAILED：两项既有 `PhotoCheckPresentationTests` 多条断言失败；`AppState.cancel()` 在诊断取消时误清图库分页。|
|第三次|[37208795156／111455534540](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37208795156/job/111455534540)；`2c05008a74f3ec4df170de1b2fc1fb79a0bcec84`|SUCCESS：生产修复限定 idle／search 清页，无关诊断取消保留分页；加强既有图库快照断言，包含 session／候选总数。新 run attempt 1 是第三次整体验证。|

没有删除旧测试、放宽数值容差、延长超时或绕过 CI 门槛。第二次是生产回归，不能写成只有测试修正；既有两项诊断取消测试现已通过，并比以前多检查分页身份与候选数量。

|测试套件|实际通过数／秒|本轮新增|主要覆盖／证据边界|
|---|---|---:|---|
|[../Tests/DisplayThumbnailLoaderTests.swift](../Tests/DisplayThumbnailLoaderTests.swift)|33／2.250|33|几何／scale、HQ/Fast 顺序、可读低分辨率、3164、联网临时回调、错误优先级、重复回调与取消竞态。|
|[../Tests/PhotoThumbnailCacheTests.swift](../Tests/PhotoThumbnailCacheTests.swift)|15／0.035|15|双 revision、尺寸／网络／generation 键、编辑后当前像素、清空、权限与迟到结果。|
|[../Tests/ResultPaginationTests.swift](../Tests/ResultPaginationTests.swift)|18／0.571|18|37 项按 12→24→36→37 稳定前缀、分数 bit pattern、负分、全局中心、去重、失效、首屏／续页 ID 校验、3 张选项、一次翻译／编码。|
|[../Tests/ResultPaginationPresentationTests.swift](../Tests/ResultPaginationPresentationTests.swift)|3／0.705|3|真实 `ContentView`／`UIScrollView`，37 项按 12→24→36→37 追加、初始离屏边界不追加、小横向视口不重置。合成结果／未授权缩略图路径，不是 XCUI 物理手势、实际旋转或 Photos HQ 质量证明。|
|[../Tests/PhotoIndexWorkerTests.swift](../Tests/PhotoIndexWorkerTests.swift)|30／1.277|1|新增 25 项全局结果的真实 worker 分页校验、新 ID 越界／后续编辑拒绝、数据库未写与零像素请求；30 是整套总数。|
|[../Tests/PhotoCheckPresentationTests.swift](../Tests/PhotoCheckPresentationTests.swift)|20／1.434|0|修复第二次失败的两项既有测试对应的生产回归；图库快照增加 session／候选总数断言，保留原查询／结果／选择检查。|
|[../Tests/GeneratedModelParityTests.swift](../Tests/GeneratedModelParityTests.swift)|8／150.700|0|CPU、`.all`、真实 20 actor；20 actor 120 次预测／252 项测量和原 23／58 数值门槛全部保留。|
|新增合计|**70 项全通过**|**70**|33＋15＋18＋3＋1，已计入 App 总数，不与整套方法数重复相加。|

|整体门槛|实际结果|
|---|---|
|Swift 核心|79 全通过。|
|App XCTest|**662＝661 通过／1 项既有 SQLite 真机文件保护模拟器跳过／0 失败**；**237.412 秒，wall 244.696 秒**。比 build 21 的 592 新增 70 项。|
|独立 UI|**11 全通过／757.953 秒**；导航 **6／525.587 秒**、键盘 **5／232.366 秒**。真实设置交互从 **12 改为 3** 并核验保留；未授权真实 Photos，不证明真机图库或 HQ 清晰度。|
|设备构建|BUILD SUCCEEDED；**0.5.9 / 22、arm64 Release、未签名、最低 iOS 17、SDK 18.5、Xcode 16.4**。|

静态／资源检查、完整真实模型数值对齐、全部 App 及独立 UI 回归门槛保留，不以新增模拟测试替代。完整流程见 [../.github/workflows/ios.yml](../.github/workflows/ios.yml)；本次文档更新不重新执行该流程。App 子套件已计入 662，UI 另计，测试耗时不是手机性能。

## 历史 build 22 · 7. 当时交付资产与有限视觉复核

|资产／核验|实际记录|
|---|---|
|公开 Release|[ci-37208795156-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37208795156-1)，ID **403064885**，**2026-10-04T14:50:02Z** 发布；**9 项资产、prerelease、非 draft、非 Latest**。|
|本地原始 IPA|[../build/device-download/37208795156/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/37208795156/LocalImageIQ-iphoneos-unsigned.ipa)，asset **610020605**，**1,418,628,098 字节**；SHA-256 **`6244de326a29fe3daf22146dc4591f4d061a5565a21d051149e4a7f698dd9f28`**。完整流式长度／哈希 PASS，`ipaVerifiedLocally: true`。|
|归档完整性|**7-Zip 26.03 全量解压／CRC PASS**；11 文件夹、30 文件，解压后 **1,563,942,417 字节**。不验证重签后的包或手机安装。|
|UI ZIP|[../build/ui-review/37208795156/UIReview.zip](../build/ui-review/37208795156/UIReview.zip)，asset **610020492**，**5,851,186 字节**；SHA-256 **`46edd9ef2232bfd4b087c739903d5d6e0086922c2b1743cee18b5019c0544318`**，已下载核验。|
|小型 IPA 元数据|实际核验 **0.5.9 / 22、LaunchScreen**，原地点 FNV **`raycast-v1-93c9a925e35247f2`** 保持不变。|

配套文件：[设备报告](../build/device-download/37208795156/device-build.json)、[交付清单](../build/device-download/37208795156/delivery.json)、[校验文件](../build/device-download/37208795156/SHA256SUMS.txt)、[全量下载记录](../build/device-download/37208795156/release-fetch-95efc8a3-b875-4ebc-a17d-70005eb0295d.json)。

父流程实际**只查看 [1010×758 三图联系图](../build/ui-review/37208795156/result-paging-contact.jpg)**，三个原图均 **393×852**，见 [审核记录](../build/ui-review/37208795156/result-paging-review.json)：

- 第一张为真实 `ContentView` 追加 **24 项之后的滚动视口**，内容是无访问权限占位符及 TEST 水印，非真实照片。**24 项由测试状态断言确认，截图视口内没有 24 计数器，也不是同时可见 24 张照片**；底部“已索引 37 张”是已存索引统计，不能把 37 当作已显示数量或 24 项的视觉证明。
- 另两张是黑金深色／浅色设置夹具，均显示“**每批显示 12**”；UI 自动测试改成 3 的交互证据与这两张静态图分别记录，不能混作同一截图。
- 未读取／授权真实 Photos，没有其他图片审核、HQ 清晰度、物理 iPhone 手势或性能证明。原生 `UIScrollView` 测试不等于 XCUI 真实图库滚动验收。

## 历史 build 22 · 8. 当时安装、不变项与剩余风险

**原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载、不清索引、不重建**；已有当前策略有效索引复用，安装见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。本轮不变项包括索引 HQ224／Fast 策略、20 个索引 worker、手动索引、模型 FP32／`.all`、SQLite schema 与模型／索引／地点缓存身份、品牌和九步启动条逻辑。新版上下文首次启动可能按原规则显示条，见 [STARTUP_STEP_PROGRESS.md](STARTUP_STEP_PROGRESS.md)，不是新增模型步骤或索引迁移。

**仍待真机验收：**安装、实际 Photos HQ 清晰度及本地覆盖率、首屏／后续加载延迟、滚动性能与峰值／稳态 RSS 均未测。首次仍读取完整候选向量并全局排序，排序复杂度 **O(N log N)**；会话失效前保留完整 ID／向量，随显示增加也保留更多 tile／图像相关状态。分页减少初次展示与像素加载需求，不证明全量检索更快或内存有界；不为掩盖未测容量增加任意 ceiling、超时或静默降级政策。全屏旧 helper 未改，本轮不能宣称全屏 HQ 升级或任何目标像素尺寸的可用性保证。