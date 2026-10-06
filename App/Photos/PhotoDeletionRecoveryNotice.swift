/// Shared confirmation/completion wording; no recovery service or Photos access.
/// Apple recovery guidance (including the explicit iOS 26 guide):
/// https://support.apple.com/zh-cn/104967
/// https://support.apple.com/zh-cn/guide/iphone/iphb4defbde9/26.0/ios/26.0
enum PhotoDeletionRecoveryNotice {
    static let recovery = "通常会在系统“照片”的“最近删除”中保留30天，可前往那里恢复；以系统显示的剩余天数为准。提前永久删除后无法恢复。共享图库中的照片只能由添加者恢复。"

    static func warning(emptiedGroupCount: Int) -> String {
        let sync = "启用 iCloud 照片时，删除会同步到其他设备；即使本 App 关闭网络访问，系统仍可能同步删除。"
        let fullGroup = emptiedGroupCount > 0
            ? "\n已选中\(emptiedGroupCount)个分组的全部照片，删除后这些组将不保留任何照片。" : ""
        return sync + "\n" + recovery + fullGroup
    }

    static func success(count: Int) -> String {
        "已确认删除\(count)张照片。\(recovery)请手动重新分组。"
    }
}