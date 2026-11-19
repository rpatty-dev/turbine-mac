import AppKit
// Renders assets/icon.svg into build/AppIcon.iconset (run by build.sh).
let svg = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] { for m in [1, 2] {
  let px = s * m
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(s)x\(s)\(m == 2 ? "@2x" : "").png"))
} }
