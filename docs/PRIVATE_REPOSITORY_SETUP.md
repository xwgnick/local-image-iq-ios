# 创建私有仓库，然后开始第一次 Mac 编译

## 1. 只创建空的私有仓库

打开 [GitHub 创建仓库](https://github.com/new)：

- Owner：选你有权使用的个人或组织账号。公司相关内容须符合团队代码托管政策。
- Repository name：建议 `local-image-iq-ios`。
- Visibility：**Private**，不要为了免费额度选择 Public。
- 不初始化 README、.gitignore 或 License，本地已经有工程说明和忽略规则。
- 点 Create repository。登录／MFA 由你在浏览器完成。

然后把仓库网页地址发到聊天，例如 `https://github.com/<owner>/local-image-iq-ios`。
地址不是密码；**不要发送 GitHub token、Apple 密码或签名证书**。

本轮只准备本地源码和这些步骤，没有创建仓库、初始化 Git、提交、推送或扣用 Actions 额度。

## 2. 上传边界

后续只以 `local_image_iq_ios` 文件夹本身作为仓库根目录：

- 顶层应是 `App`、`Tests`、`Packages`、`Resources`、`scripts`、`docs`、
  `project.yml`、README 和 `.github`。
- GitHub 必须看到根目录的 `.github/workflows/ios.yml`。
- **不要**把整个 BeatQwen3 工作区初始化、发布为这个仓库。
- 不上传 `photo_search_app`、私人相片、视频、SQLite 索引、模型权重、缓存或密钥。
- GitHub 浏览器直接上传 ZIP 不会自动解包，不能靠 ZIP 文件触发构建。

收到地址后，可以先检查本地将提交的文件清单，再用 Git 正常推送。身份认证需要时
通过 Git Credential Manager 或浏览器完成；不在聊天或脚本中传凭据。

## 3. 第一次手动构建：先不带模型

源码推送后，仓库的 **Actions → Native iOS — manual validation → Run workflow**：

- `include_models`：不勾选。
- `all_compute_units`：不勾选。

这轮验证 Swift 核心、照片访问和界面等代码能否编译，并运行模型无关测试。
缺少模型时 App 会显示资源尚未包含，数值 parity 测试会明确跳过。
**绿色的 model-free 构建不代表图片搜索已经能运行。**

## 4. 第二次：成对模型转换与原生一致性验证

第一轮通过后，手动勾选 `include_models`。它会：

1. 下载固定 revision 的两个公开 Sentence-Transformers 模型。
2. 在 Apple Silicon Mac 转成 Core ML 并比较原始 Python 输出。
3. 在模拟器验证 Swift 分词、图像预处理和模型输出；不会使用你的相片或 GPS。

只有真正需要验证其它计算单元时才再选 `all_compute_units`。
这轮比无模型编译重，查看账号可用 Actions 额度和存储，不保证无限免费。
不要为绕过资源限制把私有内容公开。

## 5. 下载产物的含义

Actions 产物包含 Simulator App ZIP 与 XCTest 的 xcresult；
**不能直接装到 iPhone，也不是 TestFlight 邀请**。

下一阶段才处理正式 Bundle ID、图标、模型再分发许可、真机性能和 Apple 签名。
不需要为了当前模拟器验证先把 Apple 账户或付费开发者信息交给任何脚本。

当前仍未执行任何 Mac/iOS 构建；运行后以实际日志和测试结果为准。