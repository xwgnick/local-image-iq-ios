# 相似清理系统路径兼容修复 — 0.11.2 / build 32

## build32：首次且唯一一次完整 CI SUCCESS，已交付；手机效果待确认

**DELIVERED／PASS-NATIVE／PASS-PACKAGE／PENDING-DEVICE。**build32此前仅文档交付记录未补齐，并非代码／构建仍待完成。最终源码 **`c8ce2548f1e9630314112e9b6e76b621a7f0c699`**，[run 37652398749](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37652398749)／[job 112898842218](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37652398749/job/112898842218) **首次且唯一一次完整CI SUCCESS**。当前安装版本已是包含此修复的build33，见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)；以下测试和资产专属build32，不与build33混计。

本次只据父流程已完成结果补记文档，**未运行终端、Git、CI、测试、下载、解包、审图或手机操作**。

用户 build31 真机截图给出 **SG-SOURCE-OPEN (1550)／sourceOpen／恢复分组失败**。SQLite 官方定义 [1550](https://www.sqlite.org/rescode.html#cantopen_symlink) 为 `SQLITE_CANTOPEN_SYMLINK`；[NOFOLLOW](https://www.sqlite.org/c3ref/open.html) 不允许数据库完整路径包含符号链接。失败发生在打开源索引连接，不是本次 Photos 授权错误，也尚未进入写锁检测。

现有 `lstat` 只检查索引目录和文件最后一段；上层目录别名仍可通过这些检查，却被 SQLite 拒绝。旧测试覆盖直接父目录／文件链接，漏了上级目录别名。**手机具体链接在哪一级仍未知，不宣称已检查手机路径或认定就是某个特定系统目录。**普通搜索没有相同 NOFOLLOW 打开限制，搜索可用与清理失败不矛盾。

## 已批准的最小修复

- 新 `SimilarGroupingLocation` 仅解析系统提供的可信 Application Support **基目录**，随后追加固定索引目录；不解析索引目录／文件，不把任意注入目录变成可信路径。
- Foundation 的符号链接解析可能保留或恢复系统前缀别名，因此最后用 `realpath` 获得物理基址；没有硬编码替换系统路径。不存在的基目录只解析已有前缀，不创建目录。
- 保留原路径与物理目标；每次恢复／分组捕获一次。基址比较 dev/inode，不以正常缓存保存会改变的目录时间戳判失效。持续核验原别名与目标指向同一源对象，观察到改指后锁存失败。
- authority 先建立，再让只读源读取和默认分组缓存使用同一物理目标。原路径与目标两侧仍检查直接索引目录、普通文件、硬链接、辅助文件和前后源身份。
- 保留 **READONLY、FULLMUTEX、NOFOLLOW、DELETE 日志模式、真实 reserved writer、同连接 data_version** 及 Photos／发布／选择／删除核验。没有“失败后去掉 NOFOLLOW 重试”、无监视器回退、清库、源迁移或自动重建。
- 主导航、0.80阈值、OCR、搜索评分及12张分页、五列清理浏览、模型／schema／缓存算法身份和删除流程不变。

这修复的是已找到的路径兼容机制，不只是再换提示。仍不能承诺跨 Photos／SQLite／文件系统原子性；两个 SQLite 连接的前后路径核验不是句柄级原子绑定，也不排除短暂改指再恢复的所有竞态。

## 已完成的 build32 原生验证

新增 **24** 项 App 测试：路径18、默认 service 路径集成6。包含真实临时 SQLite + 显式祖先符号链接：旧 NOFOLLOW 调用拒绝1550，新可信基址路径读同一库；旧完整分组缓存与向量位模式保留，首次缺失与成功零组、别名改指、sidecar／writer／data_version、直接目录／文件链接拒绝、无额外源写入和无推理。显式目录注入仍严格拒绝同一祖先链接。

|项目|父流程实际结果|
|---|---|
|Core|**79全通过**。|
|App XCTest|**1549＝1548通过／1项既有SQLite物理文件保护模拟器跳过／0失败**；**491.128秒，wall497.116秒**。|
|新增路径套件|**18／0.191秒，全通过**。|
|复用集成|新增 **6项全通过**；复用套件现共 **71／4.511秒**，不是新增6项单独耗时。新增24已包含在App1549内。|
|真实模型Generated|**8／136.867秒，全通过**；完整 **CPU／`.all`／20 actor**保留。|
|独立UI|**14全通过／1174.786秒**；这是build32结果，不能套用于build33。|

build32没有CI配置、runner、模型门槛或新增测试跳过变更。测试使用合成图库元数据及临时SQLite，不实际读取／删除私人照片；**没有本版UI改动或实际审图记录**。机制测试证明可信系统基址解析兼容祖先链接且仍拒绝不可信路径，**不能证明手机实际链接在哪一级，也不能证明用户手机1550已经消失**。

## build32 历史发布与全量核验

|资产／核验|父流程实际结果|
|---|---|
|Release|[ci-37652398749-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37652398749-1)，ID **405988873**；**2026-10-07T17:16:55Z**发布。|
|IPA|asset **619299845**；[../build/device-download/37652398749/LocalImageIQ-0.11.2-build32-iphoneos-unsigned.ipa](../build/device-download/37652398749/LocalImageIQ-0.11.2-build32-iphoneos-unsigned.ipa)，**1,419,537,921 bytes**。|
|完整文件SHA-256|**`0a0478310e4e1700ba1ad0cba9d0d12b37096791745b5fe086b78d79e0bcdcf0`**；实际全文件流式核验，不是仅核对远端声明。|
|归档完整性|**7-Zip26.04全量CRC PASS：11目录、30文件、解压后1,567,730,022 bytes**。|
|下载记录|[../build/device-download/37652398749/release-fetch-77354ca5-a844-46f5-87fd-cf5a1701f47d.json](../build/device-download/37652398749/release-fetch-77354ca5-a844-46f5-87fd-cf5a1701f47d.json)。|

这是 **0.11.2／32、arm64 Release未签名IPA**，仍需本机Sideloadly重签；原包校验不验证重签包或手机安装。模型／SigLIP768／图像策略／schema／OCR身份沿用，不把身份核对写成完整模型字节比较。当前build33的最终包、测试例外及发布记录另见 [BUILD_STATUS.md](BUILD_STATUS.md)。

## 安装边界

沿用同一 Sideloadly Apple 账号和有效 Bundle ID **覆盖安装，不卸载、不清索引、不重建、不重新授权**；现在选择顶部安装文档中的build33，不要求先安装build32或降级。真机安装与1550现象消失仍须手机确认；不要求实际删除照片测试。若仍失败，只需一张带短码的普通弹窗截图，不增加清库、重索引或反复重试步骤。