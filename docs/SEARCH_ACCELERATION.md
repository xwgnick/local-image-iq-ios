# 搜索加速：架构、精度与测量边界

**0.9.0 / build 27：PENDING。最后已交付版本仍为 0.8.0 / build 26。**
目标是用户实际搜索达到 **10×**，不是先显示 1 张照片、缩小候选集或降低缩略图质量制造的 UI 提速。
当前是待验证的实现与测试契约；**尚未证明真机端到端达到 10×**，没有提前承诺加速倍数。
版本配置见 [../project.yml](../project.yml)，已交付记录仍以 [BUILD_STATUS.md](BUILD_STATUS.md) 为准。

## 1. 执行路径与不变项

- [../App/State/AppState.swift](../App/State/AppState.swift) 捕获查询、翻译/OCR 开关、地点权重、筛选及对照模式，经原串行任务链等待前任务排空，再调用 worker。
- [../App/State/PhotoIndexWorker.swift](../App/State/PhotoIndexWorker.swift) 串接图库快照、模型准备、索引读取、查询编码、统计、评分、OCR、筛选与发布校验。
- 默认加速仅用于具备 `PhotoSearchSnapshotting` 能力的图库；旧注入图库、参考模式保留原 SQLite 读取和 `VectorSearch` 评分路径，不触碰派生缓存。
- 模型权重、精度、CoreML 配置、图像预处理、768 维索引身份、地点算法、手动索引及缩略图质量策略不变；没有 Float16、模型量化、Metal/GPU 搜索或 ANN。
- 没有查询结果/查询向量缓存，也没有重做 Apple Translation 会话；每次普通文字搜索仍解析/翻译并编码查询。中文翻译的固定成本和真实文本模型推理仍可能主导总耗时。
- 启动仍按原契约准备模型/分词器并读取保存的统计；没有自动启动额外 CPU-only 模型、图像推理、读像素、重建索引或全图库预热。搜索缓存建设成本不转移到启动中隐藏。
- OCR 关闭的普通搜索不打开文字库；启动/刷新原有只读 OCR 统计不因该开关而改变，不能把“搜索不读 OCR”说成“启动也不读”。

## 2. 驻留评分：最终 Float 逐位一致

实现见 [../App/Inference/ResidentSearchIndex.swift](../App/Inference/ResidentSearchIndex.swift)；未修改的参考算法见 [../Packages/ImageIQCore/Sources/ImageIQCore/VectorSearch.swift](../Packages/ImageIQCore/Sources/ImageIQCore/VectorSearch.swift)。
- 不可变快照保留原始 `IndexedPhoto` / Float32 向量，另建行连续的 Double 图像矩阵；不是把原始向量替换为低精度表示。
- 图库向量形状、有限值和同地点向量一致性在快照构建时验证一次并供后续查询复用；每个新查询仍验证权重、limit、维度和有限值，零结果请求也不跳过验证。
- 地点按原始 UTF-8 字节去重、排序；每个唯一地点仍用原顺序 Double 标量点积，按相同字节顺序累加均值，不按照片频率加权。缺地点的残差仍为零。
- 图像使用 CPU Accelerate `vDSP_mmulD` 一次覆盖所有候选行，再按原公式融合地点项；不只算首屏，也不归一化、截断或钳制分数。
- IEEE 舍入误差区间同时覆盖批量与原顺序归约的差异，以向外舍入的范数上界、`gamma(2D)` 和下溢绝对误差项构造，再向外传播融合运算。
- 只有区间两端转成 Float 后 `bitPattern` 相同，且计算值同位且有限，才接受批量结果；否则该行退回原始左到右 Double 标量点积。不是容差近似，正负零也不能用 `==` 混过。
- 全量排序保留分数降序、ID 的 UTF-8 字节升序、重复 ID 的原输入顺序兜底；省掉全量请求的满尺寸 heap，不省候选或最终排序。
- Accelerate 原生调用本身不能中途取消；前后检查取消，其余构建、校验、修正和排序有协作检查。边界/异常形状仍保留参考路径及原错误语义。

## 3. 独立派生缓存与真实冷启动成本

实现见 [../App/Persistence/SearchIndexCache.swift](../App/Persistence/SearchIndexCache.swift)。运行时独立文件名为 search-vectors-v1.bin，不替换或迁移 SQLite 源库。
- binary plist 封装元数据与 little-endian 原始 Float 位模式字节；不是 JSON 数值重编码，也不保存 Double 矩阵。照片修订、创建时间、模型、地点文本及 geography 版本保留。
- key 绑定模型 UTF-8、完整授权 ID scope 的长度分帧 SHA-256、**整个源数据库字节**的 SHA-256；header/payload checksum、结构、向量与 scope 检查通过后才复用。
- warm resident 依靠同一条持久只读 SQLite 连接的 `PRAGMA data_version`，结合设备/inode/resource identity、大小及文件时间检查；不同连接的 data_version 不可直接比较，替换文件必须重开监测连接。
- 安全稳定的 warm 命中不重新全库 hash、不重新 JSON 解码，也不重建矩阵；scope 身份和源状态检查仍存在，不是零成本访问。

|状态|本次显式搜索必须计入的成本|
|---|---|
|首次 SQLite 路径|完整源库流式 SHA（64 KiB 块）＋授权范围 SQLite/JSON 读取与验证＋binary 编码/写盘＋Double 矩阵构建。|
|同进程 resident|源状态/scope 检查、驻留记录与矩阵复用；新查询编码、评分、统计、访问校验等仍执行。|
|重启后 binary 路径|仍完整 hash 源 SQLite；读取整个派生文件、校验及 binary 解码，再重新构建 Double 矩阵。不是 mmap 零拷贝或“重启即内存热”。|

- 初始化、启动和普通刷新不创建该缓存；只有显式加速搜索才可能写派生文件，不写源库、不 prune、不重新编码照片，也不额外加载 CPU-only 模型副本。
- 源库缺失时跳过派生文件创建及目录创建，不能以旧 binary 代替不存在的源库；损坏/截断/不匹配的派生文件退回一次原只读 SQLite loader。
- 无法安全监测、保留写锁、journal/WAL/SHM 等情况绕过磁盘及驻留复用；loader 结果使用独立签名，避免误复用矩阵。派生写入失败不阻断可用搜索。
- 已确认的源消失/变化和取消不能吞掉；读取、hash、写入发布边界都检查源状态。可访问源数据的实际错误保留，不能用派生缓存掩盖或自动重试。
- 临时文件原子 rename 发布；失败回滚按文件对象身份只撤掉自身发布物。缓存自己的 `clear()` 仅删除精确派生文件及自身临时文件，不递归清目录或删源/OCR 库。
- 用户原有“清除索引”仍由 worker 分别清派生、图像和文字索引；这与派生缓存单独清理不是同一语义。搜索只读源库的字节一致性由合成测试断言，未冒充用户真库实测。

## 4. 内存、生命周期与隐私

- 8,000 × 768 × 4 字节的原始 Float32 图像载荷约 **23.44 MiB**；额外 Double 矩阵为 **46.875 MiB**，两者合计约 **70.31 MiB**，绝不是“总共约 24 MB”。
- 还需记录/ID/地点元数据、范数与索引、全量 hits/排序/查询 scratch；冷构建另有 SQLite JSON、binary 编码和 `Data` 缓冲的瞬时开销。未测 RSS、CPU 峰值、峰值内存或发热。
- 进入后台立即撤销结果页、选择/预览与图库快照，清缩略图；取消当前任务并**等待排空后**释放 worker 驻留矩阵、缓存记录和只读监测连接，磁盘派生文件保留。
- Photos 变化先同步推进 epoch，再由 `AppState` 撤销可见结果；同样把排空/释放接入队尾，**刷新之前释放**旧授权 scope，不能等下一次查询才清。
- 前台恢复使快照失效并走原刷新；新任务等待上述释放尾链。手动图像索引先失效搜索内存；没有新增 TTL、容量上限、定时淘汰或自动后台重建。
- 派生向量仍是敏感照片信息，不能因“不含原图”视为公开数据；与源缓存采用相同文件保护（首次解锁后可用）并排除备份。
- 诊断只记录本地固定标签、数量、模式和时长，不记录原始照片、OCR 正文、查询、照片 ID、坐标、路径或原始错误；不上传，也不持久化计时历史。
- 源 SHA 与缓存 checksum 用于身份/损坏校验，**不是安全签名、认证或抵御同权限篡改的证明**；派生文件本身含向量及必要元数据，不是匿名日志。

## 5. PhotoKit 快照与不能省掉的全局校验

实现见 [../App/Photos/PhotoSearchSnapshot.swift](../App/Photos/PhotoSearchSnapshot.swift) 与 [../App/Photos/PhotoLibraryClient.swift](../App/Photos/PhotoLibraryClient.swift)。
- 观察者已实际注册且授权/epoch 不变时，可复用初始完整修订快照，评分前用授权/epoch 校验；Photos 事件使旧快照失效，保留 fetch 的更新不等于逐行增量计算。
- **worker 最终始终重新完整枚举图库**并比较全部修订，包含未返回照片；因此未送达通知的全局删除/编辑也不能悄悄改变唯一地点集合和全局中心后仍发布旧评分。
- 稳定且观察者有效时，冷查询通常 **2 次完整元数据遍历**（初始＋最终），warm 为 **1 次**（最终）；原路径为 **3 次**。这不是总 PhotoKit API 调用数，也不是确定倍速。
- 未注册观察者时，快照 validators 会退回完整读取，次数可能更多；不把 epoch 单独当作全局新鲜证明。旧图库实现及参考模式仍保留原来的 3 次完整枚举。
- 首屏及后续页在 MainActor 发布时，对本页 ID 做一次新的 **batch** 修订校验，并始终包括相似搜索 seed（即使不在结果中）；批量前后检查授权/epoch。
- 这些边界不构成跨 PhotoKit/SQLite 的原子事务。后台、撤权、通知或选中项变化使旧会话失效；不能保证库在最终检查之后永远不再改变。
- 元数据筛选仍保留额外 PhotoKit 获取/遍历，见 [../App/Photos/PhotoSearchMetadata.swift](../App/Photos/PhotoSearchMetadata.swift)；首屏批量验证没有消除这些开销。
- 缩略图每 ID 的原有权限、修订及缓存前后 guards 仍保留，见 [../App/Photos/PhotoThumbnailCache.swift](../App/Photos/PhotoThumbnailCache.swift)；没有完成“把所有逐图检查压成一次”的优化。

## 6. 检索与分页语义

- `AppState` 请求 `Int.max`，对完整可访问的当前模型索引先全局评分/排序，再 OCR 融合、筛选和 seed 排除；12 张仍只是显示页大小，非只搜 12 张或先出 1 张。
- OCR 使用原查询，只匹配当前修订的有效图像候选；视觉模型使用有效译文。原全量排名的 RRF 与显示的原视觉分数保留；无文字命中/OCR 关闭不改原排序与 score bits。
- 找相似仍读原缓存图像向量作 query，地点权重为零、排除 seed，保留当前筛选；不翻译、不文本编码、不读像素或重索引。
- 日期/相册/类型筛选只裁剪全局排名，不提前改变地点中心；可访问但编辑过的照片仍按原手动更新契约使用旧视觉向量，新照片不会自动加入索引。
- 后续分页不重译、不重新编码/评分；查询、筛选或诊断模式等设置变更撤销旧会话，捕获参数及 token 校验防止混入新设置的结果。

## 7. 本地分段计时与真机比较口径

实现见 [../App/State/SearchTiming.swift](../App/State/SearchTiming.swift) 与 [../App/UI/SearchTimingView.swift](../App/UI/SearchTimingView.swift)。
- 从搜索请求入口开始，依次覆盖：排队/前任务等待、翻译、快照、模型准备（可能已缓存）、索引读取/缓存准备、查询编码、统计、评分前检查、评分排序、OCR、筛选、最终检查、排名发布。
- 区间互不重叠，重复阶段仍累加；冷路径 hash/编码/写盘/矩阵成本包含在“读取索引／准备缓存”，尚无这些内部子项的独立计时。取消/失败报告截止于该次结束。
- “到首张缩略图”从**同一搜索起点**算，排名发布后首次可用图片回调补充；不与排名时长相加，不保证 HQ、原图或屏幕 scan-out，也不是“先显示一张”的加速措施。
- `ContentView` 按结果 session 标识重建缩略图身份，缓存命中也回调；`AppState` 只接受当前会话、当前可见照片的首次回调，旧 cell 不能更新新搜索报告。
- 入口：**设置 → 显示调试工具 → 诊断信息 → 搜索耗时**；同处“使用原搜索作对照”只在下次显式搜索生效，session 默认 OFF（即默认加速）。
- 隐藏调试恢复的仅是参考基线开关，并关闭诊断展示，不重置地点权重、模型或普通用户偏好；若模式实际改变则撤销旧搜索会话，不自动发起搜索。
- 对照保持同一图库/scope、同一查询、权重、筛选和 OCR/翻译配置；分别比较英文、中文翻译、OCR ON/OFF。每个模式逐条用完全相同查询配对，而一般 warm 评估使用不同查询，不反复刷一句。
- 首次 SQLite 建设、进程重启后的 binary 读取与同进程 warm 分开报告；启动耗时另列，不能把冷成本挪到启动或拿已暖系统缓存冒充设备冷启动。
- 真机验收应分别看排名发布、首图和分段瓶颈，汇总 P50/P95；**App 目前只有最新一次内存报告，没有历史采集或自动 P50/P95**。不要求用户机械重复 20 次查询，也不以评分局部倍速承诺整体 10×。

## 8. 已编写测试与待验证证据

以下是源码中的 XCTest 方法数，**不是 build 27 已运行/已通过的数量**：
|测试文件|方法数|主要契约|
|---|---:|---|
|[../Tests/ResidentSearchIndexTests.swift](../Tests/ResidentSearchIndexTests.swift)|24|全序列 Float bits、UTF-8/中心/边界/取消；含 1 个 scorer 基准。|
|[../Tests/SearchIndexCacheTests.swift](../Tests/SearchIndexCacheTests.swift)|29|scope/源变化/替换/原始位/损坏回退/只读/派生清理。|
|[../Tests/PhotoSearchSnapshotTests.swift](../Tests/PhotoSearchSnapshotTests.swift)|35|观察生命周期、漏通知窗口、批量校验及无观察者回退。|
|[../Tests/AcceleratedSearchWorkerTests.swift](../Tests/AcceleratedSearchWorkerTests.swift)|20|新旧路径精确对照、OCR/筛选/seed、全局最终检查及缓存失效。|
|[../Tests/SearchTimingTests.swift](../Tests/SearchTimingTests.swift)|14|时钟分段、并发、冻结、隐私标签与首图补充。|
|[../Tests/SearchAccelerationStateTests.swift](../Tests/SearchAccelerationStateTests.swift)|13|参数捕获、模式切换、取消、排空释放与会话隔离。|
|[../Tests/SearchTimingPresentationTests.swift](../Tests/SearchTimingPresentationTests.swift)|2|原生合成计时页、最大字体滚动。|
|[../Tests/SearchThumbnailTimingTests.swift](../Tests/SearchThumbnailTimingTests.swift)|1|新会话缓存命中仍回调，不再请求像素。|
|[../Tests/SearchPipelinePerformanceTests.swift](../Tests/SearchPipelinePerformanceTests.swift)|1|8,000 × 768 SQLite/冷建/warm/binary 合成比较。|

合计 **139**；按 build 26 的 App 1066 项推算，预期 **1205**，仍以实际原生测试发现/执行结果为准，不能写成已通过。
- `TIMINGS-ResidentSearchIndex-8000x768`：3 个不同合成 query，完整候选的 scorer-only 对照，单列矩阵构建时间及 scalar fallback 数；不含 SQLite/PhotoKit/模型/UI。
- `TIMINGS-search-pipeline`：真实临时 SQLite 及生产 worker/cache/scorer，对照 3 个不同 query、首次冷建、3 次不同-query warm、新 worker 的 binary 首读；断言全部 8,000 个排序 ID 与 Float bits 一致，检查源与 binary 字节未变。
- 后者仍用假图库与 encoder lookup，**没有真实 CoreML 推理输入链**、Translation、PhotoKit 像素、首屏发布/首图或 OCR；同进程新 worker 不等于真正重启，系统缓存状态未控制。真实模型既有 parity 测试与此性能夹具不可混称。
- 两个 `TIMINGS` 名称是原生运行时预定生成的附件，不是已有实测数值；没有时间通过门槛，也不是手机端到端 10× 证据。
- 唯一计划的计时页截图附件为 `UIReview-search-performance-dark`，含明确 TEST 合成数字；不是实测首图截图或性能验收。build 27 原生结果、截图审核与真机收益均 **PENDING**。