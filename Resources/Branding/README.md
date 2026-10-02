# B02 初版品牌素材

用户于 2026-10-02 选定“照片＋搜索／高级感”B02，并要求去除外部黑背景、保留前景图标块。随后授权接入 App 图标与纯图标启动页。

[B02-selected.png](B02-selected.png) 是其选定透明前景的字节一致副本，来源图由 GPT Image 2 生成，随后仅作前景 alpha 提取。

SHA-256：`5c5dd3cfb41febfccdffbd4feacaf5e9033d8d9c49a26d3551a74f3f70b4500f`。

本目录用于可复现来源记录，**不加入 App 资源阶段**；App 只打包 [Assets.xcassets](../../App/Assets.xcassets/Contents.json) 内的派生资源。

[manifest.json](manifest.json) 记录尺寸和派生哈希。[生成脚本](../../scripts/build_brand_assets.py) 仅在本地处理 PNG，无 API、无网络。未对素材作商标或市场全量近似清查。