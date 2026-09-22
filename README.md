# Local Image IQ · Native iOS

SwiftUI + PhotoKit + Core ML。独立离线 App，不是桌面网页套壳。

## 当前进度

这是恢复后的**第一版原生工程**，不是已经签名、可安装到 iPhone 的成品。
Windows 无 Swift/Xcode；现已通过用户提供的私有仓库运行 macOS 构建。
最新**带真实模型**的预览索引修复版已通过：79 个 Swift 核心测试、97 个 iOS App
测试通过，仅 1 项真机文件保护测试明确跳过。两个 Core ML 模型、Swift 分词、
图像预处理及 CPU／自动计算单元推理均已执行数值测试。见
[构建记录与下载](docs/BUILD_STATUS.md)。真机安装、检索质量与性能尚未验证。

- 照片全部／有限授权、选择更多照片、前台增量索引与取消。
- Core ML 成对图像／多语言文本编码，512 维，SQLite 本机缓存。
- 语义搜索、结果预览与分享；不上传照片或坐标。
- 默认地点权重 0.6，支持 0...1；无离线地点包时明确显示无覆盖，不在线反查。
- iCloud 网络访问默认关闭，用户主动开启后才允许 PhotoKit 按需联网。
- 0.1.1 索引改为**本地预览优先**，不再先请求原图；可接收低清预览。
   仅本地无可用图像且用户开启联网时，才请求缺失的图像表示。PhotoKit 控制实际
   下载量，不能保证全部云照片零联网。见 [预览索引修复](docs/PREVIEW_INDEXING.md)。
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

- [project.yml](project.yml)：XcodeGen 规范，iOS 17+，Swift 5 语言模式，Swift 5.9+
   工具链，app + 测试 target。
- [project.models.yml](project.models.yml)：转换完成后的模型测试资源增量配置。
- [App](App)：UI、PhotoKit、Core ML、SQLite、可选离线边界。
- [Packages/ImageIQCore](Packages/ImageIQCore)：无第三方依赖的数学、检索、分词。
- [Resources/Models/README.md](Resources/Models/README.md)：模型导出入口与生成资源。
- [docs/IMPLEMENTATION_CONTRACT.md](docs/IMPLEMENTATION_CONTRACT.md)：固定模型配对与接口。
- [docs/NATIVE_PARITY.md](docs/NATIVE_PARITY.md)：原生数值验收，不能用维度相同替代对齐验证。

保留桌面已用的 cased WordPiece + DistilBERT masked mean + 512D 投影，不能只
导出图像模型然后任意替换文本模型。原生 CGContext 插值与 Pillow 并非已证明
一致：生成测试已单独衡量 preprocessing 与 embedding 误差，合成样本满足当前
验收标准。FP32 是本轮对齐基线，模拟器包约 715 MB，并非手机内存、耗电和速度
已经优化的声明。

目前不附带地理数据。可选 `Places.geojson` 为 WGS84 FeatureCollection，
每个 Polygon/MultiPolygon 的 properties 必须含 `label`、`level`（如 ADM2）。
来源、许可、覆盖范围需要另行验证；不自动从个人照片推导边界。

## 发布前仍需完成

macOS 编译／测试和固定模型转换／原生 parity 已通过。下一步：真机照片权限、
iCloud、耗时／内存／发热验证，以及 App 图标、正式 Bundle ID、模型许可审查、
签名和 TestFlight。
当前 `com.example.localimageiq` 仅为开发占位标识；未提交到任何商店。

普通免费 Apple 账号可供个人开发测试使用，但描述文件通常 7 天过期；Windows
第三方签名不是 TestFlight，也不等于永久安装或苹果官方 Windows 开发支持。

文件备份排除可在模拟器测试；iOS 文件数据保护属性必须在真机验证。对应测试在
模拟器明确跳过，但生产代码仍设置 `completeUntilFirstUserAuthentication`。

参考：[GitHub macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
· [Apple membership comparison](https://developer.apple.com/support/compare-memberships/)