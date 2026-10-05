# 照片文字搜索

**0.7.0 / build 25：待原生 CI 验证，未交付（PENDING-NATIVE / PENDING-ARTIFACTS / NOT-DELIVERED）。**

版本来自 [../project.yml](../project.yml)。当前已交付版本仍是 **0.6.0 / build 24**，见 [BUILD_STATUS.md](BUILD_STATUS.md)；旧包不包含本功能。build 25 的原生测试结果、截图审阅、设备 IPA、发布及本地包校验均待完成，不能以源码或测试数量代替交付证据。

## 1. 怎么用

用于补充查找截图、票据、招牌等照片中的文字，不替代原来的图片语义搜索。

1. 打开「设置 → 照片文字 → **文字搜索增强**」。**默认关闭；明确切换后的开／关选择会持久保存，重启恢复**，不是每次启动重置的调试开关。它与「中文搜索增强」（查询翻译）相互独立。
2. 点击「**更新文字索引**」，保持应用在前台。开启后「我的图库」也显示相同入口；仅开启开关、打开页面或搜索都不会自动识别照片。
3. 在原搜索框输入原文即可，不需要专用搜索语法。有有效文字命中时，结果区提示「已结合照片文字」；查看、筛选、选择、分享、收藏、加入相簿等仍用原控件。
4. 可点「暂停文字索引」。进入后台或关闭增强也会取消当前文字更新；已提交记录保留，返回前台／重新开启不会自动续跑，需再次手动更新。

按钮需要照片可读权限、搜索模型已就绪、已知且非零的图片索引计数、前台且没有其他工作。**仅开启开关不会请求照片权限，也不会自动开启 iCloud 下载。**

未来 build 25 正式交付后，用原 Sideloadly 账号及原有效 Bundle ID **覆盖安装，不卸载、不清库、不为升级重建图片索引**。已有有效图片向量可复用；想用新功能，只需开启并手动更新文字索引。新增或编辑过的照片例外：先更新图片索引，再更新文字索引。

入口与持久化：[../App/UI/PhotoTextIndexSection.swift](../App/UI/PhotoTextIndexSection.swift)、[../App/State/AppState.swift](../App/State/AppState.swift)、[../App/LocalImageIQApp.swift](../App/LocalImageIQApp.swift)。生产环境通过 `UserDefaults.standard` 保存 `photoTextSearchEnabled.v1`；未注入偏好存储的测试实例不代表生产开关只在会话内有效。

## 2. 手动索引与启动边界

- 候选限定为**当前有权限访问、已有当前模型／图片输入策略索引**的照片；图片记录的 revision 必须与当前照片一致才做 OCR。已有图片记录但 revision 过期的计入「已变化跳过」，未建图片索引的不会自动补入。
- 文字更新独立于图片向量：只检查模型身份、读取图片 ID／revision 和计数，**不解码图片向量、不调用图片或文字向量编码器、不加载额外 Core ML 权重、不解析地点边界，也不改写图片索引**。原有启动模型准备和图片索引的 20 worker 不因此改变。
- 冷启动、回前台、图库通知及普通统计刷新**不自动扫描照片、不做 OCR、不清理文字记录**。文字统计只读已保存元数据；数据库不存在就返回零，不创建目录、数据库或迁移。
- 可选文字统计读取失败时，显示统计不可用，不阻断图片模型就绪、刷新或图片索引完成；取消仍按取消处理，不能吞成普通统计警告。统计不是当前授权可搜索数量，也不验证识别正确性。
- 每次手动文字更新先按当前合格 ID／revision／策略清理过期文字记录。相同 ID、revision、策略且非 `isReduced` 的记录可复用，**成功识别为空也是真实完成记录**。小图／降质记录照样保存并参与搜索，但下次手动更新会重试；没有后台升级或轮询。
- 普通读取／识别失败及离线需云端项目只计数，**不把错误或部分识别保存为完成**；后续项目可继续。权限丢失、访问变化、取消和存储错误会停止本次工作。「已检查」包含跳过／失败，不等于都识别成功。

实现：[../App/State/PhotoIndexWorker.swift](../App/State/PhotoIndexWorker.swift)、[../App/Persistence/SQLitePhotoStore.swift](../App/Persistence/SQLitePhotoStore.swift)、[../App/Photos/PhotoTextModels.swift](../App/Photos/PhotoTextModels.swift)。

## 3. Vision、像素来源与内存

使用 **iOS 系统 Vision 本机 OCR**：`VNRecognizeTextRequestRevision3`、`.accurate`，语言明确为 `zh-Hans`、`zh-Hant`、`en-US`；关闭自动语言检测，开启语言纠正，`minimumTextHeight = 0`。实际识别时检查该 revision／模式支持的语言，缺失则报错，不悄悄换版本或删减语言。初始化和启动不构造识别请求或探测语言能力；没有新增随 App 分发的 OCR 模型权重或 OCR 云服务。

像素经 PhotoKit `.current` 获取，**所有阶段均为整幅 `.aspectFit`，不是裁剪后的网格缩略图**。保留实际 CGImage，并把八种 UIKit 方向正确转换为 EXIF 方向交给 Vision；记录应用方向后的实际像素宽高，不拿请求尺寸或 UIImage 点数充当返回尺寸。

|顺序|请求与条件|
|---|---|
|1|本地 HQ：目标为照片原生像素宽高，`.highQualityFormat` / `.exact`，网络关闭。即使已允许 iCloud，也先试本地。|
|2|本地 HQ224：第一阶段不足或缺资源时，按原比例、短边 224、`.highQualityFormat` / `.fast` 请求。小图仍可作为候选。|
|3|仍不足且用户原先已明确允许 iCloud 时，才请求原生目标尺寸的联网 HQ；不强制联网。|
|4|只有所有已尝试的 HQ 都没有可读像素，才尝试本地 Fast224；不会用 Fast 掩盖已有 HQ 候选。|

沿用共享候选策略：优先非明确降质，再比方向修正后的双轴像素覆盖，平局保留先返回者；达到目标且未明确降质可提前结束。联网 HQ 等最终回调；普通错误、权限错误或取消会中止，不因已有候选而隐藏错误。网络选项只控制 PhotoKit 资源，OCR 本身在设备执行。

`isReduced` 依据实际双轴覆盖、降质标志及 Fast／未知来源，不设最低像素拒绝门槛。**非 reduced、HQ 标签或 degraded=false 都不是清晰度／OCR 准确率保证**；细字可能遗漏。这里的「原生／原图尺寸」仅描述请求目标，**不表示返回了原始 RAW、原始文件或足量真实细节**，实际返回仍可能很小。

文字索引**一次只处理一张照片**，不会把整库全尺寸图放入数组；但没有固定像素／内存上限。单次回退可能同时保留前一候选与新候选，再叠加像素转换及 Vision 缓冲，仍可能存在数份很大的图像／缓冲，不能据串行处理保证峰值内存安全。

实现：[../App/Photos/VisionPhotoTextRecognizer.swift](../App/Photos/VisionPhotoTextRecognizer.swift)、[../App/Photos/PhotoLibraryClient.swift](../App/Photos/PhotoLibraryClient.swift)、[../App/Photos/DisplayThumbnailLoader.swift](../App/Photos/DisplayThumbnailLoader.swift)、[../App/Photos/DisplayThumbnailResult.swift](../App/Photos/DisplayThumbnailResult.swift)。

## 4. 搜索与排序规则

1. 图片语义分支仍使用原来的有效查询（可能经过中文→英文翻译）；**文字分支始终使用用户原始查询，包括原始中文，而不是英文译文**。筛选重搜复用已经完成的原文／译文选择。
2. 先在当前可访问的图片索引全集计算原有图片＋地点排序，**不改变地点去重均值、原始分数或向量**。仍可访问但已编辑的图片可沿用旧图片向量，直到手动更新；其旧文字不得加分。
3. 文字读取先取交集：当前授权 ID、当前模型／图片策略下的已索引 ID、图片与当前照片精确相同的 revision、相同 revision 的文字记录及当前 OCR policy。**在解码 OCR 正文或计分前完成资格筛选**；文字不能引入未索引、失去权限、旧策略或过期照片。
4. 将完整图片排序与完整合格文字排序做等权 **RRF，常数 60**；不先截取前 12／Top-K。名次从 1 开始，有文字命中时贡献相加：$1/(60+r_{图片})+1/(60+r_{文字})$，未命中文字贡献为零，平局按原图片名次。
5. **融合后**才按日期／相簿／类型筛选并截取结果；原默认每批 12 张的分页、追加及权限／revision 校验继续使用同一完整排序快照，不在翻页时重新翻译、编码或 OCR。这不是数据库级分页。

**RRF 是实验性排序选择，不是已校准的相关性权重。**没有把 OCR 分数与图片原始分数直接相加。`SearchHit.score` 仍是原图片＋地点诊断分数，原浮点位保留；混合结果**不再按该诊断分数排序**，不能据其大小判断新列表顺序或概率。

- 开关关闭：走原图片搜索路径，不打开文字库；即使文字库损坏，图片搜索仍可用（前提是原图片路径正常）。
- 开关开启但无合格文字命中／文字库尚不存在：结果顺序与原分数精确保持，不假装已建立文字索引。
- 开关开启而文字库实际读取失败：**本次搜索明确报错，不静默退回图片结果**。这与启动时可选统计失败隔离是两种不同情况。
- 「找相似」始终只用已有图片向量，不查询 OCR，不做查询翻译或新图片编码；搜索本身也不会补扫 OCR。

### 文字匹配不是语义理解

正文保存汉字单字及相邻双字项；查询的连续汉字段长 ≥2 时只用双字项，单字字段用单字项。非汉字字母／数字按连续完整词项处理；统一大小写、宽度及 Unicode 规范形式，标点会截断词项。

文字分数为**命中的不同查询词项数 ÷ 全部不同查询词项数**（OR 匹配），若规范化后的完整词项序列连续出现，再加 1；同分按 ID 稳定排序。没有 NLP 分词、查询意图理解、OCR 语义向量或语义嵌入检索，也没有 TF-IDF／全库统计影响。

因此「北京大学」可能部分命中「北京饭店」；**很弱的局部命中也可能经 RRF 把图片抬高**。数字按完整词项匹配：单独查询 `123` 不匹配 `1234`，也不匹配连续标识符 `ABC123`；但连字符／标点是边界，`ABC-123` 会拆成两个词项，多词查询又采用 OR。混合查询「订单123」仍可能因「订单」部分命中「订单1234」，不能把完整数字规则误读成整条查询严格相等。短语加分基于规范词项序列，不是原始标点逐字一致。

匹配与融合：[../App/Persistence/SQLiteTextStore.swift](../App/Persistence/SQLiteTextStore.swift)、[../App/Photos/PhotoTextModels.swift](../App/Photos/PhotoTextModels.swift)。

## 5. 保存、权限与清除

- 独立运行时数据库名为 **text-index.sqlite3**，schema **1**；保存 ID、revision、OCR policy、原始识别文字、实际像素尺寸、降质状态及词项索引。当前 policy 为 `vision-ocr-r3-accurate-zh-en-fit-v1`。**图片数据库 schema、图片模型／输入策略版本不变**，不因增加 OCR 使已有有效图片向量失效。
- 目录和文字数据库设置 `completeUntilFirstUserAuthentication` 文件保护及备份排除；使用 DELETE journal。**原始 OCR 可能包含证件、地址、票据信息等敏感内容**；这是受系统文件保护的本机数据库，不是额外的应用层加密承诺。OCR 正文不进入日志、进度或上传；错误使用固定通用描述，不透出照片 ID、路径或识别内容。
- 页面「已识别／含文字／降低分辨率」统计当前 OCR policy 的**已保存记录**，包含成功空结果及可能已无权限的旧记录，不代表当前授权范围、可搜索覆盖率或准确率。
- **权限撤回／有限授权缩小后，不再让失去访问权的照片参与搜索，但不会自动删除旧 OCR 正文。**旧文字留在本机，直到具备可读权限后完成手动文字更新中的清理，或用户主动清除索引。普通图片索引更新也不清理文字库；不能宣传“撤权即擦除”。
- **关闭增强不会删除文字。**「清除索引」会删除本机图片、地点和文字索引，不删除原照片；UI 没有单独清除文字的按钮。
- **「全部重建索引」也先删除文字索引**，然后只重建图片／地点索引；文字仍需另行手动更新。不要为启用 OCR 而清除或全部重建。两个库的清除是依次进行，文件删除也不是跨库原子事务或物理安全擦除保证。

清除提示：[../App/UI/SettingsSheet.swift](../App/UI/SettingsSheet.swift)、[../App/UI/LibrarySheet.swift](../App/UI/LibrarySheet.swift)。

## 6. 取消与提交边界

`AppState` 的串行任务链会先取消并**等待前一项真正结束**，再启动后续工作。Vision 在自己的 actor 上同步执行；取消会调用请求的 `cancel()`，但仍等 `perform` 返回后才视为排空，不提前报告工作已结束，也不另起脱离生命周期的 OCR 任务。晚到结果和旧进度不能覆盖新状态。

保存前后检查权限、图库变化代数及照片 revision；`SQLiteTextStore.save` **进入存储 actor 后、提交前再执行同步访问验证**。正文、元数据与新旧词项在同一 SQLite 事务提交，验证失败／取消会回滚该事务，已提交前缀可手动续用。

**Photos 与 SQLite 无法原子锁定。**最终检查后发生的权限／照片变化不能保证撤销已提交记录；后续搜索仍重新检查资格。不能把这些边界检查描述成“照片授权变化与 SQL 提交绝对原子一致”。

## 7. 测试清单与待验证项

以下按当前源码中实际 `func test…` **方法定义静态计数**，不是断言数、循环场景数或执行通过数；**本版本未据此宣称运行通过，原生 CI 待验证**。

|来源|方法数|源码所含范围|
|---|---:|---|
|[../Tests/VisionTextRecognitionTests.swift](../Tests/VisionTextRecognitionTests.swift)|35|含 4 项真实 Vision 合成图片识别；另含配置、方向、降质、共享像素回退、错误及取消排空。|
|[../Tests/TextIndexStoreTests.swift](../Tests/TextIndexStoreTests.swift)|24|持久化、词项／数字边界、资格先于正文解码、只读不建库、事务回滚、保护／备份属性及手动清理。|
|[../Tests/TextIndexWorkerTests.swift](../Tests/TextIndexWorkerTests.swift)|29|图片 revision 候选、无编码副作用、续跑／降质重试、可选统计失败隔离、完整排序与权限、关闭／无命中不变、显式搜索失败及两库清除。|
|[../Tests/TextHybridRankingTests.swift](../Tests/TextHybridRankingTests.swift)|7|完整名次、等权 RRF60、重复／越界 ID、稳定平局、诊断分数位保持。|
|[../Tests/PhotoTextStateTests.swift](../Tests/PhotoTextStateTests.swift)|20|默认关闭与偏好持久化、无自动 OCR、忙碌／后台／取消排空、原文与译文分流、筛选复用、统计知识及会话失效。|
|[../Tests/PhotoTextPresentationTests.swift](../Tests/PhotoTextPresentationTests.swift)|4|原生宿主内设置／进度展示、开关不触发工作、最大辅助功能字体滚动；使用合成计数，不识别照片。|
|**上述 App 测试合计**|**119**|静态源码清单，非已通过测试报告。|
|[../UITests/PresentationNavigationTests.swift](../UITests/PresentationNavigationTests.swift)|**1 项本功能方法**|`testPhotoTextOptInDoesNotIndexOrAskPhotosPermission`；实际 UI 开关、隐私文字与重启持久化，不是该文件全部方法数。|

真实 Vision 识别恰为以下 **4 项，已包含在 35 中，不重复加总**；注入的只有合成像素，不伪造 OCR 输出，也不因模拟器／缺少 App 模型而跳过：

- `testNativeVisionServiceRecognizesSyntheticEnglish`
- `testNativeVisionServiceRecognizesSyntheticChinese`
- `testNativeVisionServiceRecognizesEXIFRotatedSyntheticEnglish`
- `testNativeVisionBlankImageIsSuccessfulEmptyText`

独立 UI 方法在显式无模型测试模式下会跳过；不等于这 4 项 Vision 测试会跳过。展示测试源码预设两张审阅图：`UIReview-photo-text-settings-dark`、`UIReview-photo-text-progress-dark`，**实际产物与审阅仍 PENDING**。文件保护的物理设备属性断言也不能用模拟器替代。

**尚无 build 25 原生通过／发布／IPA 校验证据；尚无手机中文／英文准确率、真实 PhotoKit 本地可用率、有限授权端到端、耗时／峰值内存／大图库覆盖结论。**合成图片测试、状态测试和展示夹具都不能替代这些验收。