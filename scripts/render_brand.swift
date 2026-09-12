import AppKit
import ImageIO
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let source = CGImageSourceCreateWithURL(root.appendingPathComponent("Phrayo.png") as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
// Encode the source logo on an opaque background required by iOS app icons.
for size in [24, 40, 60, 1024] {
  let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.setFillColor(CGColor(red: 250.0/255, green: 247.0/255, blue: 239.0/255, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: size, height: size))
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
  let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
  try data.write(to: root.appendingPathComponent("assets/brand/icon-\(size).png"))
  if size == 1024 {
    try data.write(to: root.appendingPathComponent("ios/Runner/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
  }
}
