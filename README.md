# Local Image IQ · Native iOS

SwiftUI + PhotoKit + Core ML。独立离线 App，不是桌面网页套壳。

## 当前：0.3.2（build 8）— 4 worker 首轮验证通过，IPA 已完整下载并校验

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
   当时已通过有界内存流式下载完成长度／SHA-256 校验；不是 build 7 或当前 build 8 的包。
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

Windows 无 Swift/Xcode；通过用户提供的私有仓库运行 macOS 构建，并生成未签名
真机 IPA，由用户在 Windows 用 Sideloadly 本地签名。此前版本已由用户安装并在
iPhone 上打开、索引和搜索；这不代表检索质量、内存／发热或新 UI 已完成真机验收。

历史 0.2.0 最终构建通过：79 个核心测试、113 个 App 测试、全部 7 个界面交互测试；
仅 1 项真机文件保护测试在模拟器明确跳过。12 张原生截图已检查，未签名真机
IPA 已下载并校验。这些数值测试与产物属于旧编码器，不能证明本轮 SigLIP 2 通过。
新版实际状态与交付信息见 [构建记录](docs/BUILD_STATUS.md)。

- 照片全部／有限授权、选择更多照片、前台增量索引与取消。
- 0.3.2 沿用 0.3.0／0.3.1 的 Core ML 成对图像／多语言文本编码，768 维、SQLite
   本机缓存；4 个独立图像槽位共享中央文本服务。本版 8 个原生 parity 测试及打包
   验证均通过，含新增四槽真实模型测试；真机速度／内存／发热仍未测定。
- 语义搜索、结果预览与分享；不上传照片或坐标。
- 默认地点权重 0.6，支持 0...1；0.3.1 构建要求四国离线行政区包，回填后地点分支
   实际参与评分。无可用包、无 GPS、包外与不可用分开呈现，不在线反查。
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
0.3.2 的 8 项原生 parity 已在本次 CI 全部通过。
`ImageIQCore` 自身仍是 Foundation-only；
App 的上述依赖是另一个边界。

图像按 EXIF 转正、转 RGB，直接拉伸到 224×224，不保比例、不中心裁剪；参考为
Pillow BILINEAR，均值和标准差均为 `[0.5,0.5,0.5]`。Quartz 仅转换原尺寸 RGB，
缩放使用遵循 Pillow 11.1.0 的 22-bit 分离式双线性实现，原生像素差和向量差
分开验证。FP32 是本轮基线；旧包大小、
桌面 CPU 数据或模拟器结果都不是新版手机内存、耗电、发热与速度的保证。

共享模型卡声明 Apache-2.0；导出流程复制实际存在的模型卡／LICENSE／NOTICE
证据并保留 `redistributionApproved:false`。许可证副本、转换通过和私人构建均不
等于公开分发的法律认证，发布前仍需人工许可审查。

自 0.3.1 起的正常构建路径（含无模型构建）会生成并打包四国公开 WGS84 行政区数据及
来源清单；不是从个人照片推导边界，也不是在线地图／地址服务。每个 Polygon／
MultiPolygon 使用 `label`、`level` 等公开属性。固定来源、历史年份、许可记录和
打包检查见 [地点资源说明](Resources/Places/README.md) 与
[索引与地点说明](docs/INDEX_PIPELINE_PLACES.md)；0.3.1 的模拟器 App、设备 App 及 IPA
资源检查已通过，0.3.2 本次对应检查也通过，设备报告确认同一地点包身份。

## 发布前仍需完成

0.3.2 的 CI、原生测试、模拟器／设备资源检查、iPhoneOS arm64 构建、IPA 完整下载
及字节数／SHA-256 校验均已完成；**本机签名／覆盖安装和物理 iPhone 验证仍未确认**。
云端原生测试和真机 SDK 编译也不能证明 4 worker 提速、实际 GPS 覆盖或内存／发热。
真机文件保护仍需物理设备验证。已验证的新包仍须本机签名；正常升级复用有效索引，
用户选择从零测速才清空索引，不另加诊断任务。正式发布另需 App 图标、正式 Bundle ID、
模型及地点数据再分发许可审查、签名和 TestFlight 配置。
当前 `com.example.localimageiq` 仅为开发占位标识；未提交到任何商店。

普通免费 Apple 账号可供个人开发测试使用，但描述文件通常 7 天过期；Windows
第三方签名不是 TestFlight，也不等于永久安装或苹果官方 Windows 开发支持。
本次更新不改变此限制或隐私边界：照片、坐标和向量仍在本机处理，不上传图库；
Apple 密码、验证码及证书不交给聊天或 CI，PhotoKit 联网仍由用户显式控制。

文件备份排除可在模拟器测试；iOS 文件数据保护属性必须在真机验证。对应测试在
模拟器明确跳过，但生产代码仍设置 `completeUntilFirstUserAuthentication`。

参考：[GitHub macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
· [Apple membership comparison](https://developer.apple.com/support/compare-memberships/)