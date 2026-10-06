# 搜索加速：架构、精度与测量边界

**DELIVERED：0.9.0 / build 27 已完成原生验证、设备构建、发布和本地 IPA 校验，是当前已交付版本。**最终功能源码 `ca5422c9473fed58a938120e3643c6de4f19e47c`；[CI 37468042819](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37468042819)／[job 112283955268](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37468042819/job/112283955268) **SUCCESS**。该 run 为 attempt 1，是功能整体第四轮验证；**第三轮也已 SUCCESS，不是四次失败**。前三轮之间 App 生产代码未变、只修测试；第四轮依据第二轮初步冷路径基准修改 bulk pack/unpack、共享去重地点数据及 Double 矩阵批量构建。

> **首搜冷建回退，冷路径目标未达成：**最终合成基准首次 SQLite 建缓存 **19,863.360208 ms**，同查询原路径 **11,943.924667 ms**；原／新加速比仅 **0.6013×**，即新路径耗时约 **1.66 倍**。同进程驻留后的 3 个不同查询中位数为 **13,351.559875 → 197.506458 ms（67.600624×）**；新 worker 的 binary 首读 **5,712.517833 ms（同查询 2.0908×）**，仍不是设备重启实测。**已经证明的是合成 warm 检索组件收益，不是所有搜索 10×；真机端到端 10× 仍未验证，首搜继续优化待完成。**

目标仍是用户实际搜索达到 **10×**，不是先显示 1 张、缩小候选集、降低画质或把成本隐藏到启动。最终基准是 DEBUG 模拟器的真实临时 SQLite＋假 Photos 元数据＋合成查询 lookup encoder；没有真实模型／翻译／OCR／照片像素／UI 发布或分页校验，不控制 OS 缓存，也没有真实进程重启。第 10 节为最终实测，第 11 节单独保留第二轮历史，不能混用。版本配置见 [../project.yml](../project.yml)，当前概要见 [../README.md](../README.md)；旧交付账本见 [BUILD_STATUS.md](BUILD_STATUS.md)。

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
- 第四轮预分配 Double 矩阵，用 `vDSP_vspdp` 批量执行 Float→Double 精确转换；不归一化每行、不修改原始向量或评分公式。
- 图库向量形状、有限值和同地点向量一致性在快照构建时验证一次并供后续查询复用；每个新查询仍验证权重、limit、维度和有限值，零结果请求也不跳过验证。
- 地点按原始 UTF-8 字节去重、排序；每个唯一地点仍用原顺序 Double 标量点积，按相同字节顺序累加均值，不按照片频率加权。缺地点的残差仍为零。
- 图像使用 CPU Accelerate `vDSP_mmulD` 一次覆盖所有候选行，再按原公式融合地点项；不只算首屏，也不归一化、截断或钳制分数。
- 第四轮改用 `vDSP_svesqD` 求非负平方和，并以保守 gamma 误差界作除法修正、向外舍入，得到数学范数上界；不能把批量平方和直接当成精确值，也不是先逐行归一化。原有范数上界证明与逐位认证契约保留。
- IEEE 舍入误差区间同时覆盖批量与原顺序归约的差异，仍以该范数上界、`gamma(2D)` 和下溢绝对误差项构造，再向外传播融合运算。
- 只有区间两端转成 Float 后 `bitPattern` 相同，且计算值同位且有限，才接受批量结果；否则该行退回原始左到右 Double 标量点积。不是容差近似，正负零也不能用 `==` 混过。
- 全量排序保留分数降序、ID 的 UTF-8 字节升序、重复 ID 的原输入顺序兜底；省掉全量请求的满尺寸 heap，不省候选或最终排序。
- Accelerate 原生调用本身不能中途取消；前后检查取消，其余构建、校验、修正和排序有协作检查。边界/异常形状仍保留参考路径及原错误语义。

## 3. 独立派生缓存、首次建设与重新载入成本

实现见 [../App/Persistence/SearchIndexCache.swift](../App/Persistence/SearchIndexCache.swift)。运行时独立文件名为 search-vectors-v1.bin，不替换或迁移 SQLite 源库。
- binary plist 封装元数据与 little-endian 原始 Float 位模式字节；不是 JSON 数值重编码，也不保存 Double 矩阵。照片修订、创建时间、模型、地点文本及 geography 版本保留。
- 第四轮仅优化 bulk pack/unpack：通过原始 Float `Data` 批量复制并保持正确 little-endian 字节序，共享已验证、字节完全相同的地点 `Data`，避免逐元素及重复地点转换。派生 binary 仍为 **v1、相同字节格式**，文本原始字节语义不变，不新增格式版本或迁移源库。
- key 绑定模型 UTF-8、完整授权 ID scope 的长度分帧 SHA-256、**整个源数据库字节**的 SHA-256；header/payload checksum、结构、向量与 scope 检查通过后才复用。
- warm resident 依靠同一条持久只读 SQLite 连接的 `PRAGMA data_version`，结合设备/inode/resource identity、大小及文件时间检查；不同连接的 data_version 不可直接比较，替换文件必须重开监测连接。
- 安全稳定的 warm 命中不重新全库 hash、不重新 JSON 解码，也不重建矩阵；scope 身份和源状态检查仍存在，不是零成本访问。

|状态|本次显式搜索必须计入的成本|
|---|---|
|首次 SQLite 路径|完整源库流式 SHA（64 KiB 块）＋授权范围 SQLite/JSON 读取与验证＋binary 编码/写盘＋Double 矩阵构建。|
|同进程 resident|源状态/scope 检查、驻留记录与矩阵复用；新查询编码、评分、统计、访问校验等仍执行。|
|驻留释放后 binary 路径（如后台恢复／重启）|仍完整 hash 源 SQLite；读取整个派生文件、校验及 binary 解码，再重新构建 Double 矩阵。不是 mmap 零拷贝或“重启即内存热”；第 10 节只测同进程新 worker，不是实际后台切换或进程重启。|

- 首个数据库／授权 scope 的首次加速搜索会承担冷建成本；源库或 scope 变化可能使派生缓存失效。最终夹具冷建耗时约为同查询原路径的 **1.66 倍**，没有达到首搜加速目标。
- 初始化、启动和普通刷新不创建该缓存；只有显式加速搜索才可能写派生文件，不写源库、不 prune、不重新编码照片，也不额外加载 CPU-only 模型副本。
- 源库缺失时跳过派生文件创建及目录创建，不能以旧 binary 代替不存在的源库；损坏/截断/不匹配的派生文件退回一次原只读 SQLite loader。
- 无法安全监测、保留写锁、journal/WAL/SHM 等情况绕过磁盘及驻留复用；loader 结果使用独立签名，避免误复用矩阵。派生写入失败不阻断可用搜索。
- 已确认的源消失/变化和取消不能吞掉；读取、hash、写入发布边界都检查源状态。可访问源数据的实际错误保留，不能用派生缓存掩盖或自动重试。
- 临时文件原子 rename 发布；失败回滚按文件对象身份只撤掉自身发布物。缓存自己的 `clear()` 仅删除精确派生文件及自身临时文件，不递归清目录或删源/OCR 库。
- 用户原有“清除索引”仍由 worker 分别清派生、图像和文字索引；这与派生缓存单独清理不是同一语义。搜索只读源库的字节一致性由合成测试断言，未冒充用户真库实测。

## 4. 内存、生命周期与隐私

- 8,000 × 768 × 4 字节的原始 Float32 图像载荷为 **24,576,000 B（约 23.44 MiB）**；额外 packed Double 矩阵为 **49,152,000 B（46.875 MiB）**，两者合计约 **70.31 MiB**。这是载荷计算值，**不是全 App RSS**，绝不是“总共约 24 MB”。
- 还需记录/ID/地点元数据、范数与索引、全量 hits/排序/查询 scratch；冷构建另有 SQLite JSON、binary 编码和 `Data` 缓冲的瞬时开销。未测 RSS、CPU 峰值、峰值内存或发热。
- 进入后台立即撤销结果页、选择/预览与图库快照，清缩略图；取消当前任务并**等待排空后**释放 worker 驻留矩阵、缓存记录和只读监测连接，磁盘派生文件保留。
- Photos 变化先同步推进 epoch，再由 `AppState` 撤销可见结果；同样把排空/释放接入队尾，**刷新之前释放**旧授权 scope，不能等下一次查询才清。
- 前台恢复使快照失效并走原刷新；新任务等待上述释放尾链。手动图像索引先失效搜索内存；没有新增 TTL、容量上限、定时淘汰或自动后台重建。
- 因此回前台下一次查询即使命中磁盘 binary，也要读取／校验并重建矩阵；不能把连续前台 warm 的约 **0.198 s** 承诺成“每次打开都约 0.2 s”。
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
- 真机验收应分别看排名发布、首图和分段瓶颈；有充分样本后再汇总 P50/P95。**App 目前只有最新一次内存报告，没有历史采集或自动 P50/P95；本次只有 3 个不同查询、冷建和 binary 各 1 次，不足以形成正式 P50/P95 或置信结论。**不要求用户机械重复 20 次查询，也不以评分局部倍速承诺整体 10×。

### 最简真机使用／可选比较

1. 用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**第 12 节的 build 27；**不卸载、不清索引、不为升级重建**，有效当前向量直接复用。
2. 默认加速 ON，**直接正常搜索即可**，无需为了使用功能开调试。第一次为当前数据库／scope 准备缓存可能更慢；保持前台后换不同查询观察 warm，不把这一阶段与后台恢复后的首搜混记。
3. 需要具体数字时，再开 **设置 → 显示调试工具 → 诊断信息 → 搜索耗时**，记录最新报告；“使用原搜索作对照”开关只作用于下一次显式搜索。同一查询、相同设置做 A/B，另记首次准备及 warm；隐藏调试即恢复默认加速。中文翻译与查询编码未改，仍可能限制整体收益。

## 8. 构建账本：成功、优化与交付分开记录

前三轮历史保留；最终交付绑定第四轮源码与资产，不把第二轮的局部基准通过写成整轮成功，也不把第三轮成功改写成失败。

|轮次|源码 commit|run / job|已知结果|
|---|---|---|---|
|第一轮|`7c7a79856ad3396073fb4f72e41da37f5380d4e9`|`37458924577` / `112253292188`|FAILED：测试编译失败，[PhotoSearchSnapshotTests.swift](../Tests/PhotoSearchSnapshotTests.swift#L455) 当时访问 `Task.value` 缺少 `try await`。|
|第二轮|`b96b1eeb7e5b033ff93a449ce2d05b5c3a58985d`|`37459851841` / `112256414011`|仅修测试编译。原生 App 执行 1205 项、skip 1；**同一个缓存测试内 2 个断言失败**，恢复的 mtime 显示相等但 `Date` 精度下不严格相等。其余 App 测试（含全部 bit parity 与两个基准）通过；UI 14 项通过，743.936 s。|
|第三轮|`5e8360731ea2c5b0cf45bbf1a505045ba6d75e49`|`37462788954` / `112266263119`|仅修测试：在构造缓存**之前**设置固定整秒时间，保留严格 mtime 相等断言。**2026-10-06T13:04Z completed / SUCCESS**；当时未查询完整测试数量/耗时，未下载该轮 IPA、未作为最终交付。|
|第四轮|`ca5422c9473fed58a938120e3643c6de4f19e47c`|`37468042819` / `112283955268`|**SUCCESS／DELIVERED**。第三轮成功后，依据第二轮实际基准进行计划内生产优化：缓存批量装包/解包、共享已验证地点 `Data`、预分配 Double 矩阵及向量化转换/平方和。最终测试、基准和资产见下文；冷建仍回退。|

第二轮失败证据取自 **DRAFT `404674626`**，UI asset `615440231`，**6,771,580 B**，SHA-256 `02e95c39259daf3809321ce13f120b0c01b7844d42bc824218642110917b77b4`。该 draft 保留、未发布；该轮基准通过不改变整轮 FAILED 的事实。

## 9. 第四轮最终原生执行结果

**Core 79 通过；App 1215 项 = 1214 通过／1 既有 SQLite 物理保护测试跳过／0 失败**，测试耗时 **324.087 s**、墙钟 **349.439 s**。既有 Generated 模型组 **8 项／121.399 s** 通过，保留全部 **20 actor、CPU／`.all`** 数值对齐；这不是合成性能夹具内的真实模型推理测量。UI **14 项／945.081 s** 全通过，**本功能没有新增 live UI 导航测试，不能声称实际“诊断信息 → 搜索耗时”导航已获端到端验证**。

新增搜索相关 **149** 项均已在最终原生执行中通过，不再只是静态预期数：

|测试文件|通过数|主要契约|
|---|---:|---|
|[../Tests/ResidentSearchIndexTests.swift](../Tests/ResidentSearchIndexTests.swift)|27（原 24＋3）|全序列 Float bits、UTF-8/中心/边界/取消；含 1 个 scorer 基准。|
|[../Tests/SearchIndexCacheTests.swift](../Tests/SearchIndexCacheTests.swift)|36（原 29＋7）|scope/源变化/替换/原始位/损坏回退/只读/派生清理。|
|[../Tests/PhotoSearchSnapshotTests.swift](../Tests/PhotoSearchSnapshotTests.swift)|35|观察生命周期、漏通知窗口、批量校验及无观察者回退。|
|[../Tests/AcceleratedSearchWorkerTests.swift](../Tests/AcceleratedSearchWorkerTests.swift)|20|新旧路径精确对照、OCR/筛选/seed、全局最终检查及缓存失效。|
|[../Tests/SearchTimingTests.swift](../Tests/SearchTimingTests.swift)|14|时钟分段、并发、冻结、隐私标签与首图补充。|
|[../Tests/SearchAccelerationStateTests.swift](../Tests/SearchAccelerationStateTests.swift)|13|参数捕获、模式切换、取消、排空释放与会话隔离。|
|[../Tests/SearchTimingPresentationTests.swift](../Tests/SearchTimingPresentationTests.swift)|2|原生合成计时页、最大字体滚动。|
|[../Tests/SearchThumbnailTimingTests.swift](../Tests/SearchThumbnailTimingTests.swift)|1|新会话缓存命中仍回调，不再请求像素。|
|[../Tests/SearchPipelinePerformanceTests.swift](../Tests/SearchPipelinePerformanceTests.swift)|1|8,000 × 768 SQLite/冷建/warm/binary 合成比较。|

合计 **149 = 27＋36＋35＋20＋14＋13＋2＋1＋1**（初版 139＋第四轮 10）；相较 build 26 的 App 1066 项，最终实际执行 **1215** 项。第二轮的 1205 项属于优化前版本，不能替代最终执行记录。
- `TIMINGS-ResidentSearchIndex-8000x768`：3 个不同合成 query，完整候选的 scorer-only 对照，单列矩阵构建时间及 scalar fallback 数；不含 SQLite/PhotoKit/模型/UI。
- `TIMINGS-search-pipeline`：真实临时 SQLite 及生产 worker/cache/scorer，对照 3 个不同 query、首次冷建、3 次不同-query warm、新 worker 的 binary 首读；断言全部 8,000 个排序 ID 与 Float bits 一致，检查源与 binary 字节未变。
- 后者仍用假图库与 encoder lookup，**没有真实 CoreML 推理输入链**、Translation、PhotoKit 像素、首屏发布/首图或 OCR；同进程新 worker 不等于真正重启，系统缓存状态未控制。真实模型既有 parity 测试与此性能夹具不可混称。
- 两个 `TIMINGS` 基准**已在第四轮原生执行并通过，最终附件已读取核对**，数字见第 10 节；第二轮历史独立保留在第 11 节。没有时间通过门槛，测试通过不等于冷建或手机端到端 10× 目标达成。
- 计时页截图附件 `UIReview-search-performance-dark` 使用明确 TEST 合成数字，不是实测首图截图或性能验收；不能与 `TIMINGS` 实际基准混同。最终原生截图已查看，具体可见范围见第 12 节；**真机收益仍待验证**。

## 10. 第四轮最终基准：冷建回退与 warm 收益分别报告

实际读取并核对的最终证据属于 run **`37468042819`**，不是第二轮文件：
- [../build/ui-review/37468042819/TIMINGS-search-pipeline.json](../build/ui-review/37468042819/TIMINGS-search-pipeline.json)
- [../build/ui-review/37468042819/TIMINGS-ResidentSearchIndex-8000x768.json](../build/ui-review/37468042819/TIMINGS-ResidentSearchIndex-8000x768.json)

### 10.1 测量边界与 fixture

DEBUG 模拟器，真实临时 SQLite 和生产 worker/cache/scorer，**8,000 × 768** 合成向量、**8 个不同地点、8,000 条全部有地点**，地点权重约 **0.6**。数据库 **82,264,064 B**、binary **25,264,085 B**、图像向量 JSON **75,729,381 B**。矩阵载荷 **49,152,000 B Double＋24,576,000 B Float32**，不是 RSS，冷建还有 JSON／binary 缓冲等瞬时开销。

计时从 recorder 创建到 awaited worker 返回并结束，**没有真实 CoreML／tokenizer／翻译／OCR／PhotoKit 或 HQ 照片像素／UI 发布／首图／分页访问检查**。图库是假的元数据遍历与真实版本化快照缓存；编码器为合成查询 lookup。报告虽用“排名已发布”结果标签，这个夹具实际只测 worker 返回，不能据标签宣称页面已显示。

fixture 创建、独立 hash/header 核对、parity 断言和清理不计入时间；**搜索自身的完整源 hash、SQLite JSON 读取、binary 编码／写入／解码及矩阵构建均按路径计入**“读取索引／准备缓存”，未分别测内部子项。顺序固定，准备／参考读取在冷建前，binary hash/header 读取在新 worker 前；**OS 缓存未清理或控制，没有真正进程重启**。

### 10.2 首次冷建与 binary 首读：必须与同查询原路径比较

|最终测量项|同查询原路径（ms）|新路径（ms）|原／新加速比与结论|
|---|---:|---:|---|
|首次 SQLite 冷建（1 次）|11943.924667|19863.360208|**0.6013×；耗时约 1.66 倍，首搜明显回退，冷路径目标未达成。**|
|同进程新 worker 的 binary 首读（1 次）|11943.924667|5712.517833|**2.0908×**；含完整源 hash、binary 校验／解码和矩阵重建，不是真实进程启动。|

冷建的“读取索引／准备缓存”为 **19,713.135458 ms**；binary 首读该段为 **5,601.690000 ms**。不能从这些聚合时间精确归因各内部子项，也不能用原路径三查询中位数替换这里的同查询分母，以美化冷路径倍数。**67.6× 的 warm 收益不能掩盖首次 19.863 s 的回退。**

### 10.3 不同查询的 resident warm：仅合成组件收益

原路径三个不同查询实测为 **[11943.924667, 14087.185583, 13351.559875] ms**，中位数 **13351.559875 ms**；warm 三个不同查询为 **[175.900250, 197.506458, 201.297125] ms**，中位数 **197.506458 ms**。两者中位数之比 **67.600624×**。

两组执行顺序不同，不能按上面数组位置直接配对；最终附件内的同查询对照如下：

|同查询原路径（ms）|resident warm（ms）|原／新加速比|
|---:|---:|---:|
|14087.185583|175.900250|80.086217×|
|13351.559875|197.506458|67.600624×|
|11943.924667|201.297125|59.334800×|

同查询配对倍数的中位数也为 **67.600624×**。每次对照均要求**全部 8,000 个结果 ID 顺序及 Float `bitPattern` 完全一致**，不是只验 top-k 或容差相等；冷建、3 次 warm、新 worker binary 共 5 项同查询对照，并检查源与 binary 字节不变。没有缓存查询向量或结果，warm 使用不同查询，不是重复同一句制造加速。

**这只是一次固定顺序运行的 3 个查询，没有正式置信区间、可靠 P50/P95 或设备推广结论。**数据超过 10× 的是合成 warm 组件对照；真实翻译、查询编码和 Photos／UI 开销未测，不能称所有搜索或手机端到端目标已达成。

### 10.4 独立评分基准：不能替代 worker／首搜时间

独立 scorer fixture 同样 **8,000 × 768**，但使用 **17 个唯一地点**（不是 worker fixture 的 8 个）。3 个不同查询，原标量评分累计 **5,685.800375 ms**，加速评分累计 **93.299667 ms**，比值约 **60.94×**；**矩阵构建另需 1,535.667 ms**，不包含在这个评分比值中。逐行标量 fallback 数 **[2, 2, 3]**，所有 hits 的 ID 顺序及最终 Float bits 一致；scorer 全部 **27 项测试通过**。

该构建时间包含验证、地点元数据、分配、批量 Float→Double 转换与经认证的范数上界；评分计时不含 SQLite、PhotoKit、模型或 UI。既不能用它代表完整搜索，也不能把矩阵构建或冷建成本遗漏后宣称首搜 60.94×。

## 11. 第二轮历史基准：非第四轮、非真机端到端

证据属于 run **`37459851841`**，两个基准已执行并通过：
- [../build/ui-review/37459851841/TIMINGS-search-pipeline.json](../build/ui-review/37459851841/TIMINGS-search-pipeline.json)
- [../build/ui-review/37459851841/TIMINGS-ResidentSearchIndex-8000x768.json](../build/ui-review/37459851841/TIMINGS-ResidentSearchIndex-8000x768.json)

### 11.1 生产 worker/cache/scorer 合成路径

DEBUG 模拟器，真实临时 SQLite，**8,000 × 768** 合成图像向量、8 个不同地点、全部 8,000 条都有地点，权重 **0.6**，主对照为 **3 个不同查询**。实际原始数据库 **82,264,064 B**，binary **25,264,085 B**，图像向量 JSON **75,729,381 B**；不是用户真图库。

|历史测量项|时间 / 比值|边界|
|---|---:|---|
|原路径，3 个不同查询中位数|11,161.374 ms|该合成 worker 对照，不含真实查询模型等未测环节。|
|resident warm，3 个不同查询中位数|169.837 ms|与原路径配对；两者中位数之比 **65.718 ≈ 65.7×**，仅适用于此夹具。|
|重复同一个查询，中位数|65.521 ms|单独记录，不替代不同查询的 warm 比较；没有查询 embedding 缓存。|
|首次 SQLite 冷建|19,778.393 ms|包含源 hash、SQLite/JSON 读取、binary 写入及矩阵构建，不隐藏一次性成本。|
|新 worker 的 binary 首读|10,620.386 ms|包含完整源 hash、记录解码与矩阵构建；**同进程新 worker，不是真实进程重启，也未清 OS 缓存**。|

这些是第二轮固定源码的原始历史记录，不以最终数字覆盖：约 **11.161 s／0.1698 s／65.7×／冷建 19.778 s／binary 10.620 s**。冷建实测比当轮原路径查询中位数更慢，不能用 warm 的 65.7× 掩盖回退。第四轮针对装包/解包和矩阵构建后，最终 binary 首读测得 **5.713 s**；**10.620 → 5.713 s 是跨 CI 运行的观察，不是同一 runner／缓存状态的受控因果对照，不能把差值全部归因于某项代码优化**。最终冷建仍为 **19.863 s**，以第 10 节同查询配对明确报告回退。

### 11.2 独立评分基准

3 个不同查询的原标量评分累计 **5,467.852 ms**，加速评分累计 **79.7065 ms**，比值约 **68.6×**；另计矩阵构建 **2,383.532 ms**，不包含在上述评分倍数中。各查询逐行标量 fallback 数为 **[2, 2, 3]**；全部 N 条最终排序 ID 与 Float 位模式严格一致，不是只核验 top-k 或容差通过。

### 11.3 不得外推的范围

上述计时使用假 PhotoKit 元数据与 encoder lookup，**不含真实 ML 推理、翻译、OCR、照片像素读取、UI 发布及分页发布 guards 的耗时**；更不是实体 iPhone 测量、设备冷启动或完整用户搜索。68.6× 为评分局部比值，65.7× 为合成 worker warm 对照，均不能发布成“手机搜索快 65×”或“端到端 10× 目标已达成”。启动没有新增建库/预热，也不把搜索冷成本暗移至启动；真机端到端收益仍待验证。

## 12. 最终发布、包校验与原生截图边界

- [公开 Release：ci-37468042819-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37468042819-1)，ID **404761088**，绑定源码 `ca5422c9473fed58a938120e3643c6de4f19e47c`；发布于 **2026-10-06T13:40:41Z**，**9 项资产、prerelease、非草稿**。
- 本地包：[../build/device-download/37468042819/LocalImageIQ-0.9.0-build27-iphoneos-unsigned.ipa](../build/device-download/37468042819/LocalImageIQ-0.9.0-build27-iphoneos-unsigned.ipa)，远端资产 **615633249**，**1,419,250,307 bytes**；**完整文件流式 SHA-256** 为 `71e72cc990d46f396e310d1e8db255a5deb0b2654381408a7daf02ebfa0b0637`。**7-Zip 26.03 CRC PASS**：11 个目录、30 个文件、解压总计 **1,566,761,261 bytes**。
- 本地下载核验记录：[../build/device-download/37468042819/release-fetch-28779eb8-f29e-45c4-a6b6-3524e3414cd1.json](../build/device-download/37468042819/release-fetch-28779eb8-f29e-45c4-a6b6-3524e3414cd1.json)。UI 附件资产 **615632868**，**6,771,321 B**，SHA-256 `a8a31c7cf383782a9ef33b19c49fc2fb5caa1e33e11e7418e573ec4b53b3adf9`；IPA 下载记录本身不冒充 UI 审核记录。
- 小体积 IPA 条目核验为 **0.9.0／27、Launch Screen、arm64 Release、SDK 18.5／Xcode 16.4、最低 iOS 17**；仍为未签名包，需本机 Sideloadly 签名。模型身份／维度 **768**、地点数据 hash 与既有包一致；**没有完整模型权重逐字节比较**，包完整性不等于真机性能或实际照片画质证明。
- 最终已实际查看 [原生搜索计时页预览](../build/ui-review/37468042819/search-performance-review.jpg)，**370×758**，来自 **1 张 393×852 原生截图**。黑金页显示 **0.300 s 到排名、0.400 s 到首缩略图、8000 候选、内存驻留、矩阵／图库快照复用**，这些均为带 TEST 标识的**合成展示值，不是最终 benchmark 实测**。底部分段需滚动，该截图不覆盖整页；最大字体滚动测试通过也不等于整页人工可见审核或实际入口导航 E2E。

本功能新增的是 App 内原生呈现／状态等测试，既有 UI 14 项继续通过；**没有新增真实诊断导航 UI 测试，也没有真实 Photos／HQ 首图或屏幕 scan-out 端到端性能证据**。首次可用缩略图回调不保证 HQ；不能把合成截图中的 0.400 s 写成手机首图耗时。

## 13. 尚未完成的性能目标

1. **优先继续降低首次 SQLite 冷建成本**，这是已观察到的回退，未因交付而视为解决；hash、JSON、binary 和矩阵的内部子项仍需独立测量后定位，不能先宣称哪个子项已被完全消除。
2. 真机上分别观察首次准备、后台释放后 binary 首读、连续不同-query warm、排名发布与可用首图；保持同查询／同设置 A/B，不卸载、不清索引、不额外重编码，也不将启动隐藏预热作为达标手段。
3. 补齐真实翻译／查询编码／Photos 元数据与像素／发布及分页开销、RSS 峰值和发热证据。**手机端到端 10×、首搜达标及稳定 P50/P95 均待验证，没有保证。**现有图片质量、首批 12 张与完整检索范围不作为性能交换条件。