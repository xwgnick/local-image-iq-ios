# Windows → iPhone 安装（免费账号）

用户设备：**iPhone 15 / iOS 26.6.1**，只能使用 Windows；已同意使用
**Sideloadly**。这是第三方个人测试安装路线，不是 TestFlight、App Store 或
苹果提供的 Windows 版 Xcode。此前版本已在该手机安装、打开并使用；每个新版本
的界面与实际图库行为仍需在手机上确认。

## 当前：更新到 0.3.0（build 6）— 新包已下载并校验

用户已批准成对替换为 SigLIP 2。源码
`f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78` 的
[CI 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
／job `107062896845` 已 **SUCCESS**，包含 `TEST SUCCEEDED` / `BUILD SUCCEEDED`。
核心 79 通过；App 178 项，177 通过、1 项真机文件保护在模拟器跳过、0 失败；
全部 7 个原生模型 parity 测试通过（72.985 秒），全部 7 个 UI 测试通过。
生产 App 编码 API 测试已断言并通过 23 次预测（17 文本＋6 图像）、58 项测量。
完整导出测量和测试边界见 [构建记录](BUILD_STATUS.md)。

### 本次安装包（不是旧版包）

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
当前源码已改为显式 Pillow 兼容的 22-bit 重采样器，不再用 CoreGraphics medium
插值完成模型缩放；`SigLIPTokenizer.normalizedQuery` 已包含 Unicode Final Sigma
规则。本轮 68×120、112×199 原生输入和精确 Gemma IDs／masks 均已通过，查询、
完整同张量检查和数值门槛未放宽。导出 JSON 的原生 `not-run` 产生于 XCTest 之前，
不是失败；随后通过的 XCTest 才是原生执行证据。

使用上方已校验的新包：

1. 仍用**原 Sideloadly 账号、原有效 Bundle ID 覆盖安装**。不卸载、不手动清索引。
2. **必须打开 Library → Index / resume**，用新模型建一次向量索引，保持联网关闭。
  模型已变，尚未生成新向量时旧模型记录的可用覆盖为 **0** 属于预期，不是需要清库。
  不用下载原图，不用改成“下载并保留原片”。中断后再点同一入口，已完成且仍有效的
  新版本记录会复用。
3. 完成后正常搜索、看图即可；不要求额外测试查询、单照片检查或截图回传。

这次与 0.2.x 只改界面／诊断不同：图像和文本编码器一起换，schema 2、768 维、
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

以下两个升级小节仅保留历史说明，不是本轮无需新索引的依据，也不要求重新执行。

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

1. 本次直接把上方**已下载并校验的 build 6 IPA** 拖进 Sideloadly，无需重下。
  仅其他电脑没有本地包时，才从上方私有 GitHub 产物下载 ZIP、解压外层 ZIP 后取出
  IPA；**不解压或修改 IPA 的 Payload**。
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

## 5. 安装后：建一次新索引，然后正常使用

首次安装时选择你愿意授权的照片；覆盖升级无需为了这次换模型重新选择全部照片。
必须在 **Library → Index / resume** 建立一次新版本索引，联网保持关闭。旧模型记录
不会被新模型搜索，重算前其可用覆盖为 0 是预期。读取的是本地预览，不以原图下载
为前提；中断可续跑，不手动清库。完成后正常使用即可，
不需要额外查询、诊断截图、来源计数回传或性能记录。

搜索提交后键盘会收起；也可用 Done 或拖动收起。离线地理包仍未附带，地点权重
不代表已有地点覆盖，无需为本轮安装改参数。新 FP32 模型的真机耗时、内存和发热
仍未确认；模拟器通过也不能替代这些证据。

## 隐私与模型许可不因换模型而放宽

照片、坐标和向量仍在本机处理，不上传图库；应用不扫描未授权照片。PhotoKit
网络默认关闭，只有用户主动开启后才可按需访问 iCloud；不会要求下载整库原图。
Apple 凭据仍只由用户在本机签名工具／Apple 流程处理，不交给聊天或 CI。

共享 SigLIP 2 模型卡声明 Apache-2.0，导出流程复制实际存在的模型卡／LICENSE／NOTICE
证据，并保留 `redistributionApproved:false` 及人工许可审查。复制许可证、数值测试
通过或个人签名成功，都不是公开分发的法律认证。

## 免费账号的限制

开发描述文件通常 **7 天**失效，需要通过电脑重新签名刷新；这不是永久安装。
通常每台设备最多同时 3 个免费开发应用，App ID 创建也有限制。Sideloadly 提供
自动刷新功能，但是否启用常驻服务／Wi-Fi 刷新由你决定，本项目不会偷偷安装。
TestFlight / App Store 分发仍是另一条需要相应开发者资格的路线。

当前只准备自己的开发测试程序，不越狱、不绕过付费、不使用来历不明的证书。
参考：[Sideloadly FAQ](https://sideloadly.io/faq) ·
[Apple Personal Team 限制](https://developer.apple.com/support/compare-memberships/)。