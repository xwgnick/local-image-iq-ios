# Local Image IQ · Native iOS

SwiftUI + PhotoKit + Core ML。独立离线 App，不是桌面网页套壳。

## 当前：0.4.1（build 12）公开 CI 正在运行；本地发布器 94 项 PASS，暂无新 IPA

2026-09-28，用户明确选择**公开仓库＋免费标准托管 runner**，并再次确认接受既有历史
（作者邮箱、机器路径、测试查询）、历史 Actions 日志及已发布 Releases 公开。
同一仓库 [xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios)
已由 GitHub API 和匿名 GET 确认为 **PUBLIC／`private: false`**。
没有重写历史、删除内容、改动企业 `origin` 或调整计费、预算、卡片及付费限额。

- **仅公开源码，不设置项目级许可证**；不是采用 MIT／Apache-2.0 许可的项目，
   公开可见不授予一般复用权。第三方模型／地点／Pillow 权利不变，
   `redistributionApproved: false` 及人工再分发审查仍保留。
- 当前公开下载是[旧版 0.4.0 / build 11 Release](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)
   （**398009938**），**无需 GitHub 登录**；它不含 build 12 用户模式更新。
   两个旧失败 draft 保持不变，不因仓库公开自动发布。
- CI 只允许精确仓库且 `private == false` 的手动 `workflow_dispatch`，使用标准
   `macos-15`，不用付费 larger／self-hosted runner，也无 fork／PR 特权触发。
   保留全部门槛及 job 级 `contents: write` Release 交付，使用 `GITHUB_TOKEN` 而非 PAT。
- GitHub 对公开仓库标准 hosted runner 用量免费，仍受使用政策、运行限制及可用性约束；
   **不重置账号已用的私有 Actions 分钟或历史累计用量**。本次公开 job 已实际启动，
   不再是旧私有运行的计费启动阻塞。
- 新源码 **`f553cd7285d62171ce1d9ccf0c1f84c8b43e2fb5`** 已推送 `personal`。
   2026-09-28 最新检查点：[公开手动 CI 36400923391](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36400923391)
   ／[job 108858329166](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36400923391/job/108858329166)
   **IN_PROGRESS，确实正在运行**；源码检查步骤已通过，当前正在生成公开地点包。
- 本地使用指定的 **Node 22** 可执行文件运行发布器 mock 测试，父流程实际计数为
   **94 项全部 PASS**；Node／源码／工程／打包检查也已本地 PASS。这不是预期数，
   但也不代表新 CI 全部测试／回归通过。App **370**／UI **9** 仍只是本轮待验证规模，
   最终开关点击修复仍待原生 UI 验证。
- 预期公开 Release tag 为 **`ci-36400923391-1`**，**目前尚不存在**，不是下载入口；
   **没有 0.4.1 IPA**，设备构建、发布和新包本地核验仍待全部门槛通过。

工程仍为 **0.4.1 / 12**；公开转换不改引擎、模型、20 worker、HQ224／Fast、翻译或
索引／缓存身份。已有当前策略索引不因转公开清库或重建。安装继续使用已交付的 build 11，
等待上述已在运行的完整公开构建；只有全部通过、发布并完成新 IPA 长度／SHA-256 核验后才更新交付状态。
本次仅编辑指定文档，不运行命令、Git、CI、测试或下载，不修改源码或远端设置。

公开范围、有限扫描及权限说明见 [docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md)；
状态见 [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)，安装见
[docs/WINDOWS_IPHONE_INSTALL.md](docs/WINDOWS_IPHONE_INSTALL.md)。

## 历史检查点（2026-09-28，转公开前）：0.4.1（build 12）— 第三轮计费启动失败；无 IPA

以下版本历史保留当时事实；其中“当前 HEAD／私有／需要登录／先检查计费／不重试”
均指转公开前对应阶段，不是现在的访问条件或操作要求。当前公开路线及待验证项以页首和
[docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md) 为准，不抹去旧错误或旧测试结果。

[第三轮 CI 36397742264](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264)
／[job 108848065780](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264/job/108848065780)
已 **COMPLETED / FAILURE**，但 job **STARTUP / NOT STARTED，`steps: []`**，没有执行测试、
设备构建或发布。GitHub 的准确 annotation 为：

> The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the Billing & plans section in your settings

这是**账号付款／支出限额相关的启动阻塞**；现有证据不能区分付款失败还是预算／限额问题。
**不是 Actions artifact 存储问题，也不是 Release 发布器 bug**。需要账号所有者手动查看
GitHub **Settings → Billing & plans** 的付款及限额状态；不自动修改计费、不建议自动提高
限额或增加支出、不索取凭据，也不追加重试。当前继续使用已安装的 **0.4.0 / build 11**。

第二轮源码 `d2174787c1bd276c9bc38e6d6d2f1efe28ef0015` 已推送同一个人私有仓库
`xwgnick/local-image-iq-ios`（`personal`）。
[CI 36396468128](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36396468128)
／[job 108843930321](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36396468128/job/108843930321)
已 **COMPLETED / FAILURE**，仅 **2 项原生 UI 测试**仍因整行点击未命中开关、等待 ON
失败，与首轮是同一根因；设备构建 **SKIPPED，没有 IPA**。

- App **370 项：369 通过、1 项真机文件保护在模拟器跳过、0 失败（130.279 秒）**。
   `DebugToolsPresentationTests` **7 项**、`DebugToolsStateTests` **14 项**全部通过；
   已计入 App 总数，两套件本轮精确耗时未提供，不沿用首轮耗时。
- 独立 UI **9 项：7 通过、2 失败（319.699 秒）**，失败均为上述开关 ON 断言。
- 发布器的**失败证据 draft 路径 SUCCEEDED**，显式 tag 修复已在这条真实路径验证，
   首轮发布器 bug 已解决；**不是普通成功 Release 发布，更不是 IPA 交付**。

当前 HEAD **`70ad74b0f5e411ca60f741b1300545d1dbaf25c9`** 已提交并推送；相比第二轮
**仅新增 UI 测试点击位置修复**，在已识别行内点击归一化坐标 **(0.9, 0.5)** 命中右侧
开关本体。全部用户 App 代码与第二轮 App 测试通过的版本相同。
该坐标依据已捕获的实际行／开关位置；**第三轮未启动，点击修复尚未执行验证，不能声称
9 项 UI 全通过**。App **370**／UI **9** 仅为待运行测试规模，不是第三轮结果。
第二轮不含这项点击修复。版本仍为 **0.4.1 / build 12**。

第二轮失败证据保存在 **Release 398066345／tag `ci-36396468128-1`**，仍为 **DRAFT、无 IPA**；
发布器步骤 **SUCCESS**。UI ZIP（asset **594909127**，**32,920,094 字节**）已下载并校验至
[build/ui-review/36396468128/UIReview.zip](build/ui-review/36396468128/UIReview.zip)，
SHA-256：`59e77bd362d1ed25a38b5c06a2b11df2f512b09e2c52b09eeed6e0031c4530d7`。
仅提取四张 `UIReview-user-mode-*` 图，父流程已实际查看
[1340×758 联系图](build/ui-review/36396468128/user-mode-contact.jpg)：Settings 底部开关 OFF，
Maintenance／隐私说明可见；Library 连接入口、iCloud 控件可见，索引按钮禁用、无 Details；
空查看器 OFF 时只有分享入口，ON 时分享／照片检查／本地预览对比三入口均可见且禁用。
这是合成空状态／未授权场景，**不是私人 Photos 或真机证据，也不能证明开关语义点击成功**。
其余 ZIP 图片未查看，不声称截图总数或全部审核；App 代码未变，第二轮视觉结论适用于当前
App 的相同场景，**但不是第三轮新产物或新运行验证**。

首轮源码 `2af11f6d759bcf7c021c20d73878cf4e5376dac4` 的
[CI 36394279080](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36394279080)
／[job 108836892722](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36394279080/job/108836892722)
已 **FAILED**，**不是 Actions 配额问题**：

- App **370 项、1 跳过**；**25 个断言失败仅来自 7 项 `DebugToolsPresentationTests`**，
   不是 25 项测试失败。进程内无障碍（AX）读取对所有元素都返回零，普通控件也如此，
   不能据此判定普通功能被隐藏。**14 项状态测试全部通过（0.140 秒）**。
- 独立 UI **9 项中 2 项失败**：已下载校验的首轮失败 UI ZIP 中，两份 debugDescription
   文本显示 `show-debug-tools` 标识的是整行，而非右侧开关本体；`row.tap()` 点中行中心
   的标签区域，两项测试点击后值都仍为 **0**。**此前“视口移动导致失败”的猜测已撤回，
   实际是点击位置未命中开关**，未观察到生产开关失效。仅检查文本，未查看图片；详细
   AX 坐标见[构建状态](docs/BUILD_STATUS.md)。其余回归通过；首轮设备构建
   **SKIPPED**，**没有 build 12 IPA**。
- **6 项失败证据资产已上传并核验至 Release 398051690**；随后更新 draft 状态的
   PATCH 漏传 tag，GitHub 将未发布 Release 的 `tag_name` 改为
   `untaged-e8f3a293686e58364ecc`。实际回读 **`draft: true`、无 IPA**；原发布器日志
   状态为 `unknown`，严格身份检查失败。`ci-36394279080-1` 只是首轮预期 tag，
   **不是有效安装入口，证据上传不等于发布／交付**。

第二轮已包含的修复改用公开 UIKit 的真实行布局与非空白渲染像素，验证原生 **OFF → ON → OFF**
稳定性；这是视觉测试，**不冒充 AX 语义验证**。真实 Settings／Library 语义仍由跨进程
XCUI 明确断言，未削弱；不使用进程内 AX 是**测试方法的边界，不表示 App 没有 AX**。
原有滚动／重新获取开关再等待值的处理仍保留，但不是点击根因的修复。
新增点击修复已在上述 HEAD 提交／推送，**不在第二轮源码中，第三轮未启动，仍未验证**。查看器的
Combine 订阅忽略未变化的值，避免重复订阅回放触发反复清空 nil 的反馈；这是本次修复
中唯一的 App 运行时小改动，不改正常看图／搜索／索引逻辑。发布器发起的每次 PATCH
显式携带 `run.tag` 与运行源码 SHA，保留严格身份检查；模拟真实 GitHub 行为的本地
测试现为 **88 项 PASS（此前 83 项）**；第二轮另已验证失败证据 draft 路径成功，
不代表第三轮 CI 或普通成功发布已通过。

继续现有私有 Release 交付，权限不变，不用 Actions artifact 存储交付新 IPA；
**没有 build 12 设备编译成功或 IPA 交付／本地校验证据**。
正常搜索／看图、20 worker、HQ224／Fast、翻译、模型、索引策略及图像／地点缓存身份
均不变；下列调试门控是 build 12 的实现说明，不表示已安装的 0.4.0 已含该功能。

- 全部调试工具统一放在 **Settings 最底部 → Show debug tools** 后，**每次启动默认
   OFF，仅当前会话有效、不持久化**。普通使用无需打开；需要时再开这一个入口。
- 关闭时隐藏 Advanced 权重／原始分数、Diagnostics、Library Details／GPS 分项／
   worker 策略、照片检查／本地预览对比及其 sheet；清除临时诊断报告／问题并取消活动预览。
   不取消索引、搜索、语言包准备，不改查询／结果／权重／模型／缓存，不清库或重建。
- Photos 权限、Ready／数量／进度、缺预览／读取失败友好提示、iCloud 显式许可仍可见；
   结果数量、中文语言包准备、Maintenance Refresh／Clear 确认、英文提示／“使用原文”
   仍是普通功能。页脚提醒开关只控制显示，**不会重置以前的调整**；不是全 App 本地化改版。
- 新增测试仍为 **14 状态＋7 展示＝21** 项，第二轮已全部通过；第三轮未执行 App
   **370（349＋14＋7）**／UI **9**。调试功能、语义断言和数值门槛
   未削弱，未新增跳过测试；唯一既有跳过仍是真机文件保护模拟器限制。
   四张第二轮用户模式合成图已按上述范围审核，不以静态截图代替点击语义或真机验证。
- **build 12 IPA 未交付、未完成本地校验**，下方已交付的 build 11 不能当作 build 12。
   现在不安装新版；只有计费阻塞解决、后续新运行通过测试及设备构建，才进入私有 Release
   上传、新包下载和长度／SHA-256 核验，完成后再用原 Sideloadly 账号／有效 Bundle ID
   覆盖安装。这是后续交付条件，不是已启动任务或新包链接。已有 **0.4.0 或 0.3.4 当前策略
   有效索引**无需迁移，不卸载、不清库、不必 Index / resume。已装 build 11 且索引／
   语言包已就绪时，沿用即可；不要求重新下载语言包、测试指定查询或诊断，直接正常使用 App。

详见 [用户模式](docs/USER_MODE.md)、[构建状态](docs/BUILD_STATUS.md)、
[安装说明](docs/WINDOWS_IPHONE_INSTALL.md)。本次仅依据提供的事实编辑指定四份文档，
不执行命令、Git、CI 查询／触发、测试或下载，不读取／上传私人照片；build 11 及更早记录不改写。

## 历史：0.4.0（build 11）— 私有 Release 首次尝试成功，IPA 已完整下载并校验

以下保留 build 11 当时的事实、包身份与操作；“本轮／新包／现在”仅指 build 11，
不是 build 12 的通过／交付证据。当前升级与使用方式以上方及用户模式说明为准。

用户现已明确批准**方案 2：同一私有仓库 Release＋job 级 contents: write**，不是
改为公开仓库或更改计费。新源码 `844492b754f86d519c904da21cd80c1c814c056b` 相比
已通过原生／设备验证的 `0c09c46ff5edf74ffeb4a2cece2f7b9fd20a5910`，只改工作流及
两个发布／测试脚本，**没有 App、索引或模型改动**。发布器 **83 项本地 Node 22 mock
测试通过，CI 对应测试步骤也 PASS**；本轮真实上传／发布及本地下载校验均已完成。
[CI 36387878343](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343)
／[job 108817040032](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36387878343/job/108817040032)，
已 **COMPLETED / SUCCESS**，日志确认 `TEST SUCCEEDED` 和设备 `BUILD SUCCEEDED`。
这是**两次 Actions artifact 配额失败后的首次私有 Release 尝试成功**，不是 build 11 总体首轮成功。

- [私有 Release：ci-36387878343-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)
   （ID **398009938**）于 **2026-09-28T06:55:36Z** 发布，**prerelease、非 draft、非 Latest**；
   仓库仍私有。**9 项资产＝8 项载荷＋交付清单**全部上传并通过 API SHA-256 核验。
- [build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa](build/device-download/36387878343/LocalImageIQ-iphoneos-unsigned.ipa)
   **已实际完整下载并校验，可用于 Sideloadly 本机签名**。asset **594739443**，精确
   **1,414,801,288 字节**；SHA-256：`6043afbe68a84edd16d1314ecf4369f308bff8d7cf676392aee5eee6a950ca71`。
   设备报告、校验文件、交付清单及下载记录齐全；父进程直接流式复验字节／哈希一致，
   `ipaVerifiedLocally: true`，无部分下载残留，全部旧本地包保留。另一台电脑可在上述
   Release 页面登录 **xwgnick 或具有该私有仓库读取权限的账号**下载同一 IPA 并核验。

本次仅依据已核验证据更新文档，不查询 CI、执行命令、下载或追加触发。

新交付不再使用 Actions artifact 存储：仅精确匹配私有 `xwgnick/local-image-iq-ios`，
保留全局只读，构建 job 使用 `contents: write`／`actions: read` 和运行自带 token，
不新增 PAT 或 Apple 凭据。所有原生门槛不变；先建唯一 DRAFT，白名单资产逐项流式
上传并核对远端字节／哈希，全部通过后发布 prerelease，**不设为 Latest**。失败证据
保留 DRAFT；部分上传不是交付，不覆盖／删除既有 Release、tag 或资产。
详见 [私有 Release 交付](docs/PRIVATE_RELEASE_DELIVERY.md)。

**前两轮历史**：[首轮 36382669765](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36382669765)
仅两项上传配额失败，设备构建跳过；[第二轮 36383757627](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36383757627)
同样仅 Upload UI／Keep evidence 配额失败，但原生、iPhoneOS 编译和包验证通过，IPA
上传跳过。第二轮 artifacts API 为 `[]`，包身份仅见 runner 日志，未交付；旧 runner
包大小／哈希不作新包身份。完整测试、清理与历史包身份见[构建状态](docs/BUILD_STATUS.md)。

- **iOS 18+ 真机**使用系统 Translation；最低系统仍为 iOS 17，不支持时原文回退。
   本轮设备报告确认 **0.4.0 / 11、Xcode 16.4／iphoneos18.5、arm64 Release、未签名**；
   真机专用分支已编译，不等于已在手机运行。不声称要求 Apple Intelligence 或 LLM。
   模拟器不运行真实系统翻译。
- “中文搜索增强”默认开启，生产入口用 `UserDefaults.standard` 保存开关，不保存
   查询／译文。只在提交搜索时，将中文／中英混合**整个输入**译成英文；英文、含假名／
   Hangul 的输入绕过。纯 Han 短句可能歧义，简繁由系统 `NLLanguageRecognizer` 选择。
- Settings 可分别准备简体／繁体 → 英文语言对；该选择不强制搜索来源语种。缺包时仅
   显式准备入口调用 `prepareTranslation()`，由用户同意系统下载，返回后复查是否就绪。
   与照片 iCloud 联网开关独立，不改变 Photos 设置，不上传查询到 App 服务器，无云端兜底。
- 搜索会重新检查 `.installed`，host 内调用前再查，不显式准备；已知缺包或翻译失败
   显示提示并用同一原文。**检查与翻译无原子锁**，间隙中语言包被移除时，iOS 18 session
   仍可能请求系统下载提示，不能保证任何竞态下绝无 OS 弹窗。
- 搜索框保留原文，结果显示实际有效英文；“使用原文”仅本次绕过，下次普通搜索仍翻译。
   单照片检查默认用已完成搜索的有效文本；框内编辑按字面检查，不再翻译。取消、编辑、
   后台与迟到结果检查保留，已激活 host 等闭包结束；未进入后台的重复 active 不取消同意流程。
- **20 worker、HQ224／Fast 策略、模型／预处理、图像与地点缓存、Places 均不变**。
   已有 build 10 当前策略索引**不清库、不重建图像或地点、不必跑 Index / resume**。
   本轮设备报告确认同一 **768 维模型／modelVersion、2,943 要素 Places**。新 IPA
   约 **1.4 GB**，精确字节／哈希见上；语言包另占系统空间、不打进 IPA，
   实际语言包大小未测量。

**本轮实测（36387878343）**：核心 **79 通过**；App **349 项：348 通过、1 项真机文件保护在
模拟器跳过、0 失败（108.139 秒）**。新增 **42 状态（0.404 秒）＋32 桥接（0.310 秒）＋
5 展示（0.438 秒）**全部通过，已计入 App 总数。GeneratedModelParity **8 通过
（81.423 秒）**，含真实 20 槽工厂 **120 次预测／252 项测量**，原 **23／58** 门槛
不变且通过；独立 UI **7 通过（199.344 秒）**。测试耗时不是手机性能。

截图 ZIP 已下载校验，**仅提取并审核四张新增翻译截图**的
[1340×758 联系图](build/ui-review/36387878343/query-translation-contact.jpg)：普通态原中文／
英文／“使用原文”清楚，缺包提示及设置入口可见；Settings 四控件及屏内页脚可读但较密；
大字号原文／英文／按钮可见，下方空状态延伸到屏外，**不代表整页审核**。其余截图未提取／
查看，总数未核实；5 项展示测试不是按钮 UI 自动化。均是假翻译／零结果合成场景。
**PENDING-DEVICE**：真实系统翻译、离线质量、延迟及同意弹窗行为仍未测量。

**旧产物说明（适用于下方全部历史章节）**：用户仅批准删除已有本地备份的旧 IPA
云端产物；已分两阶段完成 **9＋1＝10 个**：首批 9 个为 **9,906,302,776 远端字节**，
后补最早 IPA（run 35636586662／artifact 10656339002）为 **709,538,194 远端字节**，
合计 **10,615,840,970 远端字节**。各本地备份均在删除对应云端产物前核验长度／SHA-256；
全部 10 份本地 IPA 保留并再次核验有效，源码、日志和测试报告保留。
对应旧云端 IPA 链接现已失效，仅作历史记录；原测试计数不变。清单及配额说明见
[构建状态](docs/BUILD_STATUS.md)。首批 9 个删除后的只读远端清单为 **31 个／1,837,708,271
字节**；扣除最后 1 个后推算剩余 **30 个／1,128,170,077 字节**，不是重新完整盘点。
其余测试／证据包未动，也未获准删除；这些仓库数字**不能证明配额可用**，账号套餐、
全量存储与本月累计用量未知。GitHub 官方计费说明：删除不清除已累计的月度存储用量，用量每
**6–12 小时**更新，等待不保证恢复上传。

此前“先确认实际阻塞再商讨”的阶段已结束，**当前私有 Release 路线已获明确批准**。
仓库可见性、计费与其余产物不动；macOS 分钟仍按原规则计量，不承诺免费。

**现在可用上方已校验的 build 11 IPA 签名安装**：原 Sideloadly 账号／有效 Bundle ID
覆盖安装，不卸载、不清库；
Settings → 中文搜索增强 → 简体中文 → 英文 → 下载离线语言包并同意，确认就绪后搜索
**身份证**，比较实际显示的英文及“使用原文”，不保证译为 “ID card” 或提升检索效果。
可选在语言包下载后关闭全部网络再试真机；
不要求整库重跑或诊断截图。详见 [中文搜索增强](docs/QUERY_TRANSLATION.md)、
[构建状态](docs/BUILD_STATUS.md)和[安装说明](docs/WINDOWS_IPHONE_INSTALL.md)。

## 历史：0.3.4（build 10）— 首轮验证通过，IPA 已完整下载并校验

以下及后续旧版章节保留当时结果与步骤，“当前／本次／现在”仅指对应历史版本。
build 10 的一次输入策略迁移不是 build 11 翻译升级要求；已在当前策略上的索引无需重跑。

源码 `3381fa6750f8efa76aa0895a72963c2d56a497f5` 的
[CI 35991227461](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461)
／[job 107605532969](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35991227461/job/107605532969)
已 **SUCCESS，首轮通过，无需修复重跑**；日志确认 `TEST SUCCEEDED` 和设备
`BUILD SUCCEEDED`。build 10 新 IPA 已实际完整下载并通过长度／SHA-256 校验，
现在可用于 Sideloadly 本机签名；真机效果与许可审查仍待完成。

### 已实现：先取本地高质量 224，再按条件退回 Fast

- 索引先请求短边目标 **224** 的 `.highQualityFormat`，禁止联网；只有没有可用本地
   资源时，才请求同目标的 `.fastFormat`，仍禁止联网。两路均保留 `.aspectFit`、
   `.current`、`resizeMode = .fast`，不调用原图 API。224 是请求目标，不是实际返回
   尺寸保证；后续模型预处理仍按原规则生成 224×224 张量。
- 任一路返回可用像素即接受，包括降质图和只回调一次的情况，不为等待高清而丢弃它。
   取消、权限／授权失败、无像素的普通错误**不触发兜底**。只有两次本地请求均无可用
   资源，且用户已显式允许联网，才允许第三次高质量联网请求；联网默认关闭。
- 已有真机个例中，Fast 返回 **68×120**，高质量 224 返回 **224×398**，高质量 480
   不可用。这里只保留匿名尺寸结论，不嵌入／上传私人照片、文件名或截图；不能推广到
   全图库，也不能据此保证清晰度或检索改善。三路诊断和正常图片显示均未改动。

### 模型不变，但输入策略变化需要重新编码

同一 SigLIP 2 成对模型、**768 维／FP32**、`modelVersion`、tokenizer、预处理及
**2,943 要素四国地点包**不变。新输入策略 `photokit-hq224-fast-fallback-v1` 替换
实际已发布的 `photokit-preview-v1`。下一次 **Library → Index / resume** 会自动
重新编码旧策略行，**不需要手动 Clear index**。旧策略向量在新行成功提交前不参与
搜索，也不计入当前有效索引数；迁移期间可搜数量可能减少甚至为 0，排名也可能变化，
不承诺搜索保持原样。已提交且仍有效的新策略行可复用，中断后无需从零重做；通过
Fast 兜底生成的行同样缓存，**不会自动升级为更高质量输入**。

地点文本缓存同样以完整的 `IndexImagePolicy.cacheVersion` 为键，因此**旧策略地点
文本向量也不能跨此次迁移复用**；新策略内相同地点文本仍共享缓存，只需编码一次。

### 20 个独立图像 actor：已批准的高内存实验

生产工厂提供 **20 个独立图像模型 actor／槽位**：复用 1 个常驻主图像 actor，另
**19 个仅图像 actor** 在索引作用域内懒加载，子任务全部结束后释放作用域持有；中央
仍仅 **1 个文本模型＋1 个 tokenizer**。滚动窗口把进行中和完成待顺序提交的项目
一起计入 20 槽；每顺序提交一项才补位，慢队首可能阻塞补位，**不是每 20 张一批**。
地点处理、写库、进度仍按快照顺序，保存成功后才发布计数；取消／错误退出会取消并
等待子任务结束。有效缓存命中不取图、不图像推理，纯缓存扫描不加载额外 19 份模型。

额外模型和并发张量会增加内存；这是用户明确批准、将用 **iPhone 15** 测试的实验，
**可能被 iOS 因内存压力终止**。不静默限制或自动缩回 4，不保证系统立即回收内存，
不证明硬件同时执行 20 路，也不承诺比四槽快 5 倍或一定完成整库索引。

### 验证状态与接下来怎么用

- Swift 核心 **79 通过**；App **270 项：269 通过、1 项真机文件保护在模拟器跳过、
   0 失败（122.720 秒）**。请求测试 **38 通过（0.694 秒）**，此前为 **26，不是 25**，
   新增 12 项；管线 **19 通过（1.124 秒）**、三路比较 **18 通过（0.074 秒）**、
   比较展示 **19 通过（1.340 秒）**。这些子套件均已计入 App 总数。
- `GeneratedModelParityTests` **8 通过（94.326 秒）**：真实生产工厂的 20 个图像
   actor × 6 夹具实际完成 **120 次预测、240 项归一化比较＋12 项张量测量＝252 项**；
   原 **23 次预测／58 项测量**也通过，门槛未改。UI **7 通过（202.650 秒）**；
   测试耗时不是手机性能。导出报告 `parityPassed:true`、23 cases，极值见构建记录，
   不是原生数值极值。新策略与 20 actor 的依据是源码及测试，不是设备报告中的策略字段。
- [build/device-download/35991227461/LocalImageIQ-iphoneos-unsigned.ipa](build/device-download/35991227461/LocalImageIQ-iphoneos-unsigned.ipa)
   **已完整下载并校验**，本地 **1,414,733,291 字节**；SHA-256：
   `0e1bc7ece93af94745e81e780d9ddf3fc78b9173c2e987a68710322be46bf7ff`。
   设备报告和校验文件齐全，无部分下载残留，旧包保留；设备报告确认 **0.3.4 / 10、
   arm64 Release、未签名**及同一模型／地点包身份，仍需本机签名。
- 24 张 UI 截图已下载，**仅审核 3 张索引／地点界面**的
   [build/ui-review/35991227461/hq20-index-contact.jpg](build/ui-review/35991227461/hq20-index-contact.jpg)
   （990×742）：Library 回填后／零 GPS、Settings 尚未检查地点的可见内容清楚。
   折叠项未展开，屏外联网页脚／20 worker 标签和其余 21 张均未视觉审核；合成界面
   不是实际图库或硬件 20 路并发证据。
- **PENDING-DEVICE**：本机签名／安装、迁移效果、20 槽稳定性、文件保护与性能；
   **PENDING-LICENSE-REVIEW**：模型及地点再分发仍需人工审查。

1. **使用上方已下载并校验的 build 10 IPA**，无需等待新包或重新下载；不追加诊断／截图任务。
2. 用原 Sideloadly 账号、原有效 Bundle ID **覆盖安装，不卸载、不清索引**。
3. 保持 Network **OFF**，打开 **Library → Index / resume** 跑一次并保持前台。
   模型没换，但输入策略变了，所以旧策略照片需要重新编码。
4. 完成后再试搜索。若 App 被终止，重新打开并点同一入口续跑；已成功提交且仍有效的
   前缀保留，未提交工作需重做，但不保证 20 槽配置一定能跑完。

详细状态见 [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)，操作见
[docs/WINDOWS_IPHONE_INSTALL.md](docs/WINDOWS_IPHONE_INSTALL.md)。

## 历史：0.3.3（build 9）— 首轮验证通过，IPA 已完整下载并校验

以下保留 build 9 的原始结果与当时操作；其中“当前／本次”仅指当时。无需现在重做
诊断；“不用点 Index / resume”不适用于 build 10 的输入策略迁移。后续旧版章节同理。

源码 `9e055b13be62ca184593387b1b5dc647b3a85a26` 的
[CI 35965638523](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523)
／[job 107523495276](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523/job/107523495276)
已 **SUCCESS，首轮通过**；日志确认 `TEST SUCCEEDED` 和设备 `BUILD SUCCEEDED`。

- Swift 核心 **79 通过**；App **258 项：257 通过、1 项真机文件保护在模拟器跳过、
   0 失败（96.471 秒）**。其中加载器 **18 项（0.060 秒）**、状态／展示 **19 项
   （1.248 秒）**、GeneratedModelParity **8 项（71.345 秒）**全部通过，均已计入 App 总数。
   真实四图像 actor 的 **24 次预测／60 项测量**及原 **23 次／58 项**门槛均通过且未改。
   UI **7 项全部通过（198.491 秒）**；这些耗时不是手机性能测量。
- [build/device-download/35965638523/LocalImageIQ-iphoneos-unsigned.ipa](build/device-download/35965638523/LocalImageIQ-iphoneos-unsigned.ipa)
   **已实际完整下载**，有界流式读取核验实际长度／SHA-256 后才最终重命名；本地 IPA
   **1,414,731,479 字节**，校验文件与设备报告齐全，无残留部分下载，旧包保留。
   SHA-256：`5c36d87fa1b5845a6806274a200ad602a917b778da5398b49116b2e9b303328b`。
   设备报告确认 **0.3.3 / 9、arm64 Release、未签名**，仍需 Sideloadly 本机签名。
- 24 张 UI 截图已下载，**仅审核 4 张新增预览图**的
   [build/ui-review/35965638523/local-preview-contact.jpg](build/ui-review/35965638523/local-preview-contact.jpg)
   （1340×758）。三列尺寸／元数据、等框、不可用状态及同一区域细节可见；大字号
   仅看见菜单和首个大面板，屏外元数据／其余面板未审核，也未实际点击／滚动验证。
   图像均为生成的假像素，不是实际 PhotoKit 或清晰度证据。

用原 Sideloadly 账号／原有效 Bundle ID **覆盖安装 build 9，不卸载、不清索引、不重建，
也不用点 Index / resume**。打开 App 前先开飞行模式并关闭 Wi-Fi；搜索
`a hand holding a broken white pen` 找到此前的破损白笔照片，或任选当前可访问的结果。
点开照片 → 底部“本地预览对比” → 自动依次请求 Fast 224／高质量 224／高质量 480。
先发默认三路“等框对比”截图；可选“同一区域细节”选区后再截图。照片／搜索词没有硬编码。

三路禁止联网，但 App 不检测飞行模式；打开 App、先前看图及前一请求都可能预热系统缓存，
本流程不绕过缓存。实际返回 CG 像素更大或原始降质标记为“否”，都不保证更清晰。
仅内存对比，不调用索引 worker、编码器或 SQLite；同一 SigLIP 2、四 worker、Places、
预处理／索引、正常显示及默认联网策略不变，不是质量修复。
**PENDING-DEVICE**：本机签名／安装、真实 PhotoKit 离线结果、速度／内存／发热仍待验证；
**PENDING-LICENSE-REVIEW**：模型及地点再分发仍需人工审查。
操作见 [docs/LOCAL_PREVIEW_COMPARISON.md](docs/LOCAL_PREVIEW_COMPARISON.md)，完整证据见
[docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)。

## 历史：0.3.2（build 8）— 4 worker 首轮验证通过，IPA 已完整下载并校验

以下仅为 build 8 的结果与当时测速说明；其包不含三路对比，本次不需清库或索引续跑。

源码：`b40d2faaf11b2f499779881b4863325fa7dae659`。
[CI 35848409845](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845)
／[job 107140049230](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/job/107140049230)
已 **SUCCESS，首轮通过**；App 版本已核验为 **0.3.2 / build 8**。
核心、模型导出、地点包、模型／App 资源检查、原生与 UI 测试及设备打包均通过。
本次仅记录已核验结果，不运行命令、测试、CI 查询／重试或下载，不操作用户手机。

### 已实现：固定 4 槽滚动窗口，不是每 4 张一起等完

- 用户明确要求 **4 worker**。每个子任务负责缓存读取、PhotoKit 预览、预处理及
   图像推理；每槽独立图像 `MLModel` actor，不再是 build 7 的单模型串行推理。
   **正在处理＋已完成待顺序提交的项目合计最多 4 个**；慢队首会阻挡补位，不能
   越过它不断积攒结果或再提交第 5 个未提交项目。每顺序提交一张即可补一个槽，
   不是 4 张全部完成才启动下一批。
- 一份常驻主图像模型复用到槽位 0，另外 **3 份仅图像模型**在索引作用域内首次
   使用时懒加载，全部子任务结束后释放作用域持有；**不是四套图文模型**。
   中央 actor 仍只有 **1 份文本模型＋1 份 tokenizer**，统一地点文本去重／缓存。
   三份额外图像模型及并发中间张量是明确的内存代价；这不证明系统即时归还全部内存。
- 地点处理、数据库写入和进度仍由父任务按图库快照顺序执行；成功保存后才发布
   对应计数。完成待提交项保留向量／结果，不保留预览像素。取消／错误退出会取消并
   等待全部最多 4 个子任务结束，之后才可进入下一个串行工作；同步 Core ML 可能
   需等本次预测返回。迟到 PhotoKit 回调由原 gate 忽略，不声称系统请求已确认停止。
- 有效图像缓存命中不取预览、不做图像推理；纯缓存扫描不会懒加载额外 3 份图像
   模型。没有新增任务超时、自动重试、图库数量／字节限制或批处理屏障。
   4 是用户要求的并发窗口，不是图库总量限制，**不承诺 4 倍提速或真机性能**。

### 不变项与本次实际验证

同一 SigLIP 2 权重／revision、FP32、`modelVersion`、预处理、
`photokit-preview-v1`、2,943 要素四国地点包、评分公式及默认地点权重 **0.6** 均不变。
本次设备报告已确认模型及地点包身份不变；完整版本和包哈希见 [构建记录](docs/BUILD_STATUS.md)。
仍本地预览优先、联网默认关闭，不要求下载原图。

- Swift 核心 **79 通过**；App **221 项：220 通过、1 项真机文件保护在模拟器
   跳过、0 失败**。`IndexPipelineTests` **19 项全部通过**，含新增 4 项；新增
   默认工厂边界测试也通过。以下原生子套件均已计入 App 总数，不重复相加。
- `GeneratedModelParityTests` **8 项全部通过（101.581 秒）**。新增真实四图像
   actor 测试使用生产工厂，每槽覆盖 6 个夹具：**6 × 4＝24 次预测、48 项归一化
   向量比较＋12 项张量测量＝60 项**，计数及图像余弦 **≥ 0.995** 门槛均已断言通过。
   原生产 API 的 **23 次预测／58 项测量**也通过，原数值门槛不变。
- UI **7 项全部通过（209.329 秒）**。本次模型报告 `parityPassed:true`；没有
   返回原始精确极值，因此不把历史最小余弦／最大误差复制为 build 8 测量。

### 已交付的 build 8 安装包与有限界面审核

- [build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa](build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa)
   **已实际完整流式下载，已验证本地字节数和 SHA-256**；校验文件与设备构建 JSON
   均已存在，没有残留的部分下载文件。仍是未签名包，须 Sideloadly 本机签名。
- [GitHub 产物 10745235946](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/artifacts/10745235946)：
   外层 **1,414,636,737 字节**，内层 IPA **1,414,629,419 字节**；IPA SHA-256：
   `7d37581966a45028213a52a0a9c504e2ed273293a92bbbad4ab9d77a0d73ef8e`。
- 取回 **20 张**原生 UI 截图，仅审核 **3 张索引／地点界面**：回填后的 Library、
   零 GPS 的 Library、尚未检查地点的 Settings；见
   [960×680 联系图](build/ui-review/35848409845/four-workers-ui-contact.jpg)。
   折叠项未展开，未检查内部全部计数，其余 17 张不计入审核；合成场景不是私人图库
   GPS 结果，更不是四 worker 真机并发、提速或内存／发热证据。

### 安装与使用：正常续跑复用缓存；从零测速可选

使用上方已验证的 build 8 包，用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**，
不卸载、不为升级清空索引／缓存。
正常打开 **Library → Index / resume**：有效 0.3.0／0.3.1 SigLIP 2 图像缓存继续
复用，地点仍会检查／按需回填，新增或变化照片才编码；联网关闭、前台运行，中断可续跑。

用户明确希望从零测速时，可在**安装后主动选择 Settings → Clear index，再打开
Library → Index / resume**，联网关闭、保持前台。这会删除 App 的已有索引／缓存，
**不会删除系统照片**，之后需要重新索引；不是升级前提或普通续跑步骤。
冷启动比较应使用 **0.3.1 与 0.3.2（同一地点包）**，两边均从空索引开始，
同一手机、同一批授权照片及数量、联网关闭、相近温度／发热和供电条件；不要把旧版
冷建与新版缓存续跑比较。当前没有实际速度／内存测试，也不要求索引抢救或追加诊断。

具体机制、测试边界与已核验结果见 [索引与地点说明](docs/INDEX_PIPELINE_PLACES.md)、
[原生验收](docs/NATIVE_PARITY.md)、[构建记录](docs/BUILD_STATUS.md) 和
[Windows 安装说明](docs/WINDOWS_IPHONE_INSTALL.md)。

## 历史：0.3.1（build 7）— 首轮验证通过，IPA 已完整下载并校验

以下 build 7 的实现、测试、安装包和当时操作说明属于旧版，不是 0.3.2 的通过或交付声明。

当时源码：`18ad52d37690ecfbf92b63a21285a6c3e8e753d4`。
[CI 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
／[job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763)
已 **SUCCESS，首轮通过，无需修复重跑**；日志包含 `TEST SUCCEEDED` 和
`BUILD SUCCEEDED`。以下是本次 build 7 的实际结果，不借用下方 0.3.0 历史记录。

- 源码／静态测试 **30 通过**，Swift 核心 **79 通过**；App **215 项：214 通过、
   1 项真机文件保护在模拟器跳过、0 失败**。全部 **7 个 GeneratedModelParityTests
   通过（67.736 秒）**，全部 **7 个 UI 测试通过（202.143 秒）**。
- App 中 IndexPipeline **15**、PlaceAvailability **17**、BundledPlaces **2**、
   IndexPlacesPresentation **3** 项均通过，均已计入 App 总数。包哈希／数量和公开城市
   点位（含纽约包外）检查通过，不代表用户图库 GPS 覆盖。公开地点生成及 `test_places`
   步骤通过；25 项是代码／既有本地记录中的数量，不另作日志实测总数。
- 模拟器／设备 App 资源检查、iPhoneOS arm64 Release 编译及 IPA 验证通过。
   本次模型导出报告为 **23 cases、92 comparisons**；最小余弦
   `0.9999999999960657`，最大分量误差 `0.000011444091796875`，配对矩阵最大误差
   `1.8557397291063538e-7`。模型版本未变；详细证据见 [构建记录](docs/BUILD_STATUS.md)。

### 已交付的 build 7 安装包与有限界面审核

- [build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa](build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa)
   **已实际完整下载**，有界内存流式长度／SHA-256 校验完成，下载后的本地报告已写入并检查。
- [GitHub 产物 10741731376](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741731376)：
   外层 **1,414,628,123 字节**，内层 IPA **1,414,620,805 字节**；IPA SHA-256：
   `98fb537004a64adaa84b1ba15d798acaf71a0684555275faddc647d1adafd8d6`。
   设备报告确认 **0.3.1 / build 7、iphoneos18.5 / arm64 Release、Xcode 16.4、最低
   iOS 17.0、未签名**；仍须 Sideloadly 本机签名，不是已在物理 iPhone 执行。
- 取回 **20 张**原生 UI 截图，仅审核 **3 张新增地点界面**：回填后的 Library、
   零 GPS 的 Library、尚未检查地点的 Settings；[960×680 联系图](build/ui-review/35840838147/index-places-contact.jpg)
   中可见内容可读。折叠项未展开，**不声称内部全部计数已做视觉检查**；
   数字来自合成场景，不是用户 GPS 结果，其余 17 张不计入本次审核。

### 本次变化与不变项

- 索引只预取下一张的缓存记录／PhotoKit 预览，与父任务处理当前张重叠。
   仍只有一份模型对、串行推理、单一路径按快照顺序保存和发布进度，不是多个推理 worker。
   取消／错误退出会取消并等待预取子任务结束；PhotoKit 无取消确认接口，迟到回调由原有
   gate 忽略，不声称系统内部请求已经停止。没有新增任意数量上限、期限或联网策略变化。
- 图像和文本仍为同一 SigLIP 2 模型对，`modelVersion`、FP32、预处理及
   `photokit-preview-v1` 均不变。**有效的 0.3.0 图像向量继续复用**，地点回填不需整库图像重编码。
- 新增中国、法国、德国、荷兰 ADM1／ADM2 离线行政区包。**实际设备包检查**确认
   **2,943 个要素、15,175,079 字节**，GeoJSON SHA-256：
   `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`。
   国家为 CHN／FRA／DEU／NLD，共 **8 个来源**；清单 SHA-256：
   `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`。
   这不只是本地源码元数据；来源代表年份为 2017–2022，
   不是现行地址、POI 或全球覆盖。来源与限制见 [索引与地点说明](docs/INDEX_PIPELINE_PLACES.md)。
- Library 分开显示本次／上次扫描观察到的“有 GPS、找到标签、无 GPS、无可用包、
   包外、地点不可用”和已保存标签数。未检查显示未知，不把地点标签为 0 当成无 GPS，
   不把扫描计数当成永久全库 GPS 统计。坐标仅在本机内存中用于查行政区，不保存或上传。
- 默认地点权重仍为 **0.6**，没有暗改。回填后有覆盖照片的地点分支开始实际参与评分，
   排名变化是预期；不承诺真机提速幅度或私人图库 GPS／地点覆盖率。

### 历史 build 7 安装步骤：覆盖安装，跑一次地点回填

1. 使用原 Sideloadly 账号、原有效 Bundle ID **覆盖安装**；不卸载、不清索引。
2. 打开 **Library → Index / resume** 跑一遍，保持 App 在前台、联网关闭；中断可续跑。
    已有且仍有效的 0.3.0 图像向量不再取预览或重编码，只检查／回填地点；
    新增或已变化照片按正常流程编码，不要求下载原图或“下载并保留原片”。
3. 完成后正常使用，不另加诊断查询或截图任务。若仍是 0.2.x 的 CLIP 索引，
    才需要下面历史说明中的 SigLIP 2 模型迁移；不要把它套用到有效的 0.3.0 索引。

本次仅依据已核验结果更新文档，未重新运行命令、测试、下载或查询 CI。
完整交付证据与仍未完成的真机／许可事项见 [构建记录](docs/BUILD_STATUS.md)。

## 历史：0.3.0（build 6）SigLIP 2 — 自动验证通过，IPA 已下载校验

以下结果、包身份和模型迁移步骤属于旧版 0.3.0，不是 0.3.1 或 0.3.2 的完成声明。

用户已批准把**图像和文本编码器一起**替换为
`google/siglip2-base-patch16-224`，两者固定同一 revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`；不是新图像模型混用旧文本模型。
源码 `f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78` 的
[CI 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
／job `107062896845` 已 **SUCCESS**；日志包含 `TEST SUCCEEDED` 和 `BUILD SUCCEEDED`。

- 30 个 Python 静态测试通过；0.3.0 核心 **79 通过**，App **178 项：177 通过、
   1 项真机文件保护在模拟器跳过、0 失败**；全部 **7 个 UI 测试通过**。
- 全部 **7 个 GeneratedModelParityTests 通过（72.985 秒）**。生产 App 编码 API
   测试实际完成并通过断言：**23 次预测（17 文本＋6 图像）、58 项测量**。
   Gemma IDs／masks（含 Final_Sigma）、完整同张量及数值门槛均未放宽。
- 首轮 [CI 35823153931](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35823153931)
   曾因原生小图缩放和 Final_Sigma 失败；改为 Pillow 兼容的 22-bit 分离式双线性
   重采样与 Unicode 上下文规则后，68×120、112×199 原生低清夹具均已通过。
- FP32 导出报告：23 cases、92 comparisons，最小余弦 `0.9999999999960657`，
   最大原始分量误差 `0.000011444091796875`，配对矩阵最大误差
   `1.8557397291063538e-7`。导出 JSON 的原生 `not-run` 产生于 XCTest 之前，
   不是失败；原生通过依据是随后执行的 XCTest。
- [0.3.0 未签名 IPA](build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa)
   当时已通过有界内存流式下载完成长度／SHA-256 校验；不是 build 7、8 或当前 build 9 的包。
   包身份与校验值见 [构建记录](docs/BUILD_STATUS.md)。
- 已取回 17 张原生 UI 截图，**只检查了首页／图库／设置／主结果布局 4 张**的
   [缩小联系图](build/ui-review/35824403795/siglip2-ui-contact.jpg)；都是合成／测试场景，
   没有私人照片，不宣称 17 张均已审核或已完成手机性能验收。

当前 modelVersion：
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。

### 历史：0.2.x → 0.3.0 的安装与模型迁移

1. 用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**，不卸载、不手动清索引。
2. **必须打开 Library → Index / resume**，用新模型建立一次向量索引；保持联网关闭。
    模型已变化，尚未生成新向量时旧模型记录的可用覆盖为 0，这是预期行为。
    不必下载原图，也不必切换到“下载并保留原片”。中断后再点同一入口，已完成且
    仍有效的新版本记录可复用，不必从零重来。
3. 索引后正常搜索、看图即可；本轮不要求再跑诊断、提交截图或尝试额外测试查询。

旧 CLIP 512 维记录仅能解码以便迁移，**不能被 SigLIP 2 的 768 维查询搜索**。
图像及地点文本向量都必须按新模型版本重算，不能混入旧向量。照片按 `id` 主键逐条
替换，因此保留旧 IPA **不等于备份旧索引**；回退安装包不保证恢复被替换的旧记录。

本次不改 `photokit-preview-v1`：仍用本地预览，可接受低清图，iCloud 联网默认关闭，
只有用户主动允许才可按需联网；不要求原图，不保证每张云照片都有可用本地预览。
这不是 PhotoKit 预览质量修复，也没有新增用户诊断要求。已有小规模离线对比结果
存在语言、分辨率和查询差异，不能宣称新模型全面更好；桌面 CPU 耗时不是 iPhone 性能。

## 历史：0.2.1 单照片检查（旧模型）

以下 0.2.x 说明和通过记录仅属旧版本，不是本轮操作要求或 SigLIP 2 验证证据。

点开搜索结果大图 → **Check this photo** → 输入原来没找到它的搜索词 → **Check**。
结果直接截图即可，不需要看懂参数。检查旧缓存排名与这张照片重新读取本地预览后的
排名，其他候选保持不变；不写回索引、不下载原图、不换模型。

这是排查工具，不是检索质量修复。安装/操作见 [单照片检查](docs/PHOTO_CHECK.md)。
云端构建通过：79 个核心测试、151 个 App 测试、7 个界面交互测试；1 项真机
文件保护测试在模拟器跳过。5 张新增原生截图已检查，新 IPA 已下载并校验。
实际手机检查结果待用户测试，完整记录见 [构建记录](docs/BUILD_STATUS.md)。

## 历史：0.2.0 界面重做（旧模型）

- 首页以搜索和照片为中心，图库状态收成一行入口，不再堆技术说明和参数。
- “图库”里管理授权、索引和 iCloud；“设置 → Advanced”里保留权重与诊断。
- Top 3 用一张大图＋两张小图；更多结果用两列照片网格，也能切换三列紧凑视图。
- 点开完整大图，左右翻页、双指缩放、双击复位、分享；顺序始终保持真实检索结果。
- 保留 Search／Done／拖动收起键盘。模型、排序、默认参数及索引版本不变，
   不需要因为 UI 更新清空或重建索引；dog/Apple-pen 的检索质量问题留待单独处理。

设计与验证范围见 [UI 重做说明](docs/UI_REDESIGN.md)，实际构建状态见下文。

## 功能与交付边界

Windows 无 Swift/Xcode；通过用户明确批准公开的同一仓库运行标准 macOS 构建，并生成未签名
真机 IPA，由用户在 Windows 用 Sideloadly 本地签名。此前版本已由用户安装并在
iPhone 上打开、索引和搜索；这不代表检索质量、内存／发热或新 UI 已完成真机验收。

历史 0.2.0 最终构建通过：79 个核心测试、113 个 App 测试、全部 7 个界面交互测试；
仅 1 项真机文件保护测试在模拟器明确跳过。12 张原生截图已检查，未签名真机
IPA 已下载并校验。这些数值测试与产物属于旧编码器，不能证明本轮 SigLIP 2 通过。
新版实际状态与交付信息见 [构建记录](docs/BUILD_STATUS.md)。

- 照片全部／有限授权、选择更多照片、前台增量索引与取消。
- 0.3.4 沿用同一 SigLIP 2 成对编码及 768 维 SQLite 缓存，改为 20 个独立图像
   actor 和高质量 224 优先的本地输入策略。旧策略行需自动重编码；迁移期间搜索和
   当前有效计数会排除旧行。build 10 CI 首轮通过，IPA 已完整下载并校验；真机速度／内存／发热待测。
- 0.4.0 仅新增可关闭的系统中文查询翻译与独立语言包准备，不改变上述模型／输入策略／
   图像和地点缓存；有效 build 10 索引无需重建。历史 build 11 的 CI、私有 Release 与
   本地 IPA 校验均已完成，真机翻译仍待验证；不是当前 build 12 的通过或交付证据，详见
   [docs/QUERY_TRANSLATION.md](docs/QUERY_TRANSLATION.md)。
- 语义搜索、结果预览与分享；不上传照片或坐标。
- 默认地点权重 0.6，支持 0...1；0.3.1 构建要求四国离线行政区包，回填后地点分支
   实际参与评分。无可用包、无 GPS、包外与不可用分开呈现，不在线反查。
- iCloud 网络访问默认关闭，用户主动开启后才允许 PhotoKit 按需联网。
- 自 0.1.1 起不再先请求原图；0.3.4 依次尝试本地高质量 224、本地 Fast 224，
   接受可用低清像素。只有两路本地资源均不可用且已显式开启联网，才可第三次请求
   高质量联网表示。PhotoKit 控制实际下载量；旧输入策略背景见
   [历史预览索引修复](docs/PREVIEW_INDEXING.md)，当前契约以页首为准。
- 0.1.2 修复搜索后键盘挡住结果：提交自动收起，键盘和导航栏提供 Done 按钮，
   支持拖动收起。已有 0.1.1 索引可复用，不因该键盘修复要求重建。
- 无模型构建只展示真实的资源缺失状态，**不伪造检索结果**；带模型的构建才包含
   经过转换和对齐验证的真实编码器。
- 当前没有 OCR、Agentic Search、Speedbird 生产模型接入或后台无限索引。

## 在 Windows 开发，使用公开仓库的标准 macOS 构建

只把 **local_image_iq_ios 这个目录的内容** 作为独立仓库根目录。
不要上传整个 BeatQwen3：其中有私人照片、演示录像、数据库和桌面缓存。
当前构建仓库为已确认公开的 `xwgnick/local-image-iq-ios`；转公开后的新完整构建尚待验证，
但公开 CI **36400923391／job 108858329166 已实际启动并在运行**，源码检查通过，
当前正在生成公开地点包；不是仅凭可见性变化推断启动，也不是旧计费阻塞。
原企业托管用户仓库 `wengxie_microsoft/local-image-iq-ios` 保留不动；它的个人
命名空间不支持托管 runner。普通个人账号与企业托管用户的限制不同，代码放置
仍须遵守相应政策。详见 [当前构建状态](docs/BUILD_STATUS.md)。

工作流：[.github/workflows/ios.yml](.github/workflows/ios.yml)，仅手动触发：

当前控制与公开范围见 [docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md)。
[docs/PRIVATE_REPOSITORY_SETUP.md](docs/PRIVATE_REPOSITORY_SETUP.md) 保留为历史私有建仓指南，
不是当前仓库设置要求；无需新建仓库。

1. 首次 `include_models=false`：Swift 核心测试、XcodeGen 生成工程、模拟器 App
   编译和 XCTest。没有模型的数值对齐测试会明确跳过。优先排除原生编译问题。
2. 随后 `include_models=true`：仅下载固定公开模型，macOS 转换、PyTorch/Core ML
   数值对齐，再运行 Swift tokenizer／预处理／模型推理夹具测试。
3. 非设备构建产物是 **Simulator App ZIP + xcresult**，不是可装到 iPhone 的 IPA。
   真机安装和 TestFlight 仍需要 Apple 签名、对应团队和后续配置。
4. Windows 个人测试路线：勾选 `include_models` 与 `build_device_ipa`，通过测试后
   额外编译 `iphoneos` SDK / arm64 Release App，生成**未签名真机 IPA**。由用户
   在 Windows 用已同意的第三方签名工具安装，不向 CI 提供 Apple 密码或证书。
   详见 [Windows 安装到 iPhone](docs/WINDOWS_IPHONE_INSTALL.md)。
5. 新运行通过同仓库**公开 Release** 交付包与测试证据，当前约束和历史协议见
   [docs/PRIVATE_RELEASE_DELIVERY.md](docs/PRIVATE_RELEASE_DELIVERY.md)；
   不再上传 Actions artifacts；上文旧 artifact 链接仅作历史记录。公开模型／地点来源
   仍固定，CI 不接收私人照片、GPS、数据库或视频。

标准 `macos-15` runner 当前为 Apple Silicon；公开仓库的标准 hosted runner 用量按
GitHub 规则免费，受平台使用政策／运行限制约束，不承诺无限资源或必定启动。
不使用付费 larger／self-hosted runner，不提高付费限额；转公开不会重置旧私有分钟或累计用量。
工作流只接受精确仓库名且 `private == false`；发布器 preflight／prepublish 都拒绝
私有或错误仓库。没有自动 push／PR 或 fork 特权触发，CI 只用 `GITHUB_TOKEN`，不用 PAT。
模型转换环境独立，不修改桌面 Python 环境。

## 工程与模型

- [project.yml](project.yml)：XcodeGen 规范，iOS 17+，Swift 5 语言模式；App 分词依赖
   需要 Swift 6 工具链，既有构建基线为 Xcode 16.4／iOS 18.5 SDK；app + 测试 target。
   build 11 系统翻译在 iOS 18+ 真机启用，iOS 17 原文回退；历史 build 11 的原生测试／
   设备编译、私有 Release 发布及本地包校验已通过，尚未验证真机运行。
   2026-09-28 转公开前，build 12 第二轮 **36396468128** 已结束，仅 2 项 UI 同因失败，App 369 通过／1 跳过／
   0 失败；设备构建跳过，无 IPA。第三轮源码 **70ad74b0f5e411ca60f741b1300545d1dbaf25c9**
   的 run **36397742264** 因计费 annotation 在启动前失败，未验证 UI 点击修复。
   当前新源码 **f553cd7285d62171ce1d9ccf0c1f84c8b43e2fb5** 已推送 `personal`，
   公开 run **36400923391／job 108858329166** 已实际运行，源码检查通过、正在生成公开地点包；
   不能预记全套原生测试／回归或设备构建通过。
- [project.models.yml](project.models.yml)：转换完成后的模型测试资源增量配置。
- [App](App)：UI、PhotoKit、Core ML、SQLite、离线行政区查询及无可用包状态处理。
- [Packages/ImageIQCore](Packages/ImageIQCore)：无第三方依赖的数学、检索、分词。
- [Resources/Models/README.md](Resources/Models/README.md)：模型导出入口与生成资源。
- [docs/IMPLEMENTATION_CONTRACT.md](docs/IMPLEMENTATION_CONTRACT.md)：固定模型配对与接口。
- [docs/NATIVE_PARITY.md](docs/NATIVE_PARITY.md)：原生数值验收，不能用维度相同替代对齐验证。

当前以 [实现契约](docs/IMPLEMENTATION_CONTRACT.md) 的 schema 2 为权威：图像
输入 Float32 `[1,3,224,224]`，文本仅输入 Int32 `[1,64]` 的 `input_ids`，双塔输出
原始 Float32 `[1,768]` 的 `pooler_output`，Swift 在存储／检索前各归一化一次。
文本池化固定取末位置 63，不使用 masked mean；`attentionMask` 仅用于夹具核对。

分词用同一 revision 原样复制的 tokenizer JSON 和配置 JSON，App 依赖固定
`swift-transformers` 1.3.4 的 `Tokenizers`，只从本地资源加载。显式小写后最多保留
63 个内容 token，追加 EOS 1、右补 PAD 0 到 64，不自动加 BOS；保留字面特殊 token。
Unicode 小写（含 Final_Sigma）和全部 17 条文本的 token IDs／masks 已在 0.3.0
通过精确原生对齐，不是沿用旧 WordPiece 结果；0.3.1 的原生 parity 也全部通过，
历史 0.3.2 和 0.3.3 的 8 项原生 parity 均已在各自 CI 全部通过；历史 0.3.4 的
8 项原生 parity 也已实际通过，含 20 槽工厂 120 次预测／252 项测量及原 23／58 门槛，
不是借用更早版本通过结果。0.4.0 第二轮 8 项通过（83.298 秒）保留为历史；历史 build 11
36387878343 的 8 项全部通过（81.423 秒），实际执行
同样的 120／252 及原 23／58 检查，门槛未改；不是手机性能测量，也不是当前 build 12 的结果。
`ImageIQCore` 自身仍是 Foundation-only；
App 的上述依赖是另一个边界。

图像按 EXIF 转正、转 RGB，直接拉伸到 224×224，不保比例、不中心裁剪；参考为
Pillow BILINEAR，均值和标准差均为 `[0.5,0.5,0.5]`。Quartz 仅转换原尺寸 RGB，
缩放使用遵循 Pillow 11.1.0 的 22-bit 分离式双线性实现，原生像素差和向量差
分开验证。FP32 是本轮基线；旧包大小、
桌面 CPU 数据或模拟器结果都不是新版手机内存、耗电、发热与速度的保证。

共享模型卡声明 Apache-2.0；导出流程复制实际存在的模型卡／LICENSE／NOTICE
证据并保留 `redistributionApproved:false`。许可证副本、转换通过和私人构建均不
等于公开分发的法律认证；仓库及既有 Release 现已公开，但人工再分发审查仍未完成。
本项目没有设置项目级许可证；模型卡声明不使整个项目成为 Apache-2.0 项目。
geoBoundaries 许可元数据与 Pillow MIT-CMU 源码头仍须分别保留、遵守，详见
[docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md)。

自 0.3.1 起的正常构建路径（含无模型构建）会生成并打包四国公开 WGS84 行政区数据及
来源清单；不是从个人照片推导边界，也不是在线地图／地址服务。每个 Polygon／
MultiPolygon 使用 `label`、`level` 等公开属性。固定来源、历史年份、许可记录和
打包检查见 [地点资源说明](Resources/Places/README.md) 与
[索引与地点说明](docs/INDEX_PIPELINE_PLACES.md)；0.3.1 的模拟器 App、设备 App 及 IPA
资源检查已通过，0.3.2 对应检查也通过；历史 0.3.3 设备报告再次确认同一地点包身份。
历史 0.3.4 设备资源检查已通过，设备报告确认同一 2,943 要素地点包及哈希；
历史 0.4.0（build 11）设备报告及已下载包再次确认同一地点包数量、字节数及哈希，
完整身份与本地复验记录见 [构建记录](docs/BUILD_STATUS.md)。

## 当前 0.4.1（build 12）待交付；真机与正式分发仍待验证

**历史（2026-09-28，转公开前）**：首轮 CI **36394279080** 已失败；第二轮 **36396468128／d2174787** 已 **COMPLETED /
FAILURE**，仅 2 项 UI 因同一整行误点而失败，App 测试通过（含既有 1 项模拟器跳过），
设备构建跳过、无 IPA。失败证据 draft 路径成功，显式 tag 修复有效，不是普通成功发布。
第三轮源码 **70ad74b0f5e411ca60f741b1300545d1dbaf25c9** 仅新增行内 **(0.9, 0.5)**
UI 点击修复，已提交／推送；App 代码与第二轮通过时相同。第三轮 **36397742264** 已在
启动前失败、`steps: []`，该轮未执行点击修复验证。

**当前公开运行（2026-09-28 最新检查点）**：源码
**f553cd7285d62171ce1d9ccf0c1f84c8b43e2fb5** 已推送 `personal`；
**36400923391／job 108858329166** 已实际启动、**IN_PROGRESS**，源码检查步骤通过，
正在生成公开地点包，**不是计费启动阻塞**。指定 Node 22 的本地发布器 mock 测试由
父流程实际计数 **94 项全部 PASS**；Node／源码／工程／打包检查本地 PASS。
App **370**／UI **9** 仍为本轮待验证规模，不预记全套测试／回归通过。
预期公开 tag **`ci-36400923391-1` 尚不存在**，不能作为新包下载入口。
**build 12 IPA 未交付、未完成本地校验，现在不能按 build 12 安装**。

历史 0.4.0（build 11，36387878343）为 **COMPLETED / SUCCESS、PASS-NATIVE／PASS-PACKAGE／DELIVERED**：
当时的原生／UI 测试、iPhoneOS 构建、9 项私有 Release 资产验证及 IPA 本地全量复验均完成；
仅四张新增翻译截图已做有限视觉审核。前两轮配额失败、10 个旧云端 IPA 清理及全部本地
备份保留的历史不变；只是交付路线改变，**不声称 Actions 配额已恢复**。
历史 build 11 仍记录 **PENDING-DEVICE**：覆盖安装、系统语言包同意／下载、真机断网翻译、质量和延迟；
既有 20 槽稳定性、内存／发热、照片离线／GPS 覆盖和文件保护边界仍保留。
这些待验证项不是本次升级或正常使用的前置任务。历史章节中的已校验 build 11 IPA
仅是**旧版可选回退包，不是 build 12 新包**。

build 12 实际交付且新包校验完成后，再用原 Sideloadly 账号／有效 Bundle ID 覆盖安装。
已有 build 11／10 当前策略有效索引无需迁移，不卸载、不清库、不重建图像／地点，
不必 Index / resume；语言包已就绪就沿用，正常搜索／看图，不要求指定查询、诊断或截图。
调试仅在需要时从 **Settings 最底部 → Show debug tools** 打开，每次启动默认 **OFF**；
关闭后仍保留既有权重，临时诊断清理范围见页首。不要为本次用户模式更新执行历史迁移、整库诊断或清库测速。
**PENDING-LICENSE-REVIEW**：模型及地点数据再分发仍需人工审查；正式发布另需
App 图标、正式 Bundle ID、签名和 TestFlight 配置。
当前 `com.example.localimageiq` 仅为开发占位标识；未提交到任何商店。

普通免费 Apple 账号可供个人开发测试使用，但描述文件通常 7 天过期；Windows
第三方签名不是 TestFlight，也不等于永久安装或苹果官方 Windows 开发支持。
本次更新不改变此限制或隐私边界：照片、坐标和向量仍在本机处理，不上传图库；
Apple 密码、验证码及证书不交给聊天或 CI，PhotoKit 联网仍由用户显式控制。

文件备份排除可在模拟器测试；iOS 文件数据保护属性必须在真机验证。对应测试在
模拟器明确跳过，但生产代码仍设置 `completeUntilFirstUserAuthentication`。

参考：[GitHub macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
· [Apple membership comparison](https://developer.apple.com/support/compare-memberships/)