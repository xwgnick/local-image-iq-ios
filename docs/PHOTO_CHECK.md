# Photo check — current model boundary and 0.2.1 history

## 当前：0.3.0（build 6）SigLIP 2 — 自动验证通过，新包已校验

用户已批准替换图像和文本两个编码器，不是新增诊断任务。源码
`f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78` 的
[CI 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
／job `107062896845` 已 **SUCCESS**，`TEST SUCCEEDED` / `BUILD SUCCEEDED`。
核心 79 通过；App 178 项：177 通过、1 项真机文件保护在模拟器跳过、0 失败；
全部 7 个 GeneratedModelParityTests 通过（72.985 秒），全部 7 个 UI 测试通过。
生产 App 编码 API 测试已断言并通过 **23 次预测（17 文本＋6 图像）、58 项测量**。
新 IPA 已完成有界内存流式下载及本地长度／SHA-256 校验；安装包身份与导出测量见
[构建记录](BUILD_STATUS.md)，安装用 [Windows 安装说明](WINDOWS_IPHONE_INSTALL.md)。

本轮取回 17 张原生 UI 截图，**仅检查首页／图库／设置／主结果布局 4 张**的
[缩小联系图](../build/ui-review/35824403795/siglip2-ui-contact.jpg)，不是 17 张均已审核。
均为合成／测试场景，没有私人照片，也不是新版检查按钮对真实照片的端到端验收。
下方 0.2.1 的五张诊断页审核属于历史，不能冒充本轮审核范围。

首轮源码 `aee4cdc00be92e1699f68baa9ef7ccc72cbcfbda` 的
[CI 35823153931](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35823153931)
已失败：模型导出通过，但原生图像几何／重采样及 Unicode Final Sigma 检查失败。
当前源码使用显式 Pillow 兼容的 22-bit 重采样器，而非 CoreGraphics medium
插值；`SigLIPTokenizer.normalizedQuery` 已包含 Unicode Final Sigma 规则。
本轮 68×120、112×199 原生低清夹具以及包含 Final_Sigma 的精确 Gemma IDs／masks
均已通过。查询、完整同张量检查和数值门槛未放宽。导出 JSON 的原生 `not-run`
是在 XCTest 之前写入的标记，不是失败；后续 XCTest 已验证原生执行。

当前模型类型为 **SigLIP 2 同源双编码器**：
`google/siglip2-base-patch16-224`，同一 revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`，schema 2、768 维、64 token；
App 使用 `swift-transformers` 1.3.4 和两份原始 tokenizer JSON。
以 [实现契约](IMPLEMENTATION_CONTRACT.md) 为准，不使用旧 WordPiece／CLIP 文本塔。

当前 modelVersion：
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`。
构建使用 Xcode 16.4 / Swift 6 工具链（App 为 Swift 5 语言模式），未签名 FP32 包为
iphoneos18.5 / arm64、最低 iOS 17.0；尚不代表已本机签名或完成新版实机验收。

用原 Sideloadly 账号／有效 Bundle ID 覆盖安装已校验的新包，**不卸载、不手动清索引**；
**必须在 Library → Index / resume 用新模型建一次向量索引，保持联网关闭**。
因为模型变化，重算前旧模型记录的可用覆盖为 **0** 是预期。完成后正常使用即可。
中断后续跑会复用已完成且有效的新版本记录。不必下载原图，也不要求执行
下方旧版诊断流程、再试查询或补截图。

- 旧 512 维记录只为迁移而解码，不能参与新 768 维查询。图像及地点文本向量须按
  新模型版本重算，不能混用；旧 IPA 保留不代表旧索引备份，照片 `id` 主键记录被
  逐条替换后，回退安装包不保证恢复旧向量。
- 检查工具若在正常使用中打开，Saved / Fresh 只能比较**同一当前模型、同一图库
  快照**中的缓存向量与这张图的本次向量。旧 CLIP 与新 SigLIP 2 的分数、余弦及
  诊断数值不能直接跨模型比较；不同图库下的排名也不是受控的模型优劣结论。
  旧版截图不是新模型的基线通过证据，更不是新模型已修复问题的证明。
- `photokit-preview-v1`、本地 fastFormat 路径不变；检查仍强制不联网、只读且不
  写回向量。常规索引网络也默认关闭，只有用户显式允许才可联网。本次不改预览质量，
  不要求原图，不承诺重新请求会更清楚，也不宣称新模型在所有语言和查询上更好。
- 隐私与免费签名限制不变：不上传照片／GPS／索引，凭据不交给聊天或 CI；免费 Apple
  开发描述文件通常仍为 7 天。共享模型卡的 Apache-2.0 声明及复制的许可证据不等于
  公开分发的法律认证，人工许可审查仍需完成。桌面 CPU／模拟器结果不是手机性能。

## 历史：0.2.1（build 5，旧 CLIP 模型）用户操作

以下保留当时的操作和验收记录，**不是本轮要求用户再次执行的步骤**。

1. 用原 Sideloadly 账号、原有效 Bundle ID 覆盖安装；不要卸载或清索引。
2. 搜索 `a hand holding a broken white pen`，点开第一张目标照片。
3. 点 **Check this photo**。把检查页输入框改为 `Dog eat my apple pen`，点 **Check**。
4. 将结果截图发回即可；若一屏放不下，滚动补一张。不需要操作 Advanced。

主屏包含旧/新排名、图库数量、请求/实际像素、PhotoKit 原始低清标志以及向量
余弦。无需理解这些数值即可截图。结果只在本机内存里显示，没有上传、导出日志
或写回新向量。照片 ID、路径与 GPS 不显示。

## 历史：0.2.1 准确含义

- **Saved index**：当前模型/预览策略、仍被授权且未修改的缓存照片组成的图库中，
  目标照片对该查询的完整排名，不截断到 Top 12。
- **Fresh local preview**：只重新读取、编码这一张照片，在同一份图库快照中仅替换
  该图片向量后计算的排名。所有其他图片向量、地点信息、权重和排序逻辑不变。
- 使用现有 `photokit-preview-v1` 的本地优先 fastFormat 预览请求，不请求原图，
  强制 `networkAllowed: false`。本次读取不保证会比上次更清晰，也不是质量修复。
- 像素尺寸是本次 CGImage 原始尺寸；方向单独保留。请求尺寸允许原有比例计算产生
  小数，显示为近似整数。原始 degraded 标志与“尺寸不足”分类分别记录，不混淆。
- **旧缓存没有记录当时的像素尺寸或图像**，本次不能倒推出旧尺寸。向量变化及排名
  改善只是观察，不单独证明旧预览太糊或 Core ML 有误。
- Fresh 指“本次重新请求”，不是绕过 PhotoKit 缓存。点开大图可能已经改变系统
  本地缓存；检查不会重置它。Reduced flag 的 No 仅指本次回调未标为 degraded，
  不保证图片未被缩小、细节完整或与旧索引输入相同。
- 若目标缓存缺失、版本/修改时间过期，不向临时图库插入目标，不伪造可比排名。
- 若本地无法取得预览，保留旧排名并说明新预览不可用；不自动联网。

## 历史：0.2.1 隔离边界

诊断复用 AppState 已有任务链，取消后等待旧任务退出；不会清空当前结果和选中照片。
关闭检查页、修改检查文字、退到后台或图库授权变化后不发布迟到结果。

SQLite 使用专用 `SQLITE_OPEN_READONLY` 连接，通过一次 SELECT 获得缓存快照，
读取后关闭连接。缺失数据库不创建目录/文件；不调用 reconcile/save/clear，不修改
数据库设置或执行迁移。在内存中过滤失效授权/修订，并在异步边界检查图库是否变化。
正常索引的可写连接与版本、模型、打分、联网默认值保持不变。

## 历史：0.2.1 验证

新增 18 个 worker/storage 测试及 20 个状态/渲染测试（其中 5 个原生截图）。
全部使用临时数据库、生成像素、测试替身；不上传私人照片。包括数据库字节及 SHA-256
不变、无 sidecar/新文件、只替换目标、完整排名、地点中心与并列顺序、离线请求、
失败/取消/授权变化、任务串行等待、旧界面状态保留。

云端 [run 35817552815](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35817552815)
一次通过：79 个核心测试、151 个 App 测试、7 个现有导航/键盘 UI 测试通过，
1 项真机文件保护测试跳过。新增 38 个测试全部执行成功。

5 张检查页/按钮原生截图已通过小型 contact sheet 审核；均为测试生成数据。
这些渲染与状态测试不等同于“对真实照片点按钮”的端到端验证。
新 iPhoneOS/arm64 Release IPA 已下载并通过长度/SHA-256 校验；见
[构建记录](BUILD_STATUS.md)。旧安装包保留。

真实照片上的新旧排名与 PhotoKit 实际尺寸，仍由用户安装后测试确认。