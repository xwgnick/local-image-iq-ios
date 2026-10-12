import AppKit

enum PilotError: Error { case source(String), rendering(String) }
let output = URL(fileURLWithPath: "build/store-photos", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var names: [String] = []

func save(_ image: NSImage, name: String) throws {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        throw PilotError.rendering(name)
    }
    try png.write(to: output.appendingPathComponent(name), options: .atomic)
    names.append(name)
}

for (source, target) in [("sunset-pier.jpg", "moment-sunset.png"),
                         ("coffee.png", "distractor-coffee.png"),
                         ("chelsea.png", "distractor-cat.png")] {
    guard let image = NSImage(contentsOfFile: "build/store-source-photos/\(source)") else {
        throw PilotError.source(source)
    }
    try save(image, name: target)
}

func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
          size: CGFloat, bold: Bool = false, color: NSColor = .darkGray) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    for (index, line) in value.components(separatedBy: "\n").enumerated() {
        (line as NSString).draw(in: NSRect(x: x, y: y - CGFloat(index) * size * 1.4,
                                         width: width, height: size * 1.3),
                               withAttributes: [.font: font, .foregroundColor: color])
    }
}

for index in 0..<4 {
    let image = NSImage(size: NSSize(width: 1600, height: 1100))
    image.lockFocus()
    NSColor(calibratedWhite: 0.91 - Double(index) * 0.02, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 1100).fill()
    NSColor(calibratedRed: 0.86, green: 0.93, blue: 0.92, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 120, y: 150, width: 1360, height: 820),
                 xRadius: 45, yRadius: 45).fill()
    text("身份证检索 · 演示卡", x: 185, y: 790, width: 1180, size: 62, bold: true)
    text("虚构样本 / NOT A VALID ID", x: 185, y: 685, width: 1180, size: 40)
    let front = index % 2 == 0
    if front {
        NSColor(calibratedWhite: 0.7, alpha: 1).setFill()
        NSRect(x: 1150, y: 350, width: 220, height: 270).fill()
        text("头像\n占位", x: 1190, y: 415, width: 180, size: 44)
        text("姓名：演示人物 \(index + 1)\n用途：照片搜索演示\n编号：DEMO-A\(index + 1)",
             x: 185, y: 360, width: 900, size: 48)
    } else {
        text("照片检索演示\n非政府签发 / 不含真实身份信息\n背面样式 \(index + 1)",
             x: 185, y: 360, width: 1120, size: 48)
    }
    text("演示样本 · 不可用于身份验证", x: 185, y: 220, width: 1180, size: 45, bold: true,
         color: NSColor(calibratedRed: 0.65, green: 0.15, blue: 0.12, alpha: 1))
    image.unlockFocus()
    try save(image, name: "demo-identity-\(index + 1).png")
}

for index in 0..<4 {
    let image = NSImage(size: NSSize(width: 1200, height: 1600))
    image.lockFocus()
    NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.88, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1200, height: 1600).fill()
    text("片刻小馆", x: 110, y: 1320, width: 980, size: 94, bold: true)
    text("自制菜单 / DEMO MENU", x: 110, y: 1180, width: 980, size: 42)
    let codes = ["Q7M2", "R8N3", "S9P4", "T6K5"]
    let drinks = ["桂花拿铁", "抹茶拿铁", "柠檬苏打", "热巧克力"]
    text("\(drinks[index])\n今日餐点：烤吐司\n请凭取餐码领取", x: 110, y: 750, width: 980, size: 72)
    text("取餐码", x: 110, y: 590, width: 980, size: 60)
    text(codes[index], x: 110, y: 400, width: 980, size: 150, bold: true)
    text("演示素材 · 非真实订单", x: 110, y: 130, width: 980, size: 42)
    image.unlockFocus()
    try save(image, name: "demo-menu-\(index + 1).png")
}
try JSONEncoder().encode(names.sorted()).write(to: output.appendingPathComponent("inventory.json"))
print("Prepared 11 distinct pilot assets: real sunset/coffee/cat, four fictional identity cards and four OCR menus.")
