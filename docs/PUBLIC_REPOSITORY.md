# 公开仓库 — 2026-09-28

## 已确认的范围

- 同一仓库 [xwgnick/local-image-iq-ios](https://github.com/xwgnick/local-image-iq-ios)
  已转为 **PUBLIC／`private: false`**，GitHub API 与匿名 GET 已确认；不是新建、迁移或重写历史。
- 用户明确选择公开仓库＋免费标准托管 runner，并再次确认接受既有历史中的作者邮箱、
  机器路径、测试查询，以及历史 Actions 日志和已发布 Releases 公开。
- 既有 [0.4.0 / build 11 Release](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-36387878343-1)
  （**398009938**）现可公开访问，下载不要求 GitHub 登录；**它不是 0.4.1 / build 12**。
  两个旧失败草稿 **398051690／398066345** 未改变；转公开不会自动发布 draft。
- 仅这个独立 iOS 仓库公开；不上传整个父工作区。此次无历史重写、删除、企业 `origin`
  变更或计费／预算／卡片／付费额度调整；以前获批的旧 IPA 清理只是历史事实。

## 检查结果与保密边界

已检查 **277 个历史文本 blob，合计 4,653,437 字节，最大 101,959 字节**。
检查范围内未发现 NUL 二进制、图像／数据库／模型 blob，也未发现 `.env`、私钥、
令牌或带凭据 URL 的相关模式命中。**有限模式扫描不保证没有秘密或其他敏感信息**；
已知邮箱、路径和查询案例由用户确认可公开，不从历史中删除。
此结果针对 Git 历史，不表示已发布 IPA 不含模型。只在本机的 `.git` 辅助脚本未发布。
后续 CI 仍只使用固定公开模型／地点来源及生成测试夹具，不上传私人照片、GPS、数据库或视频。

## 当前 CI／发布约束

- 仅 `workflow_dispatch`，精确仓库名且 `private == false`；只用标准 **`macos-15`**，
  不用付费 larger runner 或 self-hosted runner，不添加 push／PR／fork 特权触发。
- 保持全部源码、核心、地点、模型导出／数值对齐、App、UI、设备编译及包验证门槛。
  全局 `contents: read`，构建 job 可用 `contents: write`／`actions: read` 发布 Release；
  只用运行自带 `GITHUB_TOKEN`，不用 PAT，不接收 Apple 密码、证书或签名材料。
- 发布器在 preflight 和 prepublish 均要求精确目标仓库且明确公开，拒绝私有或错误仓库。
  成功资产仍先放唯一 draft，核验身份／字节／SHA-256 后才发布非 Latest 的 prerelease；
  失败证据保留 draft，不把部分上传当交付，不覆盖或删除既有资产。
  发布文字应说明这是 **public CI**，不能声称已获第三方再分发许可。
- GitHub 对**公开仓库的标准 GitHub-hosted runner 用量免费**，须符合平台使用政策、
  运行限制及可用性；这不是无限资源或必定启动的保证。公开仓库**不重置账号已用的私有
  Actions 分钟、历史累计存储用量或其他账号限制**，也不需要提高付费限额。
  参见 [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)。

## 公开源码，不授予项目级许可证

用户选择**不设置项目级许可证**，未采用 MIT 或 Apache-2.0 作为项目许可。
可见源码不等于获授一般性的复制、修改或再分发权；不能称为已按开源许可证授权的项目。
GitHub 平台条款允许的操作与第三方组件自身的许可须分别看待。

第三方权利不变：SigLIP 2 模型卡声明 Apache-2.0，geoBoundaries 来源／许可元数据与
Pillow 的 MIT-CMU 源码头须保留并分别遵守；这些声明不覆盖整个项目。
`redistributionApproved: false` 保持不变，模型／地点再分发人工审查仍未完成。
仓库、Release 已公开这一事实，或 CI 通过，都不是法律许可审查通过。

## 当前：CI 36403948150 原生构建／测试进行中；暂无已确认的 0.4.1 IPA

工程仍为 **0.4.1 / build 12**。转公开不改引擎、模型、20 worker、HQ224／Fast、
翻译或索引／缓存身份；已有当前策略索引无需因此重建。

**首轮公开历史结果，不是新运行通过记录**：源码 **`f553cd7285d62171ce1d9ccf0c1f84c8b43e2fb5`** 的
[CI 36400923391](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36400923391)
／[job 108858329166](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36400923391/job/108858329166)
已 **COMPLETED / FAILURE，仅 1 项原生 UI 测试失败**。**公开转换已完成，公开路线计费
启动阻塞已解除**；原生 App／UI 实际执行，不是未启动 job，也不表示旧私有用量已重置。

- App **370 项：369 通过、1 项真机文件保护模拟器跳过、0 失败（217.028 秒）**；
  `DebugToolsStateTests` **14**／`DebugToolsPresentationTests` **7** 全通过，已计入总数。
  UI **9 项：8 通过、1 失败（514.171 秒）**，其他 8 项包括全局开关／重启均通过，
  **开关本体点击修复已验证**。
- 唯一失败为 `testClearQueryKeepsKeyboardAndSettingsAdvancedStartsCollapsed` 的
  [滑块可达性断言](../UITests/PresentationNavigationTests.swift#L95)。实际 trace：
  **09:20:21** 点击开关本体 **(0.9, 0.5)** 后值为 **1**；**09:20:25 第一次**点击
  `debug-advanced` 整行中心后滑块始终未暴露，随后 **8 次向下滚动**仍失败。
  **更正此前口头说明：不是第二次展开失败。**
- 新的**仅测试改动**源码 **`cfd2943cbec28bf02c1fe2597921cb12ffdec317`** 已推送 `personal`：
  全部三次展开／收起点击使用显式 ID `debug-advanced` 的尾部箭头 **(0.95, 0.5)**，
  第二次展开前重新获取 header；全部断言保留，未新增跳过或降低门槛。
  当前 [CI 36403948150](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36403948150)
  ／[job 108868075667](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36403948150/job/108868075667)
  的**原生构建／测试 IN PROGRESS，结果待验证**。App 代码与首轮公开源码相同；
  上述 App 370 项／UI 8 通过、1 失败不转记为本轮通过。这是**第三次实际 UI 测试修复迭代**；
  若新测试再失败，**停止并讨论，不无限修补／重跑**。
- 本地 **Node 22 发布器 94 项 PASS** 记录不变，此次仅测试补丁未改发布器，不冒充
  重新执行结果。先前本地检查与原生结果分开记录，不声称新修复已通过。
- 首轮公开失败证据发布步骤 **SUCCESS**：Release **398104580**／tag **`ci-36400923391-1`**
  已存在且为 **DRAFT**，预期 tag、清单、正文 run／target 与实际元数据一致，`draft: true`。
  **6 项资产仅为证据，不含 IPA，不是交付**。UI ZIP 已下载校验，仅查看清单和测试 trace，
  **未查看本轮图片、没有新视觉审核结论**；第二轮私有运行的四图只是旧参考。
  ZIP 身份、长度、SHA-256 与本地路径见 [BUILD_STATUS.md](BUILD_STATUS.md)。

首轮公开原生编译通过并执行 App／UI，**不等于 iPhoneOS 编译通过**；设备构建因 UI
门槛失败 **SKIPPED，无 0.4.1 IPA**。当前预期 tag **`ci-36403948150-1` 尚未发布**，
不是下载入口；工作流只在全部门槛通过后自动发布。尚无已确认的 0.4.1 IPA 或新包下载，
完成公开发布及新包长度／SHA-256 核验后才可报告交付。可下载的仍是 **0.4.0 / build 11 旧包**。
费用设置、无项目级许可证及第三方人工审查边界均不改变。
本次只编辑指定六份文档，不执行命令、Git、CI 查询／触发、Python、测试或下载，不改源码或远端设置。

### 历史阻塞（2026-09-28，转公开前）

旧源码 `70ad74b0f5e411ca60f741b1300545d1dbaf25c9` 的第三轮
[CI 36397742264](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264)
／[job 108848065780](https://github.com/xwgnick/local-image-iq-ios/actions/runs/36397742264/job/108848065780)
因账号付款／支出限额相关 annotation 在启动前失败，`steps: []`；不是存储配额或发布器 bug。
该历史结果保留，不改写为成功，**也不套用到首轮公开 CI 36400923391 或当前 CI 36403948150**。

详见 [BUILD_STATUS.md](BUILD_STATUS.md)、[WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)。