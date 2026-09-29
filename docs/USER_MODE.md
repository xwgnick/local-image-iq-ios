# 用户模式与调试工具 — 0.4.1（build 12）

## 当前（2026-09-29）：0.4.1（build 12）首次完成交付，用户模式原生验证通过

同一 [xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios) 已确认
**PUBLIC／`private: false`**；用户已明确同意历史作者邮箱、机器路径、测试查询、
Actions 日志和已发布 Releases 公开。范围、免费标准 runner 条件及不设置项目级许可证的
边界见 [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md)；第三方再分发审查没有因此完成。

[CI 36515068434](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434)
／[job 109235419277](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36515068434/job/109235419277)，
源码 **`fac5e2d39d37730ccf45e2f8e0231124247d4cf8`**，已 **COMPLETED / SUCCESS**。
这是 build 12 首次完成交付，不是首次构建尝试。当前
[公开 Release：ci-36515068434-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36515068434-1)
（**398799791**）于 **2026-09-29T03:27:14Z** 发布，**prerelease、`draft: false`、非 Latest、
9 项资产已核验，无需 GitHub 登录**。build 11 与旧失败 drafts 只作为历史。

- 核心 **79 通过**；App **370 项：369 通过、1 项既有真机文件保护模拟器跳过、0 失败**，
  **258.961 秒**（wall **288.923 秒**）。`GeneratedModelParityTests` **8／170.094 秒**、
  `DebugToolsPresentationTests` **7／25.179 秒**、`DebugToolsStateTests` **14／1.055 秒**
  全部通过，均已计入 App 总数；没有新增跳过或降低门槛。
- 独立 UI **9 全通过／522.447 秒**：`PresentationNavigationTests` **5／354.440 秒**，
  `SearchKeyboardTests` **4／168.007 秒**。此前失败的
  `testClearQueryKeepsKeyboardAndSettingsAdvancedStartsCollapsed` 现已通过；两次展开均在
  **任何滚动前**确认唯一 `location-weight`、无 `debug-advanced` ID 的 Slider、可点击且
  **60%**，收起、关闭调试、查询与 Top 12 保持不变的断言也通过。
- **Advanced 标签 ID 作用域修正＋语义 `button.tap()` 已通过原生验证**。旧视频已证明
  Advanced 展开，否定“未展开／箭头未命中”；父级 ID 传播是有力的机制假设，但旧三个
  `UIApplication`／`children=[]` 样本并未直接证明继承。调查与旧失败账本见
  [BUILD_STATUS.md](BUILD_STATUS.md)。不把模拟器测试耗时当成手机性能。
- 设备 **BUILD SUCCEEDED**：**0.4.1 / 12、arm64 Release、iphoneos18.5、Xcode 16.4、
  最低 iOS 17.0、未签名**。
  [../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/36515068434/LocalImageIQ-iphoneos-unsigned.ipa)
  已完整流式下载并核验实际长度／SHA-256，**`ipaVerifiedLocally: true`**；asset **597136564**，
  **1,414,818,257 字节**，SHA-256：
  `840085413cee964c7de03fa4453f89db9691ec74f8165064e3d07e432ccec03c`。
  可按 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md) 本机签名覆盖安装，
  **尚不代表本轮已在物理手机安装或测试**。

### 本轮仅四场景的视觉审核

UI ZIP asset **597136471**，**3,339,409 字节**，SHA-256：
`9fb0be72629cb43efba8716a22411ca24fdb7bfb291d89e98a9e6e19eb9e43f3`，已下载并校验。
父流程已实际查看[本轮四图联系图](../build/ui-review/36515068434/user-mode-contact.jpg)
（**1340×758**，原图**各 393×852**）：

| 场景 | 实际可见范围 |
| --- | --- |
| Settings 底部 | Show debug tools OFF；Maintenance／隐私说明仍可见。 |
| Library 未授权 | Photos 连接入口和 iCloud 控件可见；索引禁用，无 Details。 |
| 空查看器、调试 OFF | 仅分享入口可见，且禁用。 |
| 空查看器、调试 ON | 分享、Photo Check、本地预览对比均可见，且禁用。 |

均为**合成空状态／未授权、不读取 Photos**，不是真机或私人图库证据；
不声称其他图像已审核。视觉审核范围不扩大为整包审核或真机交互验收。

## 日常使用

每次启动默认隐藏全部调试工具。唯一入口在 **Settings 最底部 → Show debug tools**；
打开后本次会话可用，关闭或重新启动后隐藏，**不持久化这个开关**。无需先做诊断，
直接正常搜索、看图即可；这不是全 App 本地化改版。

| 区域 | 普通模式保留 | 开启调试后才显示 |
| --- | --- | --- |
| Settings | 结果数量、中文搜索增强、语言选择／离线语言包准备、Maintenance 的 Refresh 和带确认的 Clear index | Advanced 地点权重／原始分数、Diagnostics |
| Library | Photos 权限、Ready／有效数量／进度、缺少本地预览／读取失败的友好提示、iCloud 联网显式许可 | Details、GPS 分项计数、worker／输入策略等技术信息 |
| 照片查看器 | 正常看图功能及友好错误提示 | Check this photo、本地预览对比，以及两者的诊断 sheet |
| 搜索 | 原查询、结果、实际英文提示和“使用原文” | 调试分数等技术展示 |

中文搜索增强及其持久化设置仍是普通用户功能，不与这个仅会话有效的调试开关混同。
Settings 页脚明确提醒：**开关只控制调试工具的显示，不重置先前调整的设置**；例如以前
改过的地点权重在关闭后仍保持。隐藏 Clear index 不是本次设计：它仍在 Maintenance，
必须由用户主动选择并确认，切换调试开关不会触发它。

## 状态与关闭行为

- `AppState` 提供会话标志；单照片检查的执行入口也检查标志，不是仅隐藏按钮。
- 查看器通过 `onReceive` 响应实际开关变化；兼容可选 `AppState` 的旧调用方式，
  **没有 `AppState` 时不显示调试工具**，不默认放行。
- 先前修复已使查看器 Combine 订阅忽略未变化的值，避免重复订阅回放触发反复清空 nil
  的反馈，令处理幂等；不改正常看图逻辑。最新改动另仅缩小 Advanced 的 AX ID 作用域。
- 关闭时同时隐藏两个诊断入口并收起其 sheet，清除单照片检查报告／问题状态；
  活动预览比较注册弱引用取消回调，关闭时取消，避免仅移除界面却继续运行。
- 关闭调试**不取消索引、搜索或语言包准备**，不修改查询、当前结果、权重、模型或缓存；
  不清库、不自动重建索引。只清理上述临时诊断状态，不重置普通用户状态。

## 升级与交付

本版改动范围是展示／调试门控及版本号；后续修复包括测试／发布器、查看器幂等处理和
最新 Advanced 标签 AX ID 作用域调整。核心、正常搜索／索引 API、模型、PhotoKit 取图策略和翻译
引擎没有变更。20 worker、HQ224／Fast、模型与图像／地点缓存身份不变。从 **0.4.0 或
0.3.4 已有当前策略 `photokit-hq224-fast-fallback-v1` 的有效索引**升级无需迁移，
不卸载、不清库，也不用为了升级执行 Index / resume。更早版本迁移要求不因此取消。

公开转换本身不改上述引擎、模型、20 worker、HQ224／Fast、翻译或缓存契约。
build 12 的完整构建、公开 Release 发布及新 IPA 全量长度／SHA-256 校验**均已完成**。
现在可按 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)，用**原 Sideloadly Apple
账号／原有效 Bundle ID 覆盖安装**。已有当前策略索引／就绪语言包直接沿用，正常搜索／
看图；不要求卸载、Clear index、重建图像／地点、Index / resume、指定查询、诊断或截图。

**PENDING-DEVICE**：本轮用户侧签名／安装、真实用户模式交互、系统翻译／语言包同意、
离线质量／延迟、20 槽稳定性、内存／发热、Photos／GPS 覆盖及文件保护仍待真机验证。
免费标准 `macos-15` 的平台限制、计费／权限不变；**无项目级许可证**及第三方
`redistributionApproved: false`／人工再分发审查边界不变。

### 2026-09-28 转公开前的构建与交付历史

以下“当前 HEAD／私有／先处理计费／不重试”保留当时检查点含义，不是现行条件。
当前路线以页首和 [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md) 为准；历史失败不改写。

第二轮源码 **`d2174787c1bd276c9bc38e6d6d2f1efe28ef0015`** 已推送同一 `personal`
私有仓库。[CI 36396468128](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36396468128)
／[job 108843930321](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36396468128/job/108843930321)
已 **COMPLETED / FAILURE**，仅两项原生 UI 测试因与首轮相同的整行误点、等待开关 ON
失败；App 测试全部通过（除既有 1 项真机文件保护模拟器跳过）。
当前 HEAD **`70ad74b0f5e411ca60f741b1300545d1dbaf25c9`** 已提交并推送，相比第二轮
**仅新增 UI 测试行内 (0.9, 0.5) 点击修复**；全部用户 App 代码与第二轮 App 测试通过时
相同。位置依据已捕获的实际行／开关本体坐标；**第三轮未启动，修复未执行验证，不能声称
全部 9 项 UI 通过**。第二轮不含这项点击修复。版本仍为 **0.4.1 / build 12**。

[第三轮 CI 36397742264](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264)
／[job 108848065780](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264/job/108848065780)
已 **COMPLETED / FAILURE**，job **STARTUP / NOT STARTED，`steps: []`**。准确 annotation：

> The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the Billing & plans section in your settings

只能确定是**账号付款／支出限额相关的启动阻塞**，不能区分付款失败还是预算／限额问题；
**不是 Actions artifact 存储问题，也不是 Release 发布器 bug**。没有执行 App／UI 测试、
设备构建或发布，App **370**／UI **9** 只是待运行规模，不是本轮结果。

首轮源码 `2af11f6d759bcf7c021c20d73878cf4e5376dac4` 的
[CI 36394279080](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36394279080)
／[job 108836892722](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36394279080/job/108836892722)，
已 **FAILED**，不是 Actions 配额问题。首轮、第二轮设备构建均 **SKIPPED**，
没有 build 12 IPA。

失败证据 **6 项资产已上传并核验至 Release 398051690**，随后更新 draft 状态的
PATCH 漏传 tag，GitHub 将未发布 Release 的 `tag_name` 改为
`untaged-e8f3a293686e58364ecc`。实际 API 回读为 **`draft: true`、无 IPA**；
原发布器日志状态为 **`unknown`**，严格身份检查失败。首轮预期
`ci-36394279080-1` 不是有效安装入口，证据上传不等于发布／交付；该旧 draft 保留原状。

**第二轮发布器的失败证据 draft 路径 SUCCEEDED**，显式 tag 修复已在这条真实路径验证，
首轮发布器 bug 已解决；不是普通成功 Release 发布，不代表首轮旧 draft 被修复或 IPA 交付。
第二轮 **Release 398066345／tag `ci-36396468128-1`** 仍为 **DRAFT、无 IPA**，
发布器步骤 **SUCCESS**；这是失败证据，不是安装入口。

继续现有私有 Release 交付，不改权限、不用 Actions artifact 存储交付新 IPA。
**build 12 未交付、未完成本地校验**；build 11 已下载的包不是 build 12。
现在不安装新版，继续使用现有 **0.4.0**。账号所有者需要手动查看 GitHub
**Settings → Billing & plans** 的付款及支出限额状态；不自动改计费、不建议自动提高
限额或增加支出、不索取凭据，也不追加重试。只有阻塞解决、后续新运行通过测试和设备构建，
才进入私有 Release 上传、新 IPA 下载及长度／SHA-256 核验；这是后续条件，不是已启动任务。
完成后用原 Sideloadly 账号／有效 Bundle ID 覆盖安装；已有当前策略索引与就绪语言包
继续沿用，不清库、不重建、不必 Index / resume，也不要求重复诊断、准备语言包或测试指定查询。

## 历史验证账本（2026-09-28，转公开前；不是当前公开 CI 结果）

### 首轮实际结果（不是修复版通过记录）

- App **370 项、1 跳过**；**25 个断言失败仅来自 7 项 `DebugToolsPresentationTests`**，
  不是 25 项测试失败。进程内 AX 读取对全部元素都为零，包括普通控件；不能由此
  认定普通功能被调试门控隐藏。`DebugToolsStateTests` **14 项全通过，0.140 秒**。
- 独立 UI **9 项中 2 项失败、7 项通过**：已下载校验的首轮失败 UI ZIP 中，两份
  debugDescription 文本显示 `show-debug-tools` 对应整行，`row.tap()` 点中行中心
  标签区域而非右侧开关本体；两项点击后值都仍为 **0**，等待 ON 失败。**此前
  “视口移动导致失败”的猜测已撤回，未观察到生产开关失效**。仅检查文本、未查看图片，
  详细 AX 坐标及 ZIP 身份见 [BUILD_STATUS.md](BUILD_STATUS.md)。其余回归通过；
  设备构建跳过，无 IPA。

### 第二轮实际结果与测试方法

- 新增 `DebugToolsStateTests` **14** 项、`DebugToolsPresentationTests` **7** 项仍合计
  **21** 项，第二轮全部通过且已计入 App 总数；本轮两套件精确耗时未提供，不沿用首轮耗时。
  第二轮 App **370 项：369 通过、1 项真机文件保护在模拟器跳过、0 失败（130.279 秒）**。
  `PresentationNavigationTests` 由 3 增至 **5**，加既有 **4** 项 `SearchKeyboardTests`，
  独立 UI **9 项：7 通过、2 失败（319.699 秒）**；两项均仍是整行点击未命中开关，
  等待 ON 失败，与首轮同一根因。测试耗时不是手机性能。
- 原生展示测试改用**公开 UIKit 的真实行布局、非空白渲染像素与同一真实 SwiftUI host
  的 OFF → ON → OFF 稳定性**，不只断言派生状态，也不依赖首轮全零的进程内 AX
  读取。这是原生视觉验证，**不冒充无障碍语义验证**；不使用进程内 AX 是测试方法的
  边界，**不表示 App 没有 AX**，展示通过也不等于跨进程 UI 已全部通过。
- 真实 Settings／Library 的语义仍由**跨进程 XCUI 明确断言，未削弱**；继续覆盖全局
  开关、普通控件、调试项及重启后会话重置。原有滚动／视口变化后重新获取调试开关、
  再等待目标值的处理仍保留，但它不解决点中标签的问题。默认 Settings 仍滚动检查普通控件，单一视口断言只有
  一个 **Show debug tools** 开关；不声称整页只有一个开关，中文搜索增强仍保留。
- 第二轮 UI ZIP 已下载并校验，四张用户模式合成图已提取，父流程已实际查看联系图，
  具体可见范围如下；这是独立的有限视觉审核，不把测试通过或证据上传本身当成审核。
- 发布器自己发起的每次 PATCH 显式携带 `tag_name`（`run.tag`）与
  `target_commitish`（运行源码 SHA），保留严格身份检查，不接受错 tag 作为成功。
  模拟真实 GitHub 未发布 Release 行为的回归已加入，本地 **88 项 Node 发布器测试
  PASS（此前 83 项）**；第二轮另已验证线上失败证据 draft 路径成功，显式 tag 修复有效，
  不代表普通成功 Release 发布或整轮 CI 通过。
- 没有削弱数值门槛：真实 **20 槽工厂 120 次预测／252 项测量**与原 **23／58**
  都保留，包含在第二轮通过的 App 测试中；不补写未提供的子套件耗时／数值极值。
  **未削弱调试功能或语义断言，未新增跳过测试**；唯一既有跳过仍是真机文件保护模拟器限制。
  不能以本地发布器测试代替 iOS 编译、原生／UI 或手机验证。
  系统翻译、真机稳定性与许可审查仍沿用既有待验证边界，build 11 历史记录不改写。

### 第二轮四张用户模式图：已完成有限视觉审核

UI ZIP asset **594909127**，精确 **32,920,094 字节**；SHA-256：
`59e77bd362d1ed25a38b5c06a2b11df2f512b09e2c52b09eeed6e0031c4530d7`。
已下载并校验至 [../build/ui-review/36396468128/UIReview.zip](../build/ui-review/36396468128/UIReview.zip)。
仅提取四张 `UIReview-user-mode-*` 图，父流程已实际查看
[1340×758 联系图](../build/ui-review/36396468128/user-mode-contact.jpg)：

| 已审核附件名 | 实际可见范围 |
| --- | --- |
| UIReview-user-mode-settings-default | Settings 底部 Show debug tools 为 OFF，Maintenance 与隐私说明可见。 |
| UIReview-user-mode-library-default | 连接 Photos 入口及 iCloud 控件可见，索引按钮禁用；无 Details。 |
| UIReview-user-mode-viewer-default | 空查看器、调试 OFF；仅分享入口可见。 |
| UIReview-user-mode-viewer-debug | 空查看器、调试 ON；分享、照片检查、本地预览对比均可见且禁用。 |

均为合成空状态／未授权场景，空查看器不读取 Photos；**不是私人照片或真机证据，也不能
证明开关语义点击成功**。其他 ZIP 图片未查看，不声称截图总数或全部审核。
当前 HEAD 仅改测试，App 源码与第二轮相同，因此上述结论适用于当前 App 的相同场景；
**不能标为第三轮新产物或新运行验证**，也不代替点击修复后尚未完成的 9 项 UI 验证。

### 第三轮：点击修复已提交／推送，但 job 未启动

当前 HEAD **70ad74b0f5e411ca60f741b1300545d1dbaf25c9** 仅新增一处 UI 测试点击修复：
将整行中心点击改为已识别行内的归一化
坐标 **(0.9, 0.5)**，命中右侧开关本体，保留原有滚动／重新获取元素／等待值的处理。
第二轮 **36396468128／d2174787** 不含此改动，全部用户 App 代码此后未变。
第三轮 **36397742264／108848065780** 已 **COMPLETED / FAILURE**，账号计费阻塞导致
**STARTUP / NOT STARTED，`steps: []`**。先前 HTTP 204 仅代表接受 dispatch 请求；
App **370（349＋14＋7）**／UI **9** 没有执行，点击修复尚未验证通过，没有设备包。
它只调整测试点击位置，不修改生产开关；该历史轮次的最终结果仍为启动失败。

状态见 [BUILD_STATUS.md](BUILD_STATUS.md)，安装见
[WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)；翻译与交付契约分别见
[QUERY_TRANSLATION.md](QUERY_TRANSLATION.md)、
[PRIVATE_RELEASE_DELIVERY.md](PRIVATE_RELEASE_DELIVERY.md)。历史构建结果不作为新公开运行结果；
当前公开约束见 [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md)。页首记录本轮实际成功与已交付
证据，上述历史“未交付／未验证／继续使用旧版”仅描述当时检查点，不是当前安装要求。