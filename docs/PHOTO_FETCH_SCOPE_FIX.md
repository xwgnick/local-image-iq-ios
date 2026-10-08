# 单张照片查询范围修复 — 2026-10-08

## 状态：0.12.2／build35修复IPA已交付，定点及首次完整验证通过；真机结果待确认

用户build34截图显示 `SS-ENCODING-PHOTO-CHANGED`。随后明确要求直接修复已知问题，减少通过诊断IPA反复安装／截图协助调试的成本。

本次直接修正源码中已确认的不一致：完整枚举显式包含隐藏／全部连拍照片，而单张按ID查询曾使用默认选项。现在完整枚举、单张读取及已有批量查询均复用 `PhotoLibraryClient.searchFetchOptions()`。该工厂每次返回独立选项对象，不附加日期／相册谓词或数量限制。

没有改同步版本判断、失败处理、模型、向量、索引schema或用户授权；没有清库／重建，没有用跳过照片或放宽版本检查掩盖错误。这不是另一个仅增加诊断输出的修改。

## 验证结果

源码 `61fcfa0794e1821e8fc8007092c31cc865b79dfe`，[定点run 37797859385](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37797859385)／[job 113381905767](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37797859385/job/113381905767) SUCCESS：**124项、0失败、0跳过**，测试3.792秒、wall11.882秒。这不是整次冷编译／模拟器准备耗时。

- 查询选项3项；增量同步53项；失败阶段9项；同步状态42项；手动权限／事务校验17项。
- 新增8项：3项真实PHFetchOptions工厂检查＋5项同步回归。
- 合成图库和真实临时SQLite能复现旧范围差异产生相同 `SS-ENCODING-PHOTO-CHANGED`；同一worker／图库／索引只恢复一致查询选项后成功，只编码新增照片，已有向量保持。
- 真正单张缺失、修改时间／创建时间变化，以及待处理集合之外的图库变化仍被拒绝；未清除原索引或放宽保护。
- 使用开发工作流，没有模型转换、全量UI、IPA或Release。原生App和测试源码已编译；测试未访问或变更私人Photos。

**证据限制：**fake图库明确模拟默认选项与完整选项的范围差异，不是通过真实设备创建隐藏／连拍照片的端到端测试。这证明代码范围一致性与对应合成回归修复，不能证明截图中的具体照片一定属于隐藏／连拍，也不承诺设备上没有其他触发原因。

定点验证时版本仍为0.12.1/build34；已发布build34包不包含这个后续提交，不能重新给旧链接冒充已含修复。

## build35发布授权 — 2026-10-09

用户明确要求“修复，出新的ipa”，随后明确选择“沿用例外，直接出修复包”。版本升至**0.12.2/build35**；仅为这个新构建延续已知“拖动页面收起键盘”例外，依旧记录为SKIP，不宣称已修复或测试通过。点“完成”收起键盘及其他验收不变，不把例外自动扩展到后续版本。

先前124项定点原生测试通过后，完整模型／App／UI／设备打包发布验收及本地包校验均已完成，最终结果如下。保持原Bundle ID、索引和模型身份；同账号覆盖安装，无需卸载、清库、为升级重索引或重新授权。本次无UI功能变更，没有新的UI ZIP下载或截图实审。

## build35 最终交付结果 — 2026-10-09

**DELIVERED／REPAIR-IPA／USER-APPROVED EXCEPTION／PENDING-DEVICE。**生产修复提交为上述 **`61fcfa0794e1821e8fc8007092c31cc865b79dfe`**；最终发布源码 **`c792c46e4299c4223357b57f32e9c0b9e000db2b`**。[唯一完整run 37820463496／job 113459870636](https://github.com/xwgnick/local-image-iq-ios/actions/runs/37820463496/job/113459870636) **第一次完整尝试即SUCCESS**，不是多次失败后通过，也不是把此前定点测试算作完整发布。

|验收范围|最终结果／秒|
|---|---|
|Core／App|**Core79通过；App1740＝1739通过／1既有SQLite模拟器跳过／0失败，505.259，wall513.375**；新增8项通过，已计入App。|
|真实模型Generated|**8通过／128.518**；CPU／`.all`／完整20 actor及正常发布门槛保留。|
|修复相关套件（均通过，已计入App）|查询选项 **3／0.014**；增量同步 **53／0.670**；手动权限／事务 **17／0.224**；失败阶段 **9／0.118**；同步状态 **42／0.325**。|
|DebugTools|**7通过／39.826**。|
|独立UI|**14＝13通过／1明确批准键盘跳过／0失败，1180.060，wall1180.071**；导航 **9通过／965.937**；键盘 **5＝4通过／1跳过，214.123**。|

实际日志中的两项跳过分别为 `testCacheFileProtectionOnPhysicalDevice`（模拟器不支持物理文件保护）与 `testDraggingScrollViewDismissesKeyboard`（已批准build33／34／35例外）。没有其他静默豁免；**拖动收键盘仍未验证修复，“完成”仍可收起，例外不自动适用于后续build**。

### 已发布安装包与本地校验

- [公开Release ci-37820463496-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-37820463496-1)，ID **407151862**，**2026-10-08T18:41:54Z**发布，**9资产、prerelease、非draft**。
- [../build/device-download/37820463496/LocalImageIQ-0.12.2-build35-iphoneos-unsigned.ipa](../build/device-download/37820463496/LocalImageIQ-0.12.2-build35-iphoneos-unsigned.ipa) · [IPA直链](https://github.com/xwgnick/local-image-iq-ios/releases/download/ci-37820463496-1/LocalImageIQ-0.12.2-build35-iphoneos-unsigned.ipa)；asset **622679737**，**1,419,698,527 bytes**；实际全文件SHA-256 **`3ecc4b2f35bcc818bbbc87b15611cc5534baca62291ee0fdcc535bf10fcdd86e`**。
- [../build/device-download/37820463496/release-fetch-58e66043-d76c-417b-912b-e039ceec5f37.json](../build/device-download/37820463496/release-fetch-58e66043-d76c-417b-912b-e039ceec5f37.json) 记录完整流式下载核验（`ok=true`，新增Release资产下载 **1,419,709,572 bytes**）；[../build/device-download/37820463496/release-fetch-fba3d70a-75f4-4dea-b4da-3f0a21712e99.json](../build/device-download/37820463496/release-fetch-fba3d70a-75f4-4dea-b4da-3f0a21712e99.json) 记录第二次对已有完整文件重新计算哈希。
- **7-Zip26.04全量CRC：Everything is Ok**，**11目录、30文件，解压后1,568,502,046 bytes**。设备报告确认 **0.12.2／35、arm64 Release、未签名、Xcode16.4／SDK18.5、最低iOS17**；SigLIP768及Places哈希未变，未做跨构建完整模型权重比较。

**交付边界与使用：**已收到错误码截图，已修正明确的查询范围不一致并交付修复IPA；合成图库＋真实临时SQLite的旧／新验证不是手机失败资产属于隐藏／连拍的证明。没有访问／删除私人Photos或完成手机E2E，**物理手机故障是否消失仍待确认**。沿用原Sideloadly账号／原有效Bundle ID覆盖安装后正常打开、使用修复后的App，不安排常规诊断安装／截图取证；安装见 [WINDOWS_IPHONE_INSTALL.md](WINDOWS_IPHONE_INSTALL.md)，完整账本见 [BUILD_STATUS.md](BUILD_STATUS.md)。