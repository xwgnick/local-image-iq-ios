# 高质量结果缩略图与滚动分页

**2026-10-04｜0.5.9 / build 22：代码已实现，待 CI 验证，未宣称通过或交付。** 版本见 [项目配置](../project.yml#L19-L20)。最新已验证交付仍为 **0.5.8 / build 21**；本次只新增本文，不更新 [../README.md](../README.md) 或既有交付账本，不执行终端、CI、Git 或网络操作。

## 1. 用户行为

- 搜索默认先显示 **12 张**；滑到当前列表底部，再追加 **12 张**，直到全部候选显示完。最后不足一批则全部追加；空结果、不足 12 张及恰好 12 张不会生成多余页。
- 设置保留 **3 张 / 12 张**选项，但标签已改为“**每批显示**”。`resultLimit` 现在是显示批量，不是旧 Top-K 总结果上限；修改后清空当前结果，下次显式搜索生效。
- 同一会话只追加既有全局排序的前缀，保留查询、翻译结果、既有照片顺序和分数，不重置滚动容器或跳回顶部。继续往下显示的是候选，不代表都相关；没有新增分数阈值，负分也不被截掉。

## 2. 结果缩略图：本地 HQ 优先，不请求原图

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

源码：[../App/Photos/DisplayThumbnailLoader.swift](../App/Photos/DisplayThumbnailLoader.swift)、[../App/UI/PhotoViews.swift](../App/UI/PhotoViews.swift)、[缩略图客户端入口与校验](../App/Photos/PhotoLibraryClient.swift#L253-L296)。

## 3. 缓存与明确不变的路径

- 缓存键包含 asset ID、**索引中保存的 revision + 当前照片 revision**（修改／创建时间）、请求像素宽高、网络开关及图库 `changeGeneration`。另有缓存自身 generation token，`clear()` 后的旧请求不能重新填入缓存。
- 命中缓存前、异步加载后都检查权限、当前 revision、图库 generation 与清空 token；客户端还在首次请求、各回退阶段和返回前核对授权状态／revision／generation，拒绝过期结果。
- 照片已编辑但尚未手动更新索引时，仍可用**旧 embedding 搜索、当前 `.current` 像素显示**。两种 revision 不要求相等；加载显示图不重做索引、不写数据库。
- `NSCache` 按解码像素的 `bytesPerRow × height` 记 cost；这是内存核算，**没有设置 count/cost 上限或任意像素、字节、容量天花板**，不是固定内存预算或 RSS 保证。
- **全屏旧 `displayImage` 未改变**：仍是离线 Fast／联网 HQ、`.aspectFit` 与 `.fast` resize；全屏当前页仍请求 `PHImageManagerMaximumSize`。不要把本轮网格 HQ 改善描述为全屏也已升级。
- **旧索引 HQ224 输入策略、模型及缓存身份未改变**；显示 HQ 不是索引 HQ224 的替代。本轮不要求清索引或重建，手动索引策略仍保留。

源码：[../App/Photos/PhotoThumbnailCache.swift](../App/Photos/PhotoThumbnailCache.swift)、[旧全屏加载入口](../App/Photos/PhotoLibraryClient.swift#L298-L338)、[../App/UI/PhotoGallery.swift](../App/UI/PhotoGallery.swift)、[../App/Photos/IndexingImage.swift](../App/Photos/IndexingImage.swift)。

## 4. 全局排一次，按需显示，不是数据库分页

`AppState.search()` 只解析／按需翻译查询一次，只调用一次 worker，传入 **`limit: Int.max`**。worker 对当前可访问且索引身份有效的完整候选集编码查询、计算全局地点中心与精确分数，再统一排序一次；沿用既有分数公式和 UTF-8 asset ID 同分排序，没有按页重新去均值、重新打分、截断或增加筛选阈值。

`ResultPages.response` 持有**完整 `[SearchHit]`**，其中 `IndexedPhoto` 仍携带图像向量和可能存在的地点向量；`results` 只是逐渐增长的可见前缀。**这是显示分页，不是有界内存分页，也不是数据库游标／分批读取。** 排序和页校验不请求照片像素；tile 按 SwiftUI 布局需求加载，不全图库预加载像素。懒布局可能预创建邻近 tile，不承诺只有屏幕内 tile 才会发图像请求。

分页由列表末尾 1 pt 的 `ResultPageBoundary` 发送命名滚动坐标系下的几何 preference；仅当 `minY < viewportHeight && maxY > 0`，即边界与可见视口相交时请求下一批，**不是 LazyVGrid cell 的 `onAppear`**。事件携带会话 UUID 与当时已显示数量；`loadMoreResults` 核对前台、非忙碌、同会话、数量精确匹配及尚有余项，拒绝重复、旧会话和错误边界事件。全部显示后移除边界。

源码：[搜索与追加](../App/State/AppState.swift#L344-L380)、[../App/UI/ResultPageBoundary.swift](../App/UI/ResultPageBoundary.swift)、[滚动视口与查询定位](../App/UI/ContentView.swift#L14-L47)、[可见边界判断](../App/UI/ContentView.swift#L288-L291)、[../Packages/ImageIQCore/Sources/ImageIQCore/VectorSearch.swift](../Packages/ImageIQCore/Sources/ImageIQCore/VectorSearch.swift)。

## 5. 发布前校验与会话失效

1. **初次 worker：**捕获授权状态和图库 generation，完整枚举当前授权照片；在解码向量、地点去均值及打分前过滤不可访问 ID。保留打分前、打分后两次完整快照复核，加上最初快照，共三次完整枚举。搜索只读，不删除或重写旧索引。
2. **首屏与续页：**跨 actor 后在 MainActor 同步调用 `SearchResponse.validatePageAccess`；全局检查授权状态与图库 generation，但 revision 查询只针对**本次将公开的 ID**。首屏验证前 12 个，后续只验证新增 12 个／最后余项；空首屏也做全局校验。不是每一页重查完整结果的所有 revision。
3. PhotoKit 通知到达时先同步增加 `changeGeneration`，再排 MainActor 回调；所以即使界面通知尚未处理，已收到的变化也能使页校验失败。页校验前后复查授权／generation，失败则清空整个结果会话与缩略图缓存并要求重新搜索，不保留混合新旧页。
4. 新查询、查询编辑、地点权重／每批数量／中文搜索开关变化、取消、后台、刷新、图库变化，以及手动索引或清索引都会清除 continuation、结果、选择与已完成查询信息。旧异步任务仍受取消和 operation token 检查；返回前台刷新不会复活旧页。

这些是应用层失效检查，**不是 Photos／OS 原子快照或绝对零竞态保证**：系统变化尚未发出通知，或发生在最后检查之后，仍有不可原子锁住的窗口。未公开 ID 的 revision 不逐页全量轮询；不能宣称所有系统变化瞬间都已被应用观察到。

源码：[响应验证接口](../App/State/PhotoIndexWorker.swift#L49-L66)、[worker 全局搜索与分页验证](../App/State/PhotoIndexWorker.swift#L467-L537)、[会话清除与首屏发布](../App/State/AppState.swift#L479-L570)、[Photos 同步通知 generation](../App/Photos/PhotoLibraryClient.swift#L130-L136)。

## 6. 测试账本与剩余风险

下列是**已写入源码的新增 XCTest 方法数，不是已通过数**：

|套件|新增|主要覆盖|
|---|---:|---|
|[../Tests/DisplayThumbnailLoaderTests.swift](../Tests/DisplayThumbnailLoaderTests.swift)|33|几何／scale、HQ/Fast 顺序、可读低分辨率、3164、联网临时回调、错误优先级、重复回调与取消竞态。|
|[../Tests/PhotoThumbnailCacheTests.swift](../Tests/PhotoThumbnailCacheTests.swift)|15|双 revision、尺寸／网络／generation 键、编辑后当前像素、清空、权限与迟到结果。|
|[../Tests/ResultPaginationTests.swift](../Tests/ResultPaginationTests.swift)|18|37 项按 12→24→36→37 稳定前缀、分数 bit pattern、负分、全局中心、去重、失效、首屏／续页 ID 校验、3 张选项、一次翻译／编码。|
|[../Tests/ResultPaginationPresentationTests.swift](../Tests/ResultPaginationPresentationTests.swift)|3|真实 ContentView／滚动容器的离屏边界不追加、滚动触发追加至耗尽、横向小视口不重置。|
|[新增 worker 校验测试](../Tests/PhotoIndexWorkerTests.swift#L727-L745)|1|25 项全局结果分批验证、新 ID 越界／后续编辑拒绝、数据库未写与零像素请求。|
|合计|**70**|均计入 App XCTest，不另算到独立 UI 套件。|

以 build 21 的 App **592** 项为基线，本轮预计 **592 + 70 = 662**；最终执行、通过、失败与跳过数量必须以 CI 原生报告为准。既有默认值断言已改为 12，并保留精确顺序、分数、向量、权重等断言，不能通过删除测试或放宽容差迁就分页。3 项原生展示测试使用合成搜索结果、真实未授权缩略图路径，**不是真实 Photos HQ 清晰度、物理旋转或 XCUI 手势证明**；尚未取得本轮原生运行／截图验收证据。

静态检查、资源检查、完整真实模型数值对齐、全部 App 测试及既有独立 UI 回归门槛保持，不以新增模拟测试替代或跳过；完整验证流程见 [../.github/workflows/ios.yml](../.github/workflows/ios.yml)。本次仅写文档，未执行这些门槛。

**未测风险：**首次仍读取完整候选向量并全局排序，排序复杂度 **O(N log N)**；会话失效前保留完整结果及其向量，随显示增加也保留更多 tile／图像相关状态。手机首屏耗时、滚动性能、HQ 本地覆盖率、峰值／稳态 RSS 均未测。分页减少初次展示与像素加载需求，不证明全量检索更快或内存有界；不为掩盖未测容量增加任意 ceiling、超时或静默降级政策。