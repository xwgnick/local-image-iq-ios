# Local Image IQ · Native iOS

SwiftUI + PhotoKit + Core ML。独立离线 App，不是桌面网页套壳。

## 当前：0.3.0（build 6）SigLIP 2 — 自动验证通过，IPA 已下载校验

用户已批准把**图像和文本编码器一起**替换为
`google/siglip2-base-patch16-224`，两者固定同一 revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`；不是新图像模型混用旧文本模型。
源码 `f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78` 的
[CI 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
／job `107062896845` 已 **SUCCESS**；日志包含 `TEST SUCCEEDED` 和 `BUILD SUCCEEDED`。

- 30 个 Python 静态测试通过；本轮核心 **79 通过**，App **178 项：177 通过、
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
- [新版未签名 IPA](build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa)
   已通过有界内存流式下载完成长度／SHA-256 校验，不是待下载或旧版包。
   包身份与校验值见 [构建记录](docs/BUILD_STATUS.md)。
- 已取回 17 张原生 UI 截图，**只检查了首页／图库／设置／主结果布局 4 张**的
   [缩小联系图](build/ui-review/35824403795/siglip2-ui-contact.jpg)；都是合成／测试场景，
   没有私人照片，不宣称 17 张均已审核或已完成手机性能验收。

当前 modelVersion：
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。

### 安装已校验的新版 IPA 后，只做这些

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

Windows 无 Swift/Xcode；通过用户提供的私有仓库运行 macOS 构建，并生成未签名
真机 IPA，由用户在 Windows 用 Sideloadly 本地签名。此前版本已由用户安装并在
iPhone 上打开、索引和搜索；这不代表检索质量、内存／发热或新 UI 已完成真机验收。

历史 0.2.0 最终构建通过：79 个核心测试、113 个 App 测试、全部 7 个界面交互测试；
仅 1 项真机文件保护测试在模拟器明确跳过。12 张原生截图已检查，未签名真机
IPA 已下载并校验。这些数值测试与产物属于旧编码器，不能证明本轮 SigLIP 2 通过。
新版实际状态与交付信息见 [构建记录](docs/BUILD_STATUS.md)。

- 照片全部／有限授权、选择更多照片、前台增量索引与取消。
- 0.3.0 的 Core ML 成对图像／多语言文本编码为 768 维，SQLite 本机缓存；
   新版模型已通过上述转换、原生 XCTest 和打包验证，实际手机效果与性能尚未验收。
- 语义搜索、结果预览与分享；不上传照片或坐标。
- 默认地点权重 0.6，支持 0...1；无离线地点包时明确显示无覆盖，不在线反查。
- iCloud 网络访问默认关闭，用户主动开启后才允许 PhotoKit 按需联网。
- 0.1.1 索引改为**本地预览优先**，不再先请求原图；可接收低清预览。
   仅本地无可用图像且用户开启联网时，才请求缺失的图像表示。PhotoKit 控制实际
   下载量，不能保证全部云照片零联网。见 [预览索引修复](docs/PREVIEW_INDEXING.md)。
- 0.1.2 修复搜索后键盘挡住结果：提交自动收起，键盘和导航栏提供 Done 按钮，
   支持拖动收起。已有 0.1.1 索引可复用，不因该键盘修复要求重建。
- 无模型构建只展示真实的资源缺失状态，**不伪造检索结果**；带模型的构建才包含
   经过转换和对齐验证的真实编码器。
- 当前没有 OCR、Agentic Search、Speedbird 生产模型接入或后台无限索引。

## 在 Windows 开发，使用私有仓库的 macOS 构建

只把 **local_image_iq_ios 这个目录的内容** 作为一个私有仓库根目录。
不要上传整个 BeatQwen3：其中有私人照片、演示录像、数据库和桌面缓存。
当前构建仓库为用户提供的私有 `xwgnick/local-image-iq-ios`，已能启动 macOS runner。
原企业托管用户仓库 `wengxie_microsoft/local-image-iq-ios` 保留不动；它的个人
命名空间不支持托管 runner。普通个人账号与企业托管用户的限制不同，代码放置
仍须遵守相应政策。详见 [当前构建状态](docs/BUILD_STATUS.md)。

工作流：[.github/workflows/ios.yml](.github/workflows/ios.yml)，仅手动触发：

还没有仓库时，按 [创建私有仓库步骤](docs/PRIVATE_REPOSITORY_SETUP.md) 操作。

1. 首次 `include_models=false`：Swift 核心测试、XcodeGen 生成工程、模拟器 App
   编译和 XCTest。没有模型的数值对齐测试会明确跳过。优先排除原生编译问题。
2. 随后 `include_models=true`：仅下载固定公开模型，macOS 转换、PyTorch/Core ML
   数值对齐，再运行 Swift tokenizer／预处理／模型推理夹具测试。
3. 构建产物是 **Simulator App ZIP + xcresult**，不是可装到 iPhone 的 IPA。
   真机安装和 TestFlight 仍需要 Apple 签名、对应团队和后续配置。
4. Windows 个人测试路线：勾选 `include_models` 与 `build_device_ipa`，通过测试后
   额外编译 `iphoneos` SDK / arm64 Release App，生成**未签名真机 IPA**。由用户
   在 Windows 用已同意的第三方签名工具安装，不向 CI 提供 Apple 密码或证书。
   详见 [Windows 安装到 iPhone](docs/WINDOWS_IPHONE_INSTALL.md)。

标准 `macos-15` runner 当前为 Apple Silicon；私有仓库消耗账号 Actions 额度，
**不承诺无限免费**，模型转换尤其需要核对额度和存储。没有自动 push/PR 触发。
模型转换环境独立，不修改桌面 Python 环境。

## 工程与模型

- [project.yml](project.yml)：XcodeGen 规范，iOS 17+，Swift 5 语言模式；App 分词依赖
   需要 Swift 6 工具链，当前使用 Xcode 16.4；app + 测试 target。
- [project.models.yml](project.models.yml)：转换完成后的模型测试资源增量配置。
- [App](App)：UI、PhotoKit、Core ML、SQLite、可选离线边界。
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
Unicode 小写（含 Final_Sigma）和全部 17 条文本的 token IDs／masks 已通过本轮
精确原生对齐，不是沿用旧 WordPiece 结果。`ImageIQCore` 自身仍是 Foundation-only；
App 的上述依赖是另一个边界。

图像按 EXIF 转正、转 RGB，直接拉伸到 224×224，不保比例、不中心裁剪；参考为
Pillow BILINEAR，均值和标准差均为 `[0.5,0.5,0.5]`。Quartz 仅转换原尺寸 RGB，
缩放使用遵循 Pillow 11.1.0 的 22-bit 分离式双线性实现，原生像素差和向量差
分开验证。FP32 是本轮基线；旧包大小、
桌面 CPU 数据或模拟器结果都不是新版手机内存、耗电、发热与速度的保证。

共享模型卡声明 Apache-2.0；导出流程复制实际存在的模型卡／LICENSE／NOTICE
证据并保留 `redistributionApproved:false`。许可证副本、转换通过和私人构建均不
等于公开分发的法律认证，发布前仍需人工许可审查。

目前不附带地理数据。可选 `Places.geojson` 为 WGS84 FeatureCollection，
每个 Polygon/MultiPolygon 的 properties 必须含 `label`、`level`（如 ADM2）。
来源、许可、覆盖范围需要另行验证；不自动从个人照片推导边界。

## 发布前仍需完成

0.3.0 的 macOS 编译／测试、FP32 模型转换／原生 parity、iPhoneOS arm64 构建及
IPA 下载校验均已完成。构建使用 Xcode 16.4 / Swift 6 工具链（App 为 Swift 5
语言模式）、iphoneos18.5 SDK，最低 iOS 17.0；未签名包仍须用户本机签名安装。
新版本的真机照片权限、iCloud、耗时／内存／发热尚未验收；模拟器结果不能代替。
本轮安装后仅需建新索引并正常使用，不另加用户诊断任务。正式发布另需 App 图标、正式 Bundle ID、
模型许可审查、签名和 TestFlight 配置。
当前 `com.example.localimageiq` 仅为开发占位标识；未提交到任何商店。

普通免费 Apple 账号可供个人开发测试使用，但描述文件通常 7 天过期；Windows
第三方签名不是 TestFlight，也不等于永久安装或苹果官方 Windows 开发支持。
模型替换不改变此限制或隐私边界：照片、坐标和向量仍在本机处理，不上传图库；
Apple 密码、验证码及证书不交给聊天或 CI，PhotoKit 联网仍由用户显式控制。

文件备份排除可在模拟器测试；iOS 文件数据保护属性必须在真机验证。对应测试在
模拟器明确跳过，但生产代码仍设置 `completeUntilFirstUserAuthentication`。

参考：[GitHub macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
· [Apple membership comparison](https://developer.apple.com/support/compare-memberships/)