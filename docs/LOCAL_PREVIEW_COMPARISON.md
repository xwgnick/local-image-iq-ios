# 本地预览三路对比 · 0.3.3（build 9）

用户已批准的单照片诊断，不是预览质量修复。源码：
`9e055b13be62ca184593387b1b5dc647b3a85a26`；
[CI 35965638523](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523)
／[job 107523495276](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35965638523/job/107523495276)
已 **SUCCESS，首轮通过**，日志确认 `TEST SUCCEEDED` 和设备 `BUILD SUCCEEDED`。

[../build/device-download/35965638523/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35965638523/LocalImageIQ-iphoneos-unsigned.ipa)
**已实际完整下载**：有界流式读取核验实际长度／SHA-256 后才最终重命名；
IPA **1,414,731,479 字节**，SHA-256：
`5c36d87fa1b5845a6806274a200ad602a917b778da5398b49116b2e9b303328b`。
同目录设备报告与校验文件齐全，无部分下载残留，旧包保留。
设备报告确认 **0.3.3 / build 9、arm64 Release、未签名**；仍须 Sideloadly 本机签名，
不是已在手机安装。旧 build 8 包没有此入口。

## 手机上怎么做

1. 用原 Sideloadly 账号、原有效 Bundle ID 覆盖安装，完成必要的系统信任。
   不卸载、不清索引，也不需要重建或跑一次索引。
2. 打开 App 前，先开飞行模式，并在系统设置中关闭 Wi-Fi。App 不检测飞行模式，
   页面的“网络访问关闭”只说明三路请求禁止联网，不代表已验证手机离线。
3. 打开 App，搜索 `a hand holding a broken white pen`，选择此前已经找到的
   手持破损白笔照片；也可选一张当前能访问的搜索结果。它只是人工选图示例，
   App 没有硬编码这张照片或搜索词，不要求它现在仍排第一。
4. 点开照片，点底部“本地预览对比”。进入页面自动依次跑三次请求，无需再点开始。
  等待结束，先发默认三路“等框对比”截图，尽量包含三路图像和像素／标记；不可用也照实截图。
5. 可选：切换“同一区域细节”，轻点下方参考图选择笔尖、文字等区域，再发一张截图。
   三路同步选择相同比例位置；放大滑杆仅用于显示，不增加真实细节。

不要为了准备测试，先联网在系统“照片”或 App 中打开目标图：这可能预热缓存。
即使先断网，打开 App、搜索结果／大图加载及前一路请求也可能影响随后请求；不是冷缓存实验，
不要求清系统缓存。返回尺寸更大、“High quality”或降质标记为“否”，都不等于更清晰。

## 请求与显示契约

- [PhotoLibraryClient](../App/Photos/PhotoLibraryClient.swift) 捕获同一个 `PHAsset`、
  照片 revision 与授权状态；[独立加载器](../App/Photos/LocalPreviewComparison.swift)
  顺序请求 Fast 224 → High quality 224 → High quality 480，不是并发、自动择优或重试。
  224／480 是保留照片元数据宽高比的请求短边，不是固定正方形，也不保证返回这么多像素。
- 三路均使用 `requestImage`、`.current`、`.aspectFit`、`resizeMode = .fast`、异步请求，
  `isNetworkAccessAllowed = false`；只有 delivery mode／请求尺寸不同。
  不调用原图数据接口、不按 App 联网开关回退下载；不读写 App 缩略图缓存，
  但不绕过 PhotoKit／系统缓存，前一次请求可能影响后一次。
- 每路取首次回调，包括降质图，不等待后续更清晰回调；有可用像素时优先保留，普通错误
  不覆盖它。无可用像素则记为该路不可用并继续；取消、权限失败或照片／授权快照变化
  终止整次对比，不发布半份报告。
- 保留返回的 `CGImage` 像素及方向；仅有可用 `CIImage` 时按其实际范围转为 CG 图像。
  不先放大、裁剪、烘焙方向或重新编码来伪装返回尺寸。页面显示请求尺寸、方向校正前的
  实际 CG 像素、方向、原始降质标记（是／否／未知）及来源；来源分类不是清晰度评级。
- [对比页面](../App/UI/LocalPreviewComparisonSheet.swift) 默认等大方框填充裁剪；
  “完整画面”保留整图，“同一区域细节”按转正后的相同归一化区域显示。
  参考图仅取返回像素最多者，不认定它最清晰；返回比例不同时会提示内容未必完全对齐。
- [页面状态](../App/State/LocalPreviewComparisonState.swift) 仅持有内存结果；取消、关闭或
  进入非活动状态会清空，回前台不自动重跑。重新对比先等前次取消任务结束，拒绝迟到结果，
  发布前复核照片与授权快照；不显示原始错误里的私有路径／标识。

对比链路不调用索引 worker、编码器或 SQLite，不改向量／排名，不保存或导出图片。
SigLIP 2 模型、四 worker 索引、Places、评分、`photokit-preview-v1`、正常看图策略及
默认联网关闭均保持不变；新增诊断不意味着普通列表／大图已变清晰。

## 已通过的测试

- Swift 核心 **79 通过**；App **258 项：257 通过、1 项真机文件保护在模拟器跳过、
  0 失败（96.471 秒）**。以下三个子套件均已计入 App 总数，不重复相加。
- [../Tests/LocalPreviewComparisonTests.swift](../Tests/LocalPreviewComparisonTests.swift)：
  **18 项全部通过（0.060 秒）**；
  [../Tests/LocalPreviewComparisonPresentationTests.swift](../Tests/LocalPreviewComparisonPresentationTests.swift)：
  **19 项全部通过（1.248 秒）**。自动启动另有测试覆盖，不额外截图。
- `GeneratedModelParityTests` **8 项全部通过（71.345 秒）**，包含真实四图像模型 actor：
  6 夹具 × 4 槽＝**24 次预测／60 项测量**；原 **23 次预测／58 项测量**也通过，门槛未改。
  UI **7 项全部通过（198.491 秒）**。测试耗时不是物理手机速度／发热证据。

## 已审核的截图及边界

24 张 UIReview 截图已下载，**仅审核 4 张新增预览图**，其余 20 张未审核。
前三张各 393×852，大字号图 375×667；审核使用 **1340×758** 联系图：
[../build/ui-review/35965638523/local-preview-contact.jpg](../build/ui-review/35965638523/local-preview-contact.jpg)。

- 三种合成尺寸：三列尺寸／元数据和等大面板清楚可见。
- 全部不可用：不可用状态清楚可见。
- 同一区域细节：三路面板的共同区域可见。
- 大字号：当前视口仅见菜单及第一个大面板；屏外元数据／其余面板**未做视觉审核**。

这些截图来自注入的假服务与程序生成像素，不请求真实 Photos 权限、不读取私人照片。
**未实际点击或滚动验证**；原生渲染和 UI 测试通过不是这些场景的真机交互、清晰度或
真实离线覆盖证明，也不保证更大预览更清晰。

**PENDING-DEVICE**：本机签名／覆盖安装、真实 PhotoKit 离线结果、文件保护、速度／
内存／发热仍待手机验证。高质量请求能否离线取得不同或更有细节的表示，必须看真机结果；
三路都小或不可用，也不能据此断言系统从未有过其他本地表示。
**PENDING-LICENSE-REVIEW**：模型及地点数据再分发仍需人工审查。

安装通则见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)，状态见
[BUILD_STATUS.md](BUILD_STATUS.md)。