# Windows → iPhone 安装（免费账号）

用户设备：**iPhone 15 / iOS 26.6.1**，只能使用 Windows；已同意使用
**Sideloadly**。这是第三方个人测试安装路线，不是 TestFlight、App Store 或
苹果提供的 Windows 版 Xcode。此前版本已在该手机安装、打开并使用；每个新版本
的界面与实际图库行为仍需在手机上确认。

## 已装 0.2.0，更新到 0.2.1 检查版

仍用原账号、原有效 Bundle ID 覆盖安装，不卸载、不清索引。这个版本新增
**Check this photo** 按钮；检查结果只显示在手机上，不换模型、不修改索引向量。
操作见 [单照片检查](PHOTO_CHECK.md)。不要把检查误当作重建索引或检索质量修复。

## 已装 0.1.1／0.1.2，更新到 0.2.0

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

1. 从私有 GitHub Actions 的 **iphone-unsigned** 产物下载 ZIP，解压外层 ZIP。
   把里面的 `.ipa` 拖进 Sideloadly；**不解压或修改 IPA 的 Payload**。
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

## 5. 第一次真实图库测试

打开 Local Image IQ 后先授权少量**你自己选择的**照片，再建立索引并用文字搜索。
应用不会自动扫描未授权照片，也不会上传图库。0.1.1 改为先读取本地预览（包括
低清图），不以原图存在为前提。更新时使用原签名身份／Bundle ID 覆盖安装，
不需要删除旧 App 或切换成“下载并保留原片”。最初保持联网开关关闭，运行
Index / resume；新输入策略会重建一次索引，再核对来源计数及剩余需要联网数量。
见 [预览索引修复说明](PREVIEW_INDEXING.md)。

0.1.2 的键盘修复不改变 0.1.1 的索引缓存。提交搜索会收起键盘；也可点击
键盘上方或页面顶部的 Done，或拖动页面收起。不要为了这个 UI 修复清空索引。

当前 FP32 模型较大。记录建索引速度、是否明显发热、是否被系统终止，再评估
量化／压缩；没有承诺真机内存占用或 10 万张图片的性能。离线地理包目前未附带，
地点权重不代表已经有地点覆盖；验证纯图像时可先设为 0。

## 免费账号的限制

开发描述文件通常 **7 天**失效，需要通过电脑重新签名刷新；这不是永久安装。
通常每台设备最多同时 3 个免费开发应用，App ID 创建也有限制。Sideloadly 提供
自动刷新功能，但是否启用常驻服务／Wi-Fi 刷新由你决定，本项目不会偷偷安装。
TestFlight / App Store 分发仍是另一条需要相应开发者资格的路线。

当前只准备自己的开发测试程序，不越狱、不绕过付费、不使用来历不明的证书。
参考：[Sideloadly FAQ](https://sideloadly.io/faq) ·
[Apple Personal Team 限制](https://developer.apple.com/support/compare-memberships/)。