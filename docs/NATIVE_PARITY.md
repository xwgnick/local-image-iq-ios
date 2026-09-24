# Native generated-model parity — SigLIP 2 / schema 2

## Current: 0.3.4 (10) — all eight native parity tests passed; 20-slot gate and IPA verified

源码 `3381fa6750f8efa76aa0895a72963c2d56a497f5` 的
[CI 35991227461](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461)
／[job 107605532969](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461/job/107605532969)
已 **SUCCESS，首轮通过，无需修复重跑**；日志确认 `TEST SUCCEEDED` 和设备
`BUILD SUCCEEDED`。本次 **8 个 GeneratedModelParityTests 全部通过（94.326 秒）**，
包括真实 20 图像 actor 的生产工厂；build 10 IPA 完整下载及本地长度／SHA-256
校验已完成。以下是本次实际结果，不借用 build 9／8 通过记录，也不代表真机性能。

### 当前生产工厂：120 次预测／252 项测量已实际执行并通过

`testIndexingImageFactoryAllSlotsConcurrentPreviewParity` 本次实际使用生产
`makeIndexingImageEncoders()`、一个中央 owner 及 **20 个真实独立图像模型 actor**，
不是仅用 mock 或把 20 个任务排进同一个图像 actor。复用 1 个常驻主图像 actor，
另 19 个仅图像 actor 懒加载；生产索引在所有子任务结束后释放这些额外 actor 的
作用域持有。中央只有 **1 个文本模型＋1 个 tokenizer**，不是 20 套图文模型。

- 6 个真实生成资源夹具 × 20 个生产槽＝**120 次预测**；同一组 actor 跨夹具复用，
  不逐图创建模型。每个夹具要求每槽恰有一个输出；夹具内部并发，六个夹具依次运行。
- 120 个已归一化输出各与两份归一化原始参考比较＝**240 项向量比较**；保持
  768 维、输出 norm error ≤ 1e-5、图像余弦 ≥ 0.995。不能再次归一化 App 输出
  来掩盖其归一化错误，不放宽阈值。
- 6 项 direct-CGImage／native-data 张量比较＋6 项 native／HF 诊断张量比较
  ＝**12 项张量测量**，按夹具测一次，不是每槽各 12 项。合计 **252 项**。
  诊断像素误差不是新增 bit-exact Pillow 门槛。
- 保留 EXIF、原始 **68×120／112×199** 等夹具像素，直到生产预处理执行 224×224
  缩放；不在测试侧先放大图。夹具是合成数据，不是私人图库或 PhotoKit 实测。
- 原 `testAppEncodersModelSizedPreviewAndAllTextReferenceParity` 独立保留：
  **23 次预测（6 图像＋17 文本）、46 项向量比较＋12 项张量测量＝58 项**，
  原阈值不变。120／252 不替换、也不放宽原 23／58 门槛。

以上计数与数值门槛**均已实际断言通过**。工厂测试每夹具等待 20 路完成
是测试分组，不是生产批次调度；生产窗口把进行中与完成待顺序提交一起计入 **20**，
每顺序提交一项才补位，慢队首可阻塞补位，不是每 20 张一批。父任务顺序处理地点、
写库及保存后进度；取消／错误退出取消并等待所有子任务，迟到 PhotoKit 回调仍忽略。
有效缓存命中不取图、不图像推理，纯缓存扫描不懒加载额外 19 份图像模型。

19 份额外模型及并发张量是用户明确批准、将用 **iPhone 15** 测试的高内存实验，
**可能被 iOS 终止**。不静默加限制或自动缩回 4，不保证引用释放后系统立即归还内存。
独立 actor、`.all` 或模拟器测试都不能证明硬件同时执行 20 路、比四槽快 5 倍，
也不保证整库索引或重开续跑一定完成；速度／内存／发热为 PENDING-DEVICE。

### 当前输入策略、迁移与非数值回归

模型仍是同一 SigLIP 2 配对、**768 维／FP32**、同一 `modelVersion`、tokenizer、
预处理和 **2,943 要素地点包**；改变的是输入策略，由实际发布的
`photokit-preview-v1` 切换为 **`photokit-hq224-fast-fallback-v1`**。
先请求短边目标 224 的 `.highQualityFormat`、网络关闭；仅本地资源不可用才请求
同目标 `.fastFormat`、网络仍关闭。保留 `.aspectFit`／`.current`／
`resizeMode = .fast`，不调用原图 API。可用像素立即接受，含 reduced／degraded
或单次回调；取消、权限／授权失败、无像素普通错误均不触发兜底。只有两路本地均无
资源且用户已显式允许联网，才允许第三路高质量联网请求，默认仍关闭。

下一次 Index / resume 自动重新编码旧策略行，不手动 Clear index。旧行在新行
成功提交前不进入搜索或当前有效计数，迁移中覆盖可能减少甚至为 0，排名可能变化；
不能承诺搜索不变。已提交且仍有效的新策略行可复用，Fast 兜底行也缓存、不自动
提升质量。模型不变不等于旧输入策略仍兼容。

地点文本缓存同样以完整的 `IndexImagePolicy.cacheVersion` 为键，旧策略地点文本向量
不能跨此次迁移复用；新策略内相同地点文本仍共享缓存，只需编码一次。

新策略与 20 actor 的依据是源码及测试，不声称设备报告含有输入策略字段。
下列 App 子套件已计入总数，不重复相加；耗时不是手机性能测量。

| 测试／交付项 | build 10 实际结果 |
| --- | --- |
| Swift 核心／App | 核心 79 通过；App 270 项：269 通过、1 项真机文件保护在模拟器跳过、0 失败；122.720 秒。 |
| `IndexingImageRequestTests` | 38 项全部通过；0.694 秒。此前实际 26 项，不是 25 项；新增 12 项。 |
| `IndexPipelineTests` | 19 项全部通过；1.124 秒；顺序窗口、缓存、取消／续跑与持久化由此独立验证，不由数值测试代证。 |
| `LocalPreviewComparisonTests` | 18 项全部通过；0.074 秒；三路诊断保持原行为。 |
| `LocalPreviewComparisonPresentationTests` | 19 项全部通过；1.340 秒。 |
| `GeneratedModelParityTests` | 8 项全部通过；94.326 秒；20 槽 120／252 与原 23／58 门槛均通过且未放宽。 |
| UI 测试 | 7 项全部通过；202.650 秒。 |
| 设备包／完整 IPA 下载校验 | 设备构建及资源检查通过；完整下载、本地实际长度／SHA-256 校验完成，见下文。 |
| iPhone 15／许可 | PENDING-DEVICE／PENDING-LICENSE-REVIEW；与数值验收分开。 |

本次模型导出报告为 **`parityPassed:true`、23 cases**：最小余弦
`0.9999999999960657`，最大原始分量误差 `0.000011444091796875`，
`pairedCosineMaxAbs` 为 `1.8557397291063538e-7`。这些是**导出报告极值，非原生
XCTest 或真机极值**；原生通过依据是本次实际执行的 XCTest。

### 已验证设备包与有限截图审核

- [../build/device-download/35991227461/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35991227461/LocalImageIQ-iphoneos-unsigned.ipa)
  已实际完整有界流式下载，长度／SHA-256 验证后才最终重命名。本地 IPA
  **1,414,733,291 字节**，SHA-256：
  `0e1bc7ece93af94745e81e780d9ddf3fc78b9173c2e987a68710322be46bf7ff`。
  设备报告和校验文件齐全，无部分下载残留，旧包保留；仍须 Sideloadly 本机签名。
- 设备报告确认 **0.3.4 / 10、iphoneos18.5、arm64 Release、未签名、Xcode 16.4、
  最低 iOS 17.0**，同一 FP32／768 维 SigLIP 2 配对，`modelVersion`：
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。
  同一 Places 包 **2,943 要素、15,175,079 字节、CHN／FRA／DEU／NLD、8 个来源**；
  完整包哈希及产物身份见 [BUILD_STATUS.md](BUILD_STATUS.md)。
- 24 张 UI 截图已下载，**仅审核 3 张索引／地点界面**的 **990×742** 联系图
  [../build/ui-review/35991227461/hq20-index-contact.jpg](../build/ui-review/35991227461/hq20-index-contact.jpg)：
  Library 回填后／零 GPS、Settings 尚未检查地点的可见内容清楚。折叠项未展开，
  屏外联网页脚／20 worker 标签及其余 21 张均未视觉审核；合成场景不是私人图库、
  真实 PhotoKit 或硬件 20 路并发证明。

三路诊断及正常图片显示未改动，不把取图策略改动描述为显示已经变清晰。已有匿名
真机个例仅为 Fast **68×120**、高质量 224 **224×398**、高质量 480 不可用；
不是全图库证据，也不是 build 10 真机通过证据。此处不嵌入／上传私人照片、文件名或截图。
**build 10 IPA 已就绪，无需等待或重新下载**。用原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载／
清库；Network OFF，Library → Index / resume 一次、保持前台，完成后再试搜索。
若被终止，重开并从同一入口续跑已提交的有效前缀，不保证 20 槽一定完成；现在不
追加诊断任务。完整状态见 [BUILD_STATUS.md](BUILD_STATUS.md)。

## Historical status: 0.3.2 (8) — all eight native parity tests passed; IPA verified

以下保留旧版本的原始结果及当时步骤；“new／current”仅指当时。历史四槽 24／60
通过记录不是当前二十槽 120／252 的验证结果。build 9 的既有通过证据保留于
[BUILD_STATUS.md](BUILD_STATUS.md) 的历史 0.3.3 节，也不能替代 build 10 验证。

Source `b40d2faaf11b2f499779881b4863325fa7dae659`;
[CI 35848409845](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845)
/ [job 107140049230](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/job/107140049230):
**SUCCESS on the first attempt**. All **8 GeneratedModelParityTests passed in
101.581 seconds**, including the new real four-image-actor gate. App version
**0.3.2 / build 8**, device packaging and the complete local IPA download/length/hash
are verified. This documentation-only edit records supplied verified results; it
runs no commands, tests, CI queries/retries, downloads or phone actions.

The user explicitly requested **four indexing workers**. Each slot uses its own
image `MLModel` actor for PhotoKit-preview preprocessing/inference. The factory
reuses one persistent primary image encoder and creates three indexing-scoped,
lazily loaded image-only actors; their scoped ownership ends after all children
drain and the index call exits. **ONE central text model and ONE tokenizer remain**,
not four paired/text models. The three extra image instances and concurrent
intermediates are an explicit memory trade-off, not a measured phone-memory result.

The rolling production window includes running AND finished-but-uncommitted work
in its fixed **4** positions: no fifth outstanding item and no unbounded pending
preview/result queue. One ordered commit frees one position immediately, not a
four-item batch barrier. The parent keeps locations, place-text deduplication,
writes and progress in snapshot order; saves precede their counters. Cancellation/
fatal exit cancels and awaits all four children before the next serialized job;
late PhotoKit callbacks remain gated out. Valid cache hits fetch no preview and
run no image inference; a cache-only scan does not load the extra three models.
No new timeout, automatic retry, arbitrary row/byte limit or networking change.

Same SigLIP 2 weights/revision, FP32, schema/modelVersion, tokenizer, preprocessing,
`photokit-preview-v1`, **2,943-feature** geography pack, centered score and **0.6**
default location weight. This run's device report confirms the unchanged model and
pack identities; this run's passing native gates validate the new model ownership,
not merely the unchanged weights or historical results below.
Four actors or simulator `.all` results do not prove physical GPU/ANE overlap,
**4× speed**, phone latency/memory/heat or private-photo quality.

| Build 8 gate | Verified result / remaining boundary |
| --- | --- |
| Core / export / places / model and App checks | All passed; Swift core 79 passed. Model-report parityPassed:true; raw exact extrema were not returned, so no old extrema are copied as build 8 measurements. |
| IndexPipelineTests | All 19 passed, including 4 new tests; separate pipeline/order/cancellation/cache tests, not generated-model numerical gates. |
| Default factory boundary | New test passed for four injected slots and pre-cancellation; mocks alone are not real-model independence proof. |
| GeneratedModelParityTests | All 8 passed in 101.581 seconds, including the production four-slot image factory test. |
| New four-slot factory parity | Passed: 6 fixtures × 4 real image actors = 24 predictions; 48 normalized comparisons + 12 tensor measurements = 60. Counts and image cosine ≥ 0.995 gates asserted and passed. |
| Original production API parity | Passed: unchanged 23 predictions / 58 measurements and numerical gates; retained alongside, not replaced by, the new test. |
| Full model-enabled App run | 221 total / 220 passed / 1 physical-device file-protection skip on simulator / 0 failures. The App suites above are included, not additional tests. |
| UI tests | All 7 passed in 209.329 seconds; visual review is narrower, as recorded below. |
| Build 8 resource/device/IPA checks and complete download | Passed; version 0.3.2 / build 8 verified. Local stream download COMPLETE, actual bytes/hash verified; checksum and device-build JSON exist, no partial file remains. |
| Physical phone / redistribution | PENDING-DEVICE / PENDING-LICENSE-REVIEW — separate boundaries, not implied by native CI. |

### Verified build 8 package, identities and limited screenshot review

- [IPA artifact 10745235946](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/artifacts/10745235946):
  outer **1,414,636,737 bytes**, inner IPA **1,414,629,419 bytes**;
  IPA SHA-256 `7d37581966a45028213a52a0a9c504e2ed273293a92bbbad4ab9d77a0d73ef8e`.
  Completed local download:
  [build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa).
  Still unsigned; local Sideloadly signing is required.
- Device report confirms unchanged modelVersion
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`
  and the **2,943-feature** pack, GeoJSON SHA-256
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`.
  Full pack identity: [BUILD_STATUS.md](BUILD_STATUS.md).
- **20 UI frames retrieved; only 3 index/place frames reviewed**, in the
  [960×680 contact sheet](../build/ui-review/35848409845/four-workers-ui-contact.jpg):
  Library after backfill, Library with zero GPS, and Settings with locations not
  checked. Disclosures stayed collapsed; expanded counters and the other 17
  frames were not reviewed. These synthetic scenes are not four-worker
  physical-device proof or private-library GPS observations.

Normal overwrite installation with the same Sideloadly account/effective Bundle ID
and **Library → Index / resume** reuses compatible 0.3.0/0.3.1 caches; do not uninstall
or clear index/cache for the update. For the user's optional from-zero speed test,
**after installation choose Settings → Clear index, then Library → Index / resume**,
with network off and the app foreground. Clearing loses App index/cache data
**but not system photos**; it is not an upgrade prerequisite. Compare 0.3.1 vs 0.3.2
with the same geopack, empty indexes, phone/photo set/count and comparable
temperature/heat/power. No actual speed/memory test has been performed, and no
index rescue or additional diagnostics are required. Verified result ledger:
[BUILD_STATUS.md](BUILD_STATUS.md); full pipeline: [INDEX_PIPELINE_PLACES.md](INDEX_PIPELINE_PLACES.md).

## Historical evidence: 0.3.1 (7) — native parity passed; IPA verified

All results and then-current installation steps in this build 7 section are older
evidence, not verification or delivery of build 8's four-worker implementation.

Source `18ad52d37690ecfbf92b63a21285a6c3e8e753d4`;
[CI 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
/ [job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763).
**SUCCESS on the first attempt, with no fix/retry needed**; logs contain
`TEST SUCCEEDED` and `BUILD SUCCEEDED`. This documentation-only edit records the
supplied verified results; it runs no commands, tests, downloads or CI queries.

- Source/static checks **30 passed**; core **79 passed**. App **215 total:
  214 passed, 1 physical-device file-protection skip on simulator, 0 failures**.
- **All 7 GeneratedModelParityTests passed in 67.736 seconds**, with no parity
  skip. All **7 UI tests passed in 202.143 seconds**. The parity tests are included
  in the App total, not seven additional App tests.
- IndexPipeline **15**, PlaceAvailability **17**, BundledPlaces **2**, and
  IndexPlacesPresentation **3** tests all passed, also included in the App total.
  Public-place generation and test_places passed; 25 tests is the code/prior-local
  declared count, not a separately verified CI log total here.
- [Model-report artifact 10741671604](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741671604)
  records **23 cases, 92 comparisons**, minimum cosine `0.9999999999960657`,
  maximum raw component difference `0.000011444091796875`, and maximum paired
  matrix difference `1.8557397291063538e-7`. These are this run's export results,
  not relabelled build 6 values. Native `not-run` exporter markers precede XCTest;
  the later passing XCTest results establish native parity.
- Simulator/device App resources and IPA validation passed; iPhoneOS arm64
  Release build succeeded. Device report: **0.3.1 (7), iphoneos18.5, arm64 Release,
  unsigned, Xcode 16.4, minimum iOS 17.0**. Artifact **10741731376** was completely
  downloaded with bounded-memory streaming; local length/SHA-256 verified and
  post-download report written/checked. Exact identity and local package link:
  [BUILD_STATUS.md](BUILD_STATUS.md).
- **20 native UI frames retrieved, only 3 new index/place frames reviewed** in the
  [960×680 contact sheet](../build/ui-review/35840838147/index-places-contact.jpg):
  Library after backfill, Library with zero GPS, and Settings with locations not
  checked. Visible content is readable; disclosures remained collapsed, so not
  every expanded internal counter was visually checked. Counts are synthetic,
  not user GPS results; this is not a physical-iPhone test.

This is not another model migration. Both image and text remain
`google/siglip2-base-patch16-224` at revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`, with the same schema 2 / FP32 /
768D contract, tokenizer, preprocessing, `photokit-preview-v1` and modelVersion:
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
Build 6's results below remain the historical numerical baseline. Build 7's own
passing XCTest results above establish its native parity; unchanged model identity
or successful conversion alone would not establish that result.

Build 7 adds one-ahead cache/PhotoKit preparation overlapped with parent processing,
not multiple inference workers: one model pair, serial inference and ordered
commits, with the child cancelled/drained on exit and late PhotoKit callbacks
ignored by the existing gate. No new arbitrary limits or network policy changes.
Separate pipeline/place tests cover these contracts; generated-model parity alone
does not establish cancellation, persistence or location classification.

Actual **device-package** checks confirm the China/France/Germany/Netherlands pack:
**2,943 features, 15,175,079 bytes, CHN/FRA/DEU/NLD, 8 sources**, GeoJSON SHA-256
`41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`, and manifest
SHA-256 `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`.
These are not merely local [manifest](../Resources/Places/places-manifest.json)
metadata. Sources represent 2017–2022 administrative boundaries, not
global/current-address coverage.
[BundledPlacesTests.swift](../Tests/BundledPlacesTests.swift) checks the host app's
bytes/hash/counts and four public city reference points plus uncovered New York;
both tests passed in this run. That is not a private-library GPS measurement.

Install the delivered IPA using the same Sideloadly identity/effective Bundle ID.
Valid 0.3.0 image vectors are reused in one **Library → Index / resume**
places-backfill pass; no uninstall, index clear or whole-image re-encoding.
Only new/changed photos need normal image encoding. GPS observations are per scan,
separate from saved labels, with no-GPS/no-pack/outside/unavailable distinguished.
Weight **0.6** and centered scoring stay unchanged; added place inputs intentionally
can change rankings. Keep the app foreground and network off. User-side installation
and physical-phone behavior, file protection, performance and private-library
coverage are not yet verified; no speedup or coverage is promised. Model/geography
license review remains separate. Full scope and delivery evidence:
[INDEX_PIPELINE_PLACES.md](INDEX_PIPELINE_PLACES.md) and
[BUILD_STATUS.md](BUILD_STATUS.md).

## Historical evidence: 0.3.0 (6) — native parity passed; IPA verified

All execution counts, measured values, package and review results in this section
belong to the older build 6, not build 7 or build 8.

User-approved paired model replacement, source
`f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78`.
[CI 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
/ job `107062896845`: **SUCCESS**, with `TEST SUCCEEDED` and `BUILD SUCCEEDED`.
Xcode 16.4 / Swift 6 toolchain (App Swift 5 language mode), iOS 18.5 simulator;
unsigned FP32 device build uses iphoneos18.5 / arm64 / minimum iOS 17.0.

- Core: **79 passed**. App: **178 total, 177 passed, 1 physical-protection skip,
  0 failures**. All **7 UI tests passed**. Thirty Python static tests also passed;
  static/core results are not substitutes for the native evidence below.
- **All 7 GeneratedModelParityTests passed in 72.985 seconds**, with no parity
  skip: exact Gemma IDs/masks including Final_Sigma, full same-tensor controls,
  native preprocessing and requested CPU / `.all` checks. Gates are unchanged.
- The production encoder API test **passed with asserted counts of 23 predictions
  (17 text + 6 image previews) and 58 measurements**. These are actual execution
  results, not planned coverage; measurement types and their limits are below.
- Corrected-run FP32 export: **23 cases, 92 comparisons**; minimum cosine
  `0.9999999999960657`, maximum raw error `0.000011444091796875`, and maximum
  paired-matrix difference `1.8557397291063538e-7`.
- The build 6 IPA download is **complete**, with bounded-memory streaming and local
  length/SHA-256 verification. Artifact 10734323054 and exact package identity
  are recorded in [BUILD_STATUS.md](BUILD_STATUS.md); this is not a device test.
- 17 native UI screenshots were retrieved, but **only 4** (Home, Library,
  Settings, hero results) reviewed in the downscaled
  [contact sheet](../build/ui-review/35824403795/siglip2-ui-contact.jpg).
  Synthetic/test scenes only, no private photos; not 17 reviewed screenshots.

Model version:
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
Export JSON native `not-run` markers were emitted **before XCTest** and remain
provenance, not failure indicators. The subsequent passing XCTest is the native
evidence; it does not rewrite the export inputs.

### Initial failed run and correction retained

[Run 35823153931](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35823153931)
at `aee4cdc00be92e1699f68baa9ef7ccc72cbcfbda` passed static/core checks, FP32
export, same-tensor native predictions and all seven UI tests, but **failed**
native low-resolution resizing and Greek Final_Sigma checks. The correction uses
Pillow-compatible 22-bit separable bilinear resampling and Unicode Final_Sigma
context, with ten image and three Unicode regression tests added. **68×120 and
112×199 native cases now pass**, as do exact token checks. Fixtures, queries,
full same-tensor controls and numerical thresholds were not weakened or bypassed.

Historical CLIP/WordPiece/raw-512 reports and prior successful builds are retained
in [BUILD_STATUS.md](BUILD_STATUS.md). They are not proof for SigLIP 2. All
original acceptance requirements below describe the seven tests that passed in
corrected build 6 and again in build 7. Build 8 retains those gates and adds the
eighth factory-parity test; all eight passed in build 8's verified run above.
Physical-iPhone behavior/performance and license review remain separate boundaries.

## Authoritative model and tokenizer contract

[IMPLEMENTATION_CONTRACT.md](IMPLEMENTATION_CONTRACT.md) defines schema 2. Both
image and text use `google/siglip2-base-patch16-224`, revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`; never mix old and new towers.

- Image input: `pixel_values`, Float32 `[1,3,224,224]`. Apply EXIF orientation,
  RGB conversion, direct 224×224 warp with no aspect preservation or center crop.
  The independent reference uses Pillow 11.1.0 BILINEAR (`resample=2`), division
  by 255, then mean/std `[0.5,0.5,0.5]` in NCHW layout.
- Text input: ONLY `input_ids`, Int32 `[1,64]`. Both outputs are raw Float32
  `[1,768]` `output_embedding` values from `pooler_output`. Keep the learned
  vision pooling/text heads; text pools position 63 even when it contains PAD.
  No masked mean, last-EOS pooling, replacement projection, sigmoid, logit
  scale/bias or export-side L2 normalization. Swift normalizes once for storage
  and retrieval.
- Native [SigLIPTokenizer.swift](../App/Inference/SigLIPTokenizer.swift) uses the
  `Tokenizers` product of `swift-transformers` **1.3.4**, pinned in
  [project.yml](../project.yml). It loads both unchanged JSON resources locally
  with strict loading, never downloads or falls back to the retired tokenizer.
  This App dependency does not change the Foundation-only core's dependency
  boundary.
- The Python reference explicitly calls `str.lower()` before its local fast
  Gemma tokenizer. Swift explicitly lowercases before JSON tokenization; exact
  multilingual fixtures must establish parity, not an assumption that all
  Unicode lowercasing is identical. Preserve the JSON normalizer and added
  tokens; no trimming, casefolding, accent stripping or manual Chinese splitting.
- Retain at most 63 content tokens, append EOS 1, right-pad PAD 0 to 64; no
  automatic BOS. Literal BOS 2, UNK 3, EOS and PAD remain content. A literal PAD
  has mask 1, so masks cannot be inferred from nonzero IDs. Empty input is
  `[1,0,...,0]`. `attentionMask` is checked in fixtures but NEVER sent to Core ML.

## Test scope

[GeneratedModelParityTests.swift](../Tests/GeneratedModelParityTests.swift) is an
app-hosted XCTest suite importing `LocalImageIQ` and `ImageIQCore`. It consumes
the real generated resources from [export_models.py](../scripts/export_models.py),
using the field names from that exporter and
[synthetic_fixtures.py](../scripts/synthetic_fixtures.py). It does not generate
surrogate reference embeddings, download weights, compile models at runtime,
or touch personal photos.

The original seven generated tests target this contract and passed in historical
builds 6 and 7 above. Build 8's refactored consumer and new eighth test also passed
native execution in run 35848409845. This
documentation edit performs no export, test run, installation or CI action;
passing source checks or Python export alone is not a native parity result.

## Test host and resource gate

Include the test source in the app-hosted XCTest target whose host application
and module are `LocalImageIQ`, with testability enabled. Supply the exporter's
completed model resources in the test build; Xcode must compile both model
packages to bundled `.mlmodelc` resources. There is no runtime `.mlpackage`
compilation fallback.

Required resource names (generated artifacts, not checked-in references):

- model-manifest.json
- ImageEncoder.mlmodelc and TextEncoder.mlmodelc
- tokenizer.json and tokenizer_config.json, byte-for-byte from the shared revision
- tokenizer-parity.json and image-preprocess-parity.json
- All PNG and float32 little-endian tensor files named in the image document's
  `cases[].image` and `cases[].tensor` fields, normally under the fixtures folder.

Resource lookup calls the actual `BundleResources.url` API from
[ModelManifest.swift](../App/Inference/ModelManifest.swift): bundle root, Models,
Resources/Models, and Resources. `Bundle.main` is tried first, then
`Bundle(for: type(of: self))`. When the host app has a manifest, its models and
two tokenizer JSONs are mandatory; a complete test bundle cannot mask broken app
packaging. A test-bundle-owned complete pair is supported when the app has no
manifest. Fixture documents may live in either bundle and must match the
selected manifest's version and pinned sources. Fixture files are resolved
relative to the image document first, then through bundle lookup, including
Xcode-flattened resources. Both tokenizer JSONs must be colocated and owned by
the selected manifest bundle; their two hashes, and PNG/tensor hashes, are
checked against fixture metadata. No retired vocabulary resource is required.
There is no source-tree, working-directory, network, or user-provided external-path
fallback.

| Build state | Result |
| --- | --- |
| No generated resources in either bundle, and no required-model environment flag | Fixture/model tests explicitly `XCTSkip`: model-free, parity not run. |
| `IMAGEIQ_REQUIRE_MODELS=1` reaches the test runner/host | Missing manifest, model, either tokenizer JSON, document, or referenced fixture fails; never silently skips for missing models. |
| App manifest exists, even without the flag | Model-enabled automatically; missing resources fail. |
| Test-bundle manifest exists, or partial model/fixture resources exist without a manifest | Complete test-bundle pair is tested, or incomplete packaging fails rather than skips. |
| Generated resources are present but malformed, mismatched, or model loading/prediction fails | Fails; no model-free fallback. |

Inject environment variables into the actual XCTest runner/test-host process
through the scheme/test plan or runner configuration. A variable set only in an
outer build shell is not proof it reaches XCTest. The attachment records
`requireModels`, `resourceGate`, and the selected bundle. A model-enabled CI
runner should set `IMAGEIQ_REQUIRE_MODELS=1` even if it expects the app manifest:
this detects accidentally omitting the entire model resource set.

The independent solid-color test always runs without model resources. An
optional `.all` test checks resource availability before its engine opt-in skip;
its skip cannot conceal missing resources in an enabled build.

## Historical build 8 tests and numerical acceptance — retained baseline

下面原样保留四槽版本的断言与执行结果。当前 build 10 工厂改为 20 槽，实际通过的
120 次预测／252 项测量见页首；原数值阈值和 23／58 不变且已通过。

The original seven tests and thresholds remain unchanged, with an eighth test
added for the real four-image-encoder factory. Builds 6 and 7 passed the original
seven; build 8 passed all eight. Per-test prediction/measurement counts below
were asserted and passed in build 8, not merely planned coverage; they are not
extra suite tests or exporter comparisons.

| Test | Input and acceptance |
| --- | --- |
| `testGeneratedGemmaIDsAndMasksMatchAllCases` | Actual bundled JSONs and native `SigLIPTokenizer`; all 64 IDs and mask entries match exactly for each of the 17 pinned cases. |
| `testTextEncoderCPUReferenceAndNativeTokensParity` | Load text model once with `.cpuOnly`. For every query, predict separately from fixed fixture IDs and native IDs; no mask model input. Both raw predictions require maxAbs ≤ 0.001 and cosine > 0.999 against both `referenceRaw` and `coreMLRaw`; app-normalized output cosine > 0.999. Token mismatches fail independently without suppressing the fixed-input control. |
| `testImageEncoderCPUSameFloatInputParity` | Load image model once with `.cpuOnly`, feeding each full reference tensor unchanged. Against both raw references: maxAbs ≤ 0.001 and cosine > 0.999; app-normalized cosine > 0.999. This isolates runtime/conversion from interpolation and decoding. |
| `testNativeImagePreprocessingCPUParity` | Decode all six PNGs through native preprocessing; attach full-tensor maxAbs/MAE. Raw and normalized embedding cosine ≥ 0.995 against both references. Interpolated pixel errors are diagnostic, not bit-exact gates; EXIF rotation/mirroring and both low-resolution inputs are mandatory. |
| `testKnownSolidRGBNormalizationWithoutModels` | Six uniform sRGB colors: (31,127,223), red, green, blue, black, white. Every NCHW component matches independently pinned mean/std 0.5 within 0.00001. Requires no models and does not derive expected constants from production code. |
| `testGeneratedPairAllComputeUnitsParityWhenRequested` | Opt in with `IMAGEIQ_TEST_ALL_COMPUTE_UNITS=1`. Repeat both text-input paths, unchanged image-tensor control, and native image preprocessing with `.all`, using the same numerical criteria. This is separate from the CPU export-comparison gates. |
| `testAppEncodersModelSizedPreviewAndAllTextReferenceParity` | PASSED in build 8, with the same gates as builds 6/7. Exercise production `CoreMLEncoders` with `.all` in every model-enabled build, independently of the optional-engine flag. Six actual-sized synthetic CGImage previews + 17 texts yield 23 predictions. Outputs must already be 768D unit vectors (norm error ≤ 1e-5); compare to each normalized raw reference with image cosine ≥ 0.995 and text cosine > 0.999. The 58-measurement assertion passed unchanged. Details below. |
| `testIndexingImageFactoryAllSlotsConcurrentPreviewParity` | NEW in build 8, PASSED. Call production `makeIndexingImageEncoders()` on one owner with `.all`, independently of the optional-engine flag. Retain all four real image actors; predict each of six raw CGImage fixtures on all four slots concurrently. Require exactly one output per slot per fixture, 24 predictions, already-normalized 768D outputs with norm error ≤ 1e-5 and image cosine ≥ 0.995 against each normalized raw reference. Assert 48 embedding comparisons + 12 tensor measurements = 60. All counts/gates passed. No four-text-model construction, timing gate or physical GPU/ANE concurrency claim. |

The production API test retains raw ImageIO pixels, including **68×120** and
**112×199**, until the App actor performs its 224×224 warp. There is no test-side
preview upscaling or PNG/JPEG round trip. ImageIO reads actual EXIF orientation;
fixture metadata is a check, not a substitute for that observation.

Asserted counts for this API test, which passed unchanged in builds 6, 7 and 8:

- 6 image + 17 text predictions = **23**.
- 6 exact direct-CGImage/native-data tensor comparisons + 6 diagnostic native/HF
  tensor comparisons = **12** tensor measurements.
- Each of 23 normalized outputs compared with two raw references after reference
  normalization = **46** embedding gates. Total **58** measurements.
- Do not normalize the App output again and hide a normalization bug. The test
  checks its norm directly. These counts are not the entire suite's test count.

The **new factory test's independent counts** were asserted and passed in build 8:

- 6 image fixtures × 4 production image slots = **24** predictions. Reuse the same
  four actors across fixtures; the first fixture's completed group has exercised
  all four real image models. One owner loads the text model only once.
- 24 already-normalized outputs × two normalized raw references = **48** embedding
  gates, with the same image cosine ≥ 0.995 and direct norm check as the old API gate.
- Decode/inspect each fixture once, preserving EXIF and actual 68×120 / 112×199
  pixels until production preprocessing: 6 direct/native tensor comparisons +
  6 diagnostic native/HF tensor comparisons = **12** tensor measurements, not 12
  per slot. Total **60**; diagnostic tensor errors are not new bit-exact Pillow gates.
- This is a separate eighth test, not a replacement or loosening of the original
  **23/58** test. Both tests' counts and gates are executed, passing build 8 results.

Separately, in historical builds 6 and 7, the exporter completed
23 cases × four stages = **92** comparisons:
`referenceVsWrapper`, `wrapperVsTrace`, `traceVsCoreML`, `referenceVsCoreML`.
Every stage requires cosine > 0.999; the first two require maxAbs ≤ 1e-5, the
saved Core ML comparisons ≤ 1e-3. The 17×6 paired cosine matrix has 102 entries
and requires maxAbs ≤ 1e-4; independent Pillow/HF pixels require ≤ 1e-6.
All export gates passed in builds 6 and 7; build 8's export also passed, with
model-report `parityPassed:true`. Build 8 raw exact extrema were not returned and
are not inferred from historical numbers. The older measured minima/maxima are
recorded in the separate run sections above; build 7's own model-report artifact
10741671604 supplies its values even though they match build 6 numerically.

All criteria above are numerical validation assertions, not production search
filters, query rejection policies, runtime ceilings, performance quotas, or
claims about retrieval quality. Thresholds are explicit constants in the tests;
they are not relaxed based on a fixture's recorded result. An actual failure
requires diagnosis, not a claim that native parity has been established.

`.all` permits Core ML to select available engines; it does not prove that the
Neural Engine or GPU actually executed a particular operation. The attachment
records the requested configuration and OS, not a guessed execution engine.
CPU parity and optional device-engine parity are distinct gates. Simulator
success cannot establish physical-device performance or engine parity.

## Fixture contract and coverage

Documents contain `schemaVersion:2`, `modelVersion`, `embeddingDimension:768`,
`embeddingsAreRaw:true`, `reference`, `nativeParity:"not-run"`, and `cases`.
Embeddings are raw 768-dimensional pooler outputs, not normalized reference
vectors. Tests validate header/source identity against `ModelManifest.validate()`.
The exported semantic version is `siglip2-b16-224-v1-` followed by the canonical
contract's 64-character lowercase SHA-256, not a report timestamp or old CLIP ID.

Text cases use `id`, `text`, `lowercasedText`, `inputIDs`, `attentionMask`,
`referenceRaw`, and `coreMLRaw`. The root also carries `sequenceLength:64`,
`textModel`, `tokenizerFile`, `tokenizerConfigFile`, `tokenizerSHA256`,
`configSHA256`, `tokenizerClass:"GemmaTokenizerFast"`, `tokenizerOptions`,
`preprocessing`, and `backendNormalizer`. The two hashes cover the tokenizer
JSON and its tokenizer configuration, not the model configuration. No legacy
vocabulary hash or SentenceTransformer reference alias is used.

Exactly 17 IDs and their original UTF-8 text are pinned, preventing missing,
extra, duplicate or silently simplified cases: english, chinese, case,
diacritics, combining, punctuation, special-tokens, empty, whitespace-controls,
unknown-unicode, long-word, long-truncation, greek-sigma,
turkish-unicode-chinese, gemma-turn-tokens, literal-pad, whitespace-only.
Feed original text to the production tokenizer, which applies explicit lowercase;
do not repair fixture text, change normalization or replace exact IDs with an
embedding-similarity check. Attachments preserve Unicode scalars, arrays,
masks and mismatched positions. Greek contextual sigma, dotted I, combining
marks, Chinese and literal PAD are real parity gates, not optional examples.

Image case fields are `id`, `image`, `imageSHA256`, `sourceSize`,
`exifOrientation`, `orientedSize`, `resizedSize`, `cropXYWH`, `tensor`,
`tensorSHA256`, `tensorBytes`, `dtype`, `shape`, `layout`, `spotChecks`,
`pillowVsHFMaxAbs`, `referenceRaw`, and `coreMLRaw`. A spot check has
`channel`, `y`, `x`, and `value`. The `tensor` string is a resource-relative path,
not an inline array or a nested reference object. Each tensor is exactly
602,112 bytes: Float32 little-endian, C-order NCHW `[1,3,224,224]`.
Byte-wise decoding avoids alignment and host-endianness assumptions; shape,
length, hash, finiteness, and JSON spot checks validate the interpretation.

Exactly six image cases are required: solid-rgb (224×224), checker-nonsquare
(319×231), exif-rotate-6 (321×197), exif-mirror-2 (197×321), lowres-68x120
(68×120), lowres-112-portrait (112×199). Original and oriented dimensions are
distinct; `resizedSize:[224,224]` and `cropXYWH:[0,0,224,224]` describe the whole
warped input, **not a crop operation**. The small images are procedural fixtures,
not captured PhotoKit data or proof of actual preview quality.

The native preprocessing test calls `ImagePreprocessor.values(data:)` without
an orientation override, so that function must read EXIF from the image itself.
Independently, ImageIO reads the actual orientation and dimensions; both must
agree with the fixture. The test then passes the ImageIO-derived orientation
to `ImagePreprocessor.tensor(data:orientation:)`, because the app API requires
it, and compares that tensor exactly with the no-override native values. This
same-native-path equality is not an assertion of native/Pillow equality.
Expected orientation is never substituted for observed image metadata.

Quartz only converts native pixels to sRGB; an explicit separable, 22-bit fixed-point
resampler follows Pillow 11.1.0 BILINEAR, including downsampling and per-pass 8-bit rounding.
EXIF is applied by integer pixel addressing before resizing. The full native
tensor is measured against the export tensor, but arbitrary per-pixel error
ceilings are not imposed on interpolated images. The semantic-output acceptance
for this preprocessing path is cosine ≥ 0.995; tensor max/MAE remain visible
for diagnosis. The strict unchanged-tensor test is essential: it distinguishes
conversion/runtime discrepancies from decoder/color/orientation/interpolation
discrepancies. Synthetic patterns do not prove real-photo retrieval quality.

## Historical build 8 runtime, memory, and result evidence

本节四槽运行说明与已通过记录属于历史 build 8；当前 20 槽的模型所有权、夹具复用
和待验证状态见页首。附件格式／数值证据边界仍适用，但历史通过不代表新版本通过。

Tests call the production tokenizer, Int32 tensor builder, image preprocessing,
and `CoreMLEncoders.normalizedProjection`. Direct model tests use `MLModel`
because production raw predictions/configuration are private and the actors select
`.all`. CPU raw-component comparisons therefore need no production visibility
change. The existing API test exercises the actual owner's prepare, image-preview
and text calls. The new test exercises all four production image-factory slots.
None of these numerical paths establishes PhotoKit availability, cancellation,
persistence or search UI behavior. Output coordinate indexing honors Core ML
strides instead of assuming contiguous memory.

Direct single-model tests load each role once before its fixture loop. Production
tests reuse their owners/actors rather than recreating models per query; the new
factory's three extra image models load lazily on first use in the first fixture,
then remain loaded across the other five. Existing tests iterate fixtures serially with per-fixture
`autoreleasepool` work. The new factory test iterates the six fixtures serially
but runs **four image predictions concurrently within each fixture**. It keeps
one central owner (one text model/tokenizer), the primary image actor and three
extra image actors for all 24 predictions; it does not load four text models.
Only one fixture's raw input is selected at a time, although four predictions
can each allocate their preprocessing/inference intermediates. This test grouping
is not the production scheduler, whose window rolls forward per ordered commit
rather than waiting on a four-item batch. The optional pair test finishes/releases
the text model before loading the image model. The original production API test
reuses one owner and its primary image actor for all 23 predictions.
Xcode runner-level parallelization is separate; select serial test execution
when memory measurements require avoiding overlapping test processes. The
suite adds no arbitrary memory caps, timeout rules, or speed requirements.

Each test adds an in-memory JSON `XCTAttachment` with `.keepAlways`, for retention
in the runner's `.xcresult`. Reports contain per-case raw/normalized cosine,
component max error, MAE, vector norms, acceptance bounds, token differences,
and stage/reference-group summaries (worst max error, mean case MAE, minimum
cosine, comparison/rejection counts). Reports also retain skip/error reasons
and any measurements completed before an error. They contain synthetic inputs
only; no photos, GPS, or user-library paths. The suite itself writes no files,
including no edits to source resources or export parity markers.

`completed` means the test body returned, not that all XCTest assertions passed.
XCTest failures and per-measurement `accepted` fields must be inspected; a
diagnostic-only tensor measurement being accepted means it was structurally
valid, not bit-exact. Token failures are reported independently. Group summaries
do not combine tensor-error units with embedding-error units. Preserve the
runner's result bundle to retain attachments, including successful runs.

Exporter `nativeParity: "not-run"` markers are preserved as input provenance;
this suite does not rewrite them to "passed". Only a subsequently executed
native XCTest result can establish these gates, on the OS and requested compute
configuration recorded in that run. Runs 35824403795 (build 6) and 35840838147
(build 7) each supplied passing native results; their pre-XCTest JSON markers are
not failed or unexecuted XCTest results. Run 35848409845 (build 8) supplied its own
verified eight-test native pass, including the new real four-image-actor test;
this is not a reuse of the older seven-test results.

## Migration, device use and unchanged boundaries

### Current: 0.3.4 (10) — input-policy migration without manual clear

build 10 首轮 CI、设备包身份及完整下载后的长度／SHA-256 校验已完成，IPA 现在就绪。
用原 Sideloadly 账号／原有效 Bundle ID 覆盖安装，不卸载、不手动 Clear index。
保持 Network OFF、App 前台，打开 Library → Index / resume 跑一次。
SigLIP 2 模型及地点包不变，但输入策略已从 `photokit-preview-v1` 改为
`photokit-hq224-fast-fallback-v1`，旧策略图像行必须自动重编码；旧向量被搜索和
当前有效计数排除，直到对应新行成功提交，迁移中不保证搜索覆盖／排名不变。
已完成且仍有效的新策略行可续用，Fast 兜底行也缓存、不自动提升质量。
完成后再试搜索；被终止后重开再点同一入口，已提交的有效前缀保留，未提交工作需
重做。20 槽有用户已批准的内存风险，可能反复被终止，不能保证最终跑完。
现在不追加诊断、截图或清库测速任务。

### Historical: 0.3.0 / 0.3.1 → 0.3.2, normally reuse image vectors

The semantic modelVersion and image policy do not change. Build 8's CI, IPA gates
and complete local byte/hash-verified download are finished. Use that package to
overwrite with the same Sideloadly account/effective Bundle ID and use
**Library → Index / resume** normally. Do not uninstall; no index clear or full
image rebuild is required. Still-valid 0.3.0/0.3.1 rows bypass preview fetch and
image inference while locations are checked; changed
labels/geography or removed GPS can update/remove place embeddings, and compatible
distinct-place text vectors can be reused. New/changed photos encode normally.
Keep the app open and network off; interrupted indexing resumes through the same
entry. No original-download prerequisite or additional diagnostic round is added.

For the user's optional **from-zero** timing comparison, after installation choose
**Settings → Clear index**, then **Library → Index / resume**, with network off
and the app foreground. This loses the existing index/cache, not system photos.
Compare 0.3.1 and 0.3.2
using the same geography pack, both empty indexes, same phone/photo set/count,
network off and comparable heat/power conditions. Do not conflate this optional
test with normal update/resume. No actual speed or memory result is available.

### Historical: 0.2.x CLIP → 0.3.0 SigLIP 2 model migration

That semantic modelVersion change required fresh image AND place-text vectors.
Legacy 512D cache decoding exists only for migration, not SigLIP 2 search or a
fallback encoder. The build 6 IPA was verified: overwrite with the same Sideloadly
account/effective Bundle ID, then **must use Library → Index / resume once**.
Before new vectors exist, old-model usable coverage is expected to be **0**
because that model changed. This does not apply to valid SigLIP 2 rows in builds 7/8.
Do not uninstall or manually clear the index.
Interrupted indexing reuses completed,
still-valid new rows. Photo `id` primary-key replacement means retained old IPA
files are not old-index backups; rollback cannot promise restored old vectors.

### Shared boundaries

当前 `photokit-hq224-fast-fallback-v1` 仍接受可用低清像素：高质量 224 本地优先，
无本地资源才 Fast 本地兜底；取消／权限／授权／无像素普通错误不兜底。两路本地
均无资源且用户显式允许，才可高质量联网第三次请求，默认网络关闭。不要求下载
原图，不保证每张云照片离线可用或质量提升，正常显示和三路诊断不变。历史可选
冷启动测速不是当前操作要求；现在只等新包，不追加查询、诊断或截图任务。

Synthetic numerical parity is not retrieval-quality evidence. The desktop
comparison had language/query/resolution trade-offs, not universal improvement;
desktop CPU timings and simulator `.all` results are not physical-iPhone
latency, engine, memory or heat measurements. Diagnostic scores/cosines cannot
be compared directly across CLIP and SigLIP 2 as a controlled quality measure.

Privacy and signing do not change: photos, GPS and vectors stay local; Apple
credentials do not go to chat/CI. Free development profiles normally expire
after seven days. The shared model card declares Apache-2.0; the exporter
copies actual license evidence where available and retains
`redistributionApproved:false` and manual review. License copies and successful
numerical checks are not legal certification for distribution.