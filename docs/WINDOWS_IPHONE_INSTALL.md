# Windows → iPhone 安装（免费账号）

用户设备：**iPhone 15 / iOS 26.6.1**，只能使用 Windows；已同意使用
**Sideloadly**。这是第三方个人测试安装路线，不是 TestFlight、App Store 或
苹果提供的 Windows 版 Xcode。此前版本已在该手机安装、打开并使用；每个新版本
的界面与实际图库行为仍需在手机上确认。

## 当前：0.3.2（build 8）— 4 worker 首轮验证通过，新包已完整下载并校验

源码：`b40d2faaf11b2f499779881b4863325fa7dae659`。
[CI 35848409845](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845)
／[job 107140049230](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/job/107140049230)
已 **SUCCESS，首轮通过**；App 版本已核验为 **0.3.2 / build 8**。
核心、模型导出、地点包、模型／App 资源检查、原生与 UI 测试及设备打包均通过；
新 IPA 已实际完整下载并校验本地字节数／SHA-256，不是下方旧 build 7 的包。
本次只记录已核验结果，不运行命令、测试、CI 查询／重试或下载，不签名或操作手机。

### 本版改变了什么

- 用户明确要求 **4 worker**：固定 4 槽滚动窗口，子任务各自完成 PhotoKit 取预览、
  预处理和图像推理，使用独立图像模型 actor。**进行中＋完成待提交合计最多 4 张**，
  完成但等待前序提交也占槽位；不再提交第 5 张未提交项，不无限积累预览／结果。
  每顺序提交一张就能补位，不是每 4 张一起等完的批次屏障。
- 复用一份常驻主图像模型，另 3 份仅图像模型在本次索引中按需懒加载、全部子任务
  结束后释放作用域持有。中央仍只有 **1 份文本模型＋1 份 tokenizer**，不是 4 份
  文本模型或四套图文模型。明确增加的是 **3 份图像模型及并发中间张量的内存代价**；
  不声称系统立即归还全部内存，更不保证 4 倍提速、手机耗时／内存／发热。
- 地点文本去重、写库和进度由父任务按快照顺序处理，成功保存后才发布计数。
  取消／错误退出会取消并等待全部最多 4 个子任务结束；同步预测可能要等返回，
  迟到 PhotoKit 回调仍由 gate 忽略。有效缓存命中不取预览、不做图像推理，纯缓存
  扫描不加载额外 3 份图像模型。没有新增任务超时、自动重试或图库数量／字节限制。
- 同一 SigLIP 2 权重／版本、FP32、预处理、`photokit-preview-v1`、2,943 要素
  四国地点包、评分及默认地点权重 **0.6** 均不变，联网仍默认关闭，不要求下载原图。
  build 8 本次资源检查已通过，设备报告确认同一模型及地点包身份。

### 本次实际验证

- Swift 核心 **79 通过**；App **221 项：220 通过、1 项真机文件保护在模拟器
  跳过、0 失败**。IndexPipeline **19 项全部通过**，含新增 4 项；新增默认工厂
  边界测试通过。原生子套件均已计入 App 总数，不重复相加。
- GeneratedModelParity **8 项全部通过（101.581 秒）**，含新增真实四图像 actor
  测试：6 夹具 × 4 槽＝**24 次预测、48 项归一化向量比较＋12 项张量测量＝60 项**。
  计数及图像余弦 **≥ 0.995** 门槛已断言通过；旧 **23 次／58 项**也通过，门槛未改。
- UI **7 项全部通过（209.329 秒）**；模型报告 `parityPassed:true`。未返回本次
  原始精确极值，不把旧版余弦／误差极值当成本次测量。

### 已完整下载并验证的 build 8 安装包

- [build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa)
  **实际完整流式下载已完成，本地字节数及 SHA-256 已验证**；校验文件与设备构建
  JSON 均已存在，无残留部分下载文件，无需重新下载。仍须 Sideloadly 本机签名。
- [GitHub 产物 10745235946](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/artifacts/10745235946)：
  外层 **1,414,636,737 字节**，内层 IPA **1,414,629,419 字节**。
- IPA SHA-256：`7d37581966a45028213a52a0a9c504e2ed273293a92bbbad4ab9d77a0d73ef8e`。
- 本次设备报告确认 **0.3.2 / build 8**，modelVersion 仍为
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`；
  **2,943 要素**地点包 GeoJSON SHA-256 仍为
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`。
  完整地点包身份见 [构建记录](BUILD_STATUS.md)。未签名包不等于已在物理 iPhone 执行。
- 已取回 **20 张**原生截图，**仅审核 3 张索引／地点界面**的
  [960×680 联系图](../build/ui-review/35848409845/four-workers-ui-contact.jpg)：
  Library 回填后、Library 零 GPS、Settings 尚未检查地点。折叠项未展开，未检查
  内部全部计数，其余 17 张不计入审核；合成界面不是用户 GPS 或四 worker 真机证据。

`PENDING-DEVICE`：签名／覆盖安装及物理手机表现尚无结果；没有实际速度／内存测试。
`PENDING-LICENSE-REVIEW`：模型及地点再分发许可仍需人工审核，不追加手机诊断任务。

### 使用已验证新包：正常升级复用缓存；从零测速是可选分支

1. 用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装 build 8**，不卸载 App，
   不为升级清空索引／缓存。
2. 正常使用 **Library → Index / resume**：有效 0.3.0／0.3.1 图像向量继续复用，
   地点照常检查／按需回填，新增或变化照片才图像编码。前台运行、联网关闭，中断可
   续跑。**升级不要求清空索引，也不要求整库图像重编码或下载原图。**
3. 用户明确希望从零测速时，可在**安装后主动选择 Settings → Clear index，再打开
  Library → Index / resume**，联网关闭、保持 App 前台。这会丢失已有索引／缓存，
  需要重新索引，**不会删除系统相册的照片**。这是可选测速，不是覆盖安装前提；
  本次文档编辑不会替用户清空或运行手机。

冷建测速比较 **0.3.1 与 0.3.2（同一地点包）**，两边都从空索引开始；保持同一手机、
同一批授权照片及数量、联网关闭、相近温度／发热和供电条件。不要拿旧版从零建库与
新版缓存续跑比较，也不要把 4 worker 写成 4 倍提速。除此以外，不要求额外诊断查询、
截图、索引抢救或数据回传。新包身份及已核验结果见 [构建记录](BUILD_STATUS.md)。

## 历史：0.3.1（build 7）— 首轮验证通过，旧包已完整下载并校验

以下是旧版 build 7 的测试、安装包和当时操作说明，不是 build 8 的交付或验证结果。

源码：`18ad52d37690ecfbf92b63a21285a6c3e8e753d4`。
[CI 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
／[job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763)
已 **SUCCESS，首轮通过，无需修复重跑**，包含 `TEST SUCCEEDED` / `BUILD SUCCEEDED`。
源码／静态 30 通过，核心 79 通过；App **215 项：214 通过、1 项真机文件保护在
模拟器跳过、0 失败**。全部 **7 个模型 parity 通过（67.736 秒）**，全部 **7 个 UI
测试通过（202.143 秒）**。公开地点生成校验、模拟器／设备 App 资源检查、iPhoneOS
arm64 Release 编译及 IPA 验证均已通过。完整测试明细和本次模型报告见
[构建记录](BUILD_STATUS.md)。本次仅记录已核验结果，不运行命令、测试、下载或查询 CI。

### 历史 build 7 安装包（不是当前 build 8）

- [build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa)
  **已实际完整下载**；有界内存流式长度／SHA-256 校验完成，下载后本地报告已写入并
  检查，无需重新下载。不要用下方历史 build 6 的包代替。
- [GitHub 产物 10741731376](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741731376)：
  外层 **1,414,628,123 字节**，内层 IPA **1,414,620,805 字节**。
- IPA SHA-256：`98fb537004a64adaa84b1ba15d798acaf71a0684555275faddc647d1adafd8d6`。
- 实际设备报告确认 **0.3.1 / build 7、iphoneos18.5 / arm64 Release、Xcode 16.4、
  最低 iOS 17.0、FP32、未签名**。仍需 Sideloadly 本机签名，不能直接安装；
  **用户安装后的物理 iPhone 行为尚未验证**。
- 20 张原生截图已取回，但只审核 3 张新增地点界面的
  [960×680 联系图](../build/ui-review/35840838147/index-places-contact.jpg)：
  Library 回填后、Library 零 GPS、Settings 尚未检查地点。可见内容可读；折叠项未
  展开，未视觉检查内部全部计数。数字为合成测试数据，不是用户 GPS 结果。

### 当时的 build 7 操作：覆盖安装＋一次地点回填

1. 用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**。不卸载、不清索引。
2. 打开 **Library → Index / resume** 跑一遍地点回填，保持 App 在前台、联网关闭。
  **仍有效的 0.3.0 图像向量直接复用，不取预览、不整库图像重编码**；新增或变化照片
  才按正常流程编码。中断后继续同一入口，不要求下载原图或“下载并保留原片”。
3. 完成后正常搜索、看图，不另加测试查询、诊断截图或性能数据回传任务。

这次没有再次换模型：图像和文本仍为同一 SigLIP 2 配对，`modelVersion`、FP32、
预处理及 `photokit-preview-v1` 与 0.3.0 相同。若仍保留 0.2.x 的 CLIP 旧索引，
才需要下方历史模型迁移；不能混用 CLIP 向量，也不能因此让已有 0.3.0 向量全部重算。

新增的是下一张缓存／PhotoKit 预览预取与当前张父任务处理重叠，仍单模型对、串行
推理、单一路径顺序保存；取消时取消并等待子任务，迟到 PhotoKit 回调被忽略。
没有新增任意数量／时间上限、多个推理 worker、联网默认变化或手机提速保证。

地点包覆盖中国、法国、德国、荷兰历史 ADM1／ADM2，代表年份 2017–2022；**实际设备包
检查**确认 **2,943 个要素、15,175,079 字节、CHN／FRA／DEU／NLD、8 个来源**，GeoJSON SHA-256
`41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`。
清单 SHA-256：`0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`。
这不是仅凭本地源码清单的声明，也不代表全球覆盖、街道地址或 POI。
Library 区分扫描时有 GPS／找到标签／无 GPS／无可用包／包外／不可用，未检查即未知；
扫描计数不是永久 GPS 总数，已保存标签数也不等于有 GPS 的照片数。
不新增当前手机位置权限或在线反查，原始坐标不保存、不上传。
默认地点权重 **0.6** 保持不变，但回填后地点分支开始实际参与评分，排名可能有意变化，
无需为掩盖变化改权重；不承诺私人图库地点覆盖数字。详见
[索引与地点说明](INDEX_PIPELINE_PLACES.md)。

## 历史：更新到 0.3.0（build 6）— 当时的新包已下载并校验

本节结果、下载链接和迁移步骤仅属历史 CLIP → SigLIP 2 升级，不是 build 7／8 交付证据。

用户已批准成对替换为 SigLIP 2。源码
`f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78` 的
[CI 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
／job `107062896845` 已 **SUCCESS**，包含 `TEST SUCCEEDED` / `BUILD SUCCEEDED`。
核心 79 通过；App 178 项，177 通过、1 项真机文件保护在模拟器跳过、0 失败；
全部 7 个原生模型 parity 测试通过（72.985 秒），全部 7 个 UI 测试通过。
生产 App 编码 API 测试已断言并通过 23 次预测（17 文本＋6 图像）、58 项测量。
完整导出测量和测试边界见 [构建记录](BUILD_STATUS.md)。

### 历史 build 6 安装包（不是当前 build 8）

- 本地已完整下载并校验的
  [build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa)。
  使用有界内存流式下载，**实际长度及 SHA-256 已验证完成**，无需重新下载。
- [GitHub 产物 10734323054](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795/artifacts/10734323054)：
  外层产物 **1,408,905,095 字节**，内层 IPA **1,408,903,848 字节**。
- IPA SHA-256：`529b8ae5f708f57d14929fccf4a374dfb943d0e950b7671239e99f69b5acd98e`。
- **未签名、FP32、iphoneos18.5 / arm64、最低 iOS 17.0**；使用 Xcode 16.4 /
  Swift 6 工具链（App 为 Swift 5 语言模式）。仍需 Sideloadly 本机签名，不能直接安装。
- 已取回 17 张原生截图，**仅审核首页／图库／设置／主结果布局 4 张**的
  [缩小联系图](../build/ui-review/35824403795/siglip2-ui-contact.jpg)。
  均为合成／测试场景，没有私人照片；不代表 17 张均已审核或手机性能已验收。

首轮源码 `aee4cdc00be92e1699f68baa9ef7ccc72cbcfbda` 的
[CI 35823153931](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35823153931)
已失败：模型导出通过，但原生图像几何／重采样及 Unicode Final Sigma 检查失败。
当时修正后的源码改为显式 Pillow 兼容的 22-bit 重采样器，不再用 CoreGraphics medium
插值完成模型缩放；`SigLIPTokenizer.normalizedQuery` 已包含 Unicode Final Sigma
规则。build 6 的 68×120、112×199 原生输入和精确 Gemma IDs／masks 均已通过，查询、
完整同张量检查和数值门槛未放宽。导出 JSON 的原生 `not-run` 产生于 XCTest 之前，
不是失败；随后通过的 XCTest 才是原生执行证据。

当时从 0.2.x 升级，使用上方已校验的 build 6 包：

1. 仍用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**。不卸载、不手动清索引。
2. **必须打开 Library → Index / resume**，用新模型建一次向量索引，保持联网关闭。
  模型已变，尚未生成新向量时旧模型记录的可用覆盖为 **0** 属于预期，不是需要清库。
  不用下载原图，不用改成“下载并保留原片”。中断后再点同一入口，已完成且仍有效的
  新版本记录会复用。
3. 完成后正常搜索、看图即可；不要求额外测试查询、单照片检查或截图回传。

0.3.0 与此前只改界面／诊断不同：图像和文本编码器一起换，schema 2、768 维、
64 token，来源固定为同一 `google/siglip2-base-patch16-224` revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`。App 用 `swift-transformers` 1.3.4
读取该模型的两份本地 tokenizer JSON。旧 CLIP 512 维行仅可解码用于迁移，不能
参与 SigLIP 2 搜索；图像及地点文本向量都需重算，不能混用。详见
[实现契约](IMPLEMENTATION_CONTRACT.md)。

本包 modelVersion：
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。

旧 IPA 保留，但照片记录按 `id` 主键被新向量逐条替换，**旧安装包不是旧索引备份**。
回退包不保证恢复已替换的旧记录；不要用卸载或清库来处理这次升级。

`photokit-preview-v1` 不变：本地预览优先、可接受低清图、联网默认关闭，用户显式
开启才可按需联网。不要求原图，也不承诺每张云照片都可离线读取；本次不是预览质量
修复。模型不保证所有语言、查询都更好，桌面 CPU 数字也不是 iPhone 性能。

以下两个升级小节也仅保留历史说明，不要求重新执行；当前 0.3.0／0.3.1 → 0.3.2
正常复用图像缓存、可选从零测速的区别见页首，不适用历史 CLIP 整体换模型步骤。

## 历史：已装 0.2.0，更新到 0.2.1 检查版

仍用原账号、原有效 Bundle ID 覆盖安装，不卸载、不清索引。这个版本新增
**Check this photo** 按钮；检查结果只显示在手机上，不换模型、不修改索引向量。
操作见 [单照片检查](PHOTO_CHECK.md)。不要把检查误当作重建索引或检索质量修复。

## 历史：已装 0.1.1／0.1.2，更新到 0.2.0

直接把新版未签名 IPA 拖进 Sideloadly，用**原账号、原有效 Bundle ID 覆盖安装**。
不要卸载 App，不要清空或重建已有索引。此版仅重做界面和权限提示时机，不改
模型、排序、预览输入策略或联网默认值；检索质量问题仍待单独处理。

安装后检查：首页搜索；结果大图／紧凑网格切换；点图后翻页、缩放、关闭与分享；
搜索后键盘收起；Library／Settings 能正常打开、关闭。索引、授权和 iCloud 开关
现在放在 Library；结果数量在 Settings，权重和分数在 Advanced。

## 先区分两种构建

- `LocalImageIQ-Simulator.zip`：模拟器程序，**不能用于 iPhone 安装**。
- `LocalImageIQ-iphoneos-unsigned.ipa`：使用 `iphoneos` SDK 为 arm64 编译的
  真机程序，内含 `Payload/LocalImageIQ.app` 和两个已编译 Core ML 模型。
  它是**未签名**包，不能直接点击安装，必须由本机工具签名。
- `device-build.json` 记录实际 SDK、最低 iOS、架构、模型版本、大小及 SHA-256；
  `SHA256SUMS.txt` 用于校验下载。不把模拟器 arm64 当成真机 arm64：构建同时
  验证 Info.plist 的 iPhoneOS 平台和 Mach-O 的 IOS 平台标记。

设备运行比构建 SDK 更新的 iOS，不代表应用一定不能运行；最终仍需测试实际
安装、系统授权、内存和推理行为，不声称云端模拟器替代了 iOS 26.6.1 真机验证。

## 1. 安装工具（由你操作）

从 [Sideloadly 官方网站](https://sideloadly.io/) 下载 Windows 64-bit 版本，
不要从镜像站、网盘或所谓“免签平台”获取。安装器的 UAC／管理员确认由你处理。
若这是受管理的工作电脑，先确认允许安装第三方签名工具和 Apple 设备驱动。

工具若提示缺少 Apple Mobile Device / iTunes / iCloud 组件，按其当前官方
安装提示补齐。**不要未经确认卸载你已有的 iTunes、Apple Devices 或 iCloud**；
不同分发版本的驱动兼容性按工具实际提示排查。

Sideloadly 自己的 [隐私声明](https://sideloadly.io/privacy) 声称 Apple 凭据只发送
给 Apple；这只是开发者声明，不是本项目对工具的安全审计。首次使用需要接受
这个第三方工具的信任边界；不向任何聊天、GitHub Secrets 或本项目脚本提供密码。

## 2. USB 连接手机

1. 用支持数据传输的 USB-C 线连接 iPhone 和这台 Windows，解锁手机。
2. 在手机弹窗选择“信任此电脑”，手机密码仅在手机上输入。
3. 等 Sideloadly 中的设备列表显示你的 iPhone。没有识别时先排查驱动／线缆，
   不反复提交 Apple 登录。

## 3. 签名安装

1. 将已完整下载并校验的
  [0.3.2 / build 8 IPA](../build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa)
  拖进 Sideloadly；无需重新下载。其他电脑没有本地包时，可使用页首已核验的
  产物 **10745235946**，解压外层 ZIP 后取出 IPA；**不解压或修改 IPA 的 Payload**。
2. 选择已连接的 iPhone，输入你本人有权使用的 Apple Account。
3. 点击 Start；密码及双重认证仅由你在工具／Apple 登录流程中手动输入。
   如工具明确要求普通密码或 App 专用密码，以当前官方说明为准，不互相替代试错。
4. 不启用 dylib 注入、插件或其它改包功能。首次签名可能需要调整开发用 Bundle ID；
   保持之后重签所用账号／标识一致，不随意删除旧 App 以免丢失其本地索引。

## 4. 手机上完成信任

- 如提示“未受信任的开发者”，在“设置 → 通用 → VPN 与设备管理”找到自己的
  开发者身份并信任，只信任你刚使用的账号，不安装陌生企业描述文件。
- iOS 16+ 开发测试通常需要“设置 → 隐私与安全性 → 开发者模式”，开启后按系统
  要求重启和确认。菜单暂时不出现时，先完成一次配对／开发签名安装再检查。
- 若遇到账户或设备管理政策禁止开发者模式，停止并确认政策，不绕过设备管理。

## 5. build 8 安装后：正常续跑；从零测速可选

首次安装时选择你愿意授权的照片并正常建立索引；从 0.3.0／0.3.1 覆盖升级无需重新
选择全部照片，更无需清库。打开 **Library → Index / resume**，联网关闭、App 前台。
有效缓存仍可用，不会因为 4 worker 更新而全部失效；缓存命中也检查地点但不取预览／
图像重编码，新增／变化照片正常编码，中断可续跑。不要求原图下载。

只有用户选择页首的**从零测速**时，才在安装后打开 **Settings → Clear index**，
再打开 **Library → Index / resume**，联网关闭、保持前台。索引／缓存会丢失，
系统照片不删除，之后重新索引。对比旧 0.3.1 与新 0.3.2 的同地点包、同照片数量、
同网络关闭和相近温度／发热／供电条件，不能与缓存续跑混比。正常升级不必执行这一步。
没有代跑手机或实际速度／内存测量，也没有索引抢救、额外查询、诊断截图或来源计数回传要求。

搜索提交后键盘会收起；也可用 Done 或拖动收起。四国离线行政区包身份不变，0.3.2
本次资源检查已通过，设备报告确认同一包。有 GPS 不保证落在包内或成功保存地点标签。
默认权重仍为 0.6，回填后有地点输入的评分分支生效，排名变化是预期，不静默调参抵消。
四 worker 真机耗时／内存／发热、文件保护及真实 GPS 覆盖尚未测定；云端测试和
iPhoneOS 编译不能替代，不声称 4 倍提速或物理设备性能已验收。

## 隐私与模型许可不因本次更新而放宽

照片、坐标和向量仍在本机处理，不上传图库；应用不扫描未授权照片。PhotoKit
网络默认关闭，只有用户主动开启后才可按需访问 iCloud；不会要求下载整库原图。
Apple 凭据仍只由用户在本机签名工具／Apple 流程处理，不交给聊天或 CI。

共享 SigLIP 2 模型卡声明 Apache-2.0，导出流程复制实际存在的模型卡／LICENSE／NOTICE
证据，并保留 `redistributionApproved:false` 及人工许可审查。复制许可证、数值测试
通过或个人签名成功，都不是公开分发的法律认证。地点包的来源／年份／许可记录已随包
保存，同样不能代替再分发许可审查。正式发布还需 App 图标、正式 Bundle ID、
签名及 TestFlight／商店配置；当前未提交商店。

## 免费账号的限制

开发描述文件通常 **7 天**失效，需要通过电脑重新签名刷新；这不是永久安装。
通常每台设备最多同时 3 个免费开发应用，App ID 创建也有限制。Sideloadly 提供
自动刷新功能，但是否启用常驻服务／Wi-Fi 刷新由你决定，本项目不会偷偷安装。
TestFlight / App Store 分发仍是另一条需要相应开发者资格的路线。

当前只准备自己的开发测试程序，不越狱、不绕过付费、不使用来历不明的证书。
参考：[Sideloadly FAQ](https://sideloadly.io/faq) ·
[Apple Personal Team 限制](https://developer.apple.com/support/compare-memberships/)。