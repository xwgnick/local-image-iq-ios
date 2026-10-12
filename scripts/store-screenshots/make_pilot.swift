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

guard let specimen = NSImage(contentsOfFile: "build/store-source-photos/identity-sample-both.png") else {
    throw PilotError.source("identity-sample-both.png")
}
for index in 0..<4 {
    let image = NSImage(size: NSSize(width: 1600, height: 1100))
    image.lockFocus()
    let backgrounds: [NSColor] = [
        NSColor(calibratedRed: 0.83, green: 0.76, blue: 0.65, alpha: 1),
        NSColor(calibratedWhite: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.63, green: 0.69, blue: 0.72, alpha: 1),
        NSColor(calibratedRed: 0.90, green: 0.87, blue: 0.81, alpha: 1),
    ]
    backgrounds[index].setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 1100).fill()
    for line in 0..<22 {
        NSColor(calibratedWhite: index == 1 ? 0.75 : 0.25, alpha: 0.025).setFill()
        NSRect(x: 0, y: CGFloat(line) * 52, width: 1600, height: 2).fill()
    }
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 800, yBy: 560)
    transform.rotate(byDegrees: [CGFloat(-5), 4, -3, 6][index])
    transform.concat()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.30)
    shadow.shadowOffset = NSSize(width: 8, height: -14)
    shadow.shadowBlurRadius = 24
    shadow.set()
    // AppKit source coordinates are bottom-up: the specimen front is the lower half.
    let front = index % 2 == 0
    let source = NSRect(x: 0, y: front ? 0 : specimen.size.height / 2,
                        width: specimen.size.width, height: specimen.size.height / 2)
    specimen.draw(in: NSRect(x: -680, y: -430, width: 1360, height: 860),
                  from: source, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    text("公开证件样本 · NOT A VALID ID · 不可用于身份验证",
         x: 120, y: 35, width: 1380, size: 28)
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
    let locations = ["北门值班室", "松桥路东口", "河畔图书馆", "梧桐街南门"]
    text("备注：请送到\(locations[index])，交给现场工作人员。", x: 110, y: 280, width: 980, size: 28)
    text("演示素材 · 非真实订单", x: 110, y: 130, width: 980, size: 42)
    image.unlockFocus()
    try save(image, name: "demo-menu-\(index + 1).png")
}
try JSONEncoder().encode(names.sorted()).write(to: output.appendingPathComponent("inventory.json"))
print("Prepared 11 distinct pilot assets: real sunset/coffee/cat, four fictional identity cards and four OCR menus.")
