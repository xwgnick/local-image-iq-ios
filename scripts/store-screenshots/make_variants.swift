import AppKit

enum PhotoPreparationError: Error {
    case unreadable(String)
    case encoding(String)
}

let output = URL(fileURLWithPath: "build/store-photos", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for name in ["coffee", "chelsea"] {
    let url = URL(fileURLWithPath: "build/store-source-photos/\(name).png")
    guard let source = NSImage(contentsOf: url),
          let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw PhotoPreparationError.unreadable(name)
    }
    for index in 0..<6 {
        let inset = index * 2
        let rect = CGRect(x: inset, y: inset, width: image.width - 2 * inset, height: image.height - 2 * inset)
        guard let crop = image.cropping(to: rect) else { throw PhotoPreparationError.encoding(name) }
        let bitmap = NSBitmapImageRep(cgImage: crop)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PhotoPreparationError.encoding(name)
        }
        try png.write(to: output.appendingPathComponent("\(name)-crop-\(index).png"), options: .atomic)
    }
}
print("Prepared 12 public demonstration photos; small crop variants, no private photos.")
