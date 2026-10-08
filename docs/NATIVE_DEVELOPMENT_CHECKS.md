# 原生定点开发验证

已实现并实际运行的手动开发工作流 [../.github/workflows/ios-dev.yml](../.github/workflows/ios-dev.yml)，与原发布工作流分离，**明确选择macos-15／Xcode16.4**；不是待实施建议。

- 默认只运行增量同步、同步状态、同步诊断和失败阶段四个XCTest类；可填写精确的 `target/class[/testMethod]`，不能只指定整个target。
- 使用真实macOS／Xcode编译App及测试，执行选择的用例；不转换Core ML模型、不运行全量UI、不打IPA、不创建Release。
- model-free不是只检查文本，也不能证明真实手机Photos／旧数据库根因。项目和所有测试源码仍可能一起编译。
- Places仍使用现有生成器及校验，不去下载旧的1.4GB IPA作为开发资源。当前首版没有加入模型、SPM依赖或DerivedData缓存，不宣称这些已加速。
- 原发布流程及模型／App／UI／设备校验不改；先定点通过，再进行完整发布验证；只有实际发布阶段失败才据证据处理后复验，不把完整发布当作日常调试循环。**开发检查通过本身不是发布许可**。历史单项build33键盘例外不会自动扩展到新build；本次用户在定点检查后另行明确批准诊断IPA及build34同一例外。
- 输入只作独立进程参数，拒绝目标外选择器和shell插入。记录请求SHA、选择器、xcresult及摘要；开发检查结果与Release交付分开。
- 校验精确类／方法选择器，并对照xcresult的**实际执行树、每个请求项与测试计数**；零执行、全跳过或拼错选择器均不能凭退出码0冒充通过。相关本地 **32项Node测试全部通过**，与下方真实原生104项分开计数。

本次build33手机报告「正在检查照片」约 **1秒**后失败，手动重新同步仍相同。已确认旧状态层丢弃底层诊断。当前 `PhotoSyncDiagnostic` 只增加允许列表内的SS短码、阶段、错误类别、元数据字段类别和可信SQLite数字返回码；UI不显示照片ID、路径、OCR、查询或原始错误内容。**`PhotoSyncFailure.underlying`内部仍保留原始错误，状态层只保存安全诊断**，不能写成“所有地方都不持有raw Error”。不清索引、不重建，guards、查询、计算、事务和取消行为均不改。自动同步是普通SQL路径，不使用清理源监视器的NOFOLLOW打开方式；不能把旧清理1550／某条路径认作这次已知原因。**手机的实际失败阶段和根因尚未取得，不把诊断补齐称为根因修复。**

## 第一次真实定点验证

源码 `b7f198f65d22eaf2254d3666baa6b222ddbfdd9a`，[run 37763800378](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37763800378)／[job 113266392603](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37763800378/job/113266392603) SUCCESS。明确选用预装Xcode16.4，真实编译App／测试，实际执行 **104项全通过、0失败、0跳过**：增量同步48、同步状态42、诊断5、阶段9；其中 **90项为迁入定点入口的既有测试，14项才是新增（诊断5＋阶段9）**。测试9.233秒，wall17.845秒。工作流核对xcresult执行树与每个请求项，不能以零测试退出码冒充通过。

原生编译／验证阶段459秒；项目生成及模拟器选择120秒，首次整项工作约10分钟，**不是9秒完整开发循环**。没有模型转换、全量UI、IPA或Release。其余源码仍一起编译，尚未配置缓存或持续Mac环境，因此不能宣称已经实现增量编译加速。

## build34 诊断交付范围

0.12.1/build34 增加普通同步卡中的阶段／短码。例如SQLite打开、schema、SQL读取问题，或照片ID／时间字段、授权、generation变化分别报告。例子只是合成错误，不能预言手机将返回其中哪一个。

定点通过后用户明确选择「**生成诊断IPA，保留键盘例外**」。仅把 `testDraggingScrollViewDismissesKeyboard` 的 `XCTSkipIf` 条件扩为绑定bundle的 **`CFBundleVersion == "33" || CFBundleVersion == "34"`**，测试正文保留、其他build继续执行；其他键盘、模型、数据安全和发布门槛仍执行，不授权任何其他新skip。拖动收键盘未验证修复，“完成”仍可用；跳过不能算通过。

普通卡片只读取 `detail.failureDiagnostic.message`。真实状态传播与view计算属性测试通过，**但本轮没有下载UI ZIP或实际审阅新的UI截图**，不把属性测试等同于短码屏上可见性／真实Photos同步E2E验证。build33全部既有功能与偏好规则沿用：缺失／无效才默认0.90，有效旧0.80等较低偏好保留。

## 发布阶段的失败、第二次定点与最终交付（已完成）

以下三个执行均使用同一最终源码 **`2e1a05bbe387b6c8b60853cbfb5cbc94b7bc1806`**，没有为首轮完整失败修改代码、超时或豁免该测试：

|范围|run／job|结果|
|---|---|---|
|第一次完整发布验证|[37777490964／113311912055](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37777490964/job/113311912055)|**FAILED**，唯一失败为未改动的 `DebugToolsPresentationTests.testLibrarySameHostModeRoundTripChangesPixelsAndRestoresFormRowsWithoutWork` 的5秒settle等待超时。App1732／1既有SQLite跳过／1失败，**391.305秒，wall401.198秒**；独立UI14＝13通过／1批准键盘跳过／0失败，**882.383秒**。draft **406832580**，**无IPA**。|
|第二次定点：复验实际失败套件|[37781125556／113324195270](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37781125556/job/113324195270)|**SUCCESS：DebugTools7项全通过／27.932秒，wall27.942秒**。未重复全量模型／UI／IPA发布链作为定点调试。|
|第二次完整发布验证|[37782669079／113329435394](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37782669079/job/113329435394)|**SUCCESS：Core79；App1732＝1731通过／1既有SQLite跳过／0失败，515.423秒，wall530.195秒**。独立UI14＝13通过／1批准键盘跳过／0失败，**1131.923秒**。|

最终新增 **14项全通过**：`PhotoSyncDiagnosticTests` **5／0.018秒**、`PhotoSyncFailureStageTests` **9／0.136秒**，已计入App1732；`GeneratedModelParityTests` 真实模型 **8／150.633秒**，完整 **CPU／`.all`／20 actor**保留；`DebugToolsPresentationTests` **7／31.068秒**。旧失败只是在同源码定点及完整复验中未复现，**不宣称原因已定位／修复**。本阶段总计 **2次定点＋2次完整验证**，不是一次完整发布通过，也不是四次完整发布。

**0.12.1／build34已发布并完成本地包校验，不再待补记。**[Release ci-37782669079-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37782669079-1)，ID **406888863**，**2026-10-08T13:58:00Z**，**9资产、prerelease、非draft**。本地包：[../build/device-download/37782669079/LocalImageIQ-0.12.1-build34-iphoneos-unsigned.ipa](../build/device-download/37782669079/LocalImageIQ-0.12.1-build34-iphoneos-unsigned.ipa)，asset **621985354**，**1,419,698,565 bytes**；实际全文件流式SHA-256 **`29b5dafbbeb7f3f9b92cfe46760e66c5e3daec8543129496c92ad99dd6ef0277`**，**7-Zip26.04全量CRC PASS**。完整归档／设备元数据及下载记录见 [BUILD_STATUS.md](BUILD_STATUS.md)，不是开发工作流自行生成或批准的Release。

**同Sideloadly账号／原有效Bundle ID覆盖安装一次，不卸载、不清库、不为升级重索引、不重新授权；正常打开后若仍失败，只需一张新同步卡带SS短码截图。现在不要求重复手动重新同步。**手机根因仍未知，下一步需要新码，不需要旧日志或真实删除测试。安装见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。