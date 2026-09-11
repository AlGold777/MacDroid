import Cocoa

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    
    let scale = size / 1024.0
    
    // Squircle background path (macOS icon standard shape ~ 824x824 inside 1024x1024 canvas)
    let margin: CGFloat = 100 * scale
    let iconRect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let cornerRadius: CGFloat = 185 * scale
    let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    
    // Shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 24 * scale, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()
    
    // Background Gradient (Obsidian Slate / Deep Space)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 1.0), // Top: Deep Slate Blue
        CGColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1.0)  // Bottom: Obsidian Dark
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(bgGradient, start: CGPoint(x: size / 2, y: size - margin), end: CGPoint(x: size / 2, y: margin), options: [])
    }
    
    // Inner Glow / Border
    ctx.setLineWidth(4.0 * scale)
    ctx.setStrokeColor(CGColor(red: 0.25, green: 0.55, blue: 0.95, alpha: 0.4))
    ctx.addPath(squirclePath)
    ctx.strokePath()
    
    // Subtle dual panes
    ctx.setStrokeColor(CGColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 0.15))
    ctx.setLineWidth(2.0 * scale)
    // Left pane rectangle
    let leftPane = CGRect(x: 200 * scale, y: 340 * scale, width: 280 * scale, height: 380 * scale)
    let leftPath = CGPath(roundedRect: leftPane, cornerWidth: 20 * scale, cornerHeight: 20 * scale, transform: nil)
    ctx.addPath(leftPath)
    ctx.strokePath()
    
    // Mac / Computer top bar inside left pane
    let leftHeader = CGRect(x: 200 * scale, y: 680 * scale, width: 280 * scale, height: 40 * scale)
    ctx.setFillColor(CGColor(red: 0.22, green: 0.45, blue: 0.85, alpha: 0.4))
    ctx.fill(leftHeader)
    
    // Left pane mock files
    for i in 0..<4 {
        let lineY = (620 - i * 60) * Int(scale)
        let lineRect = CGRect(x: 240 * scale, y: CGFloat(lineY), width: 200 * scale, height: 16 * scale)
        ctx.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 0.35))
        ctx.fill(lineRect)
    }
    
    // Right pane: Smartphone outline (Android)
    let phoneRect = CGRect(x: 544 * scale, y: 340 * scale, width: 280 * scale, height: 380 * scale)
    let phonePath = CGPath(roundedRect: phoneRect, cornerWidth: 32 * scale, cornerHeight: 32 * scale, transform: nil)
    ctx.setStrokeColor(CGColor(red: 0.15, green: 0.75, blue: 0.45, alpha: 0.5))
    ctx.setLineWidth(3.0 * scale)
    ctx.addPath(phonePath)
    ctx.strokePath()
    
    // Phone screen header
    let phoneHeader = CGRect(x: 564 * scale, y: 670 * scale, width: 240 * scale, height: 30 * scale)
    ctx.setFillColor(CGColor(red: 0.15, green: 0.75, blue: 0.45, alpha: 0.35))
    ctx.fill(phoneHeader)
    
    // Phone mock files
    for i in 0..<4 {
        let lineY = (610 - i * 60) * Int(scale)
        let lineRect = CGRect(x: 580 * scale, y: CGFloat(lineY), width: 200 * scale, height: 16 * scale)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.5, alpha: 0.35))
        ctx.fill(lineRect)
    }
    
    // Center transfer badge: Lightning / Dual Arrows
    let centerBadgeRect = CGRect(x: 440 * scale, y: 440 * scale, width: 144 * scale, height: 144 * scale)
    let badgePath = CGPath(ellipseIn: centerBadgeRect, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 20 * scale, color: CGColor(red: 0.0, green: 0.75, blue: 1.0, alpha: 0.8))
    ctx.setFillColor(CGColor(red: 0.05, green: 0.65, blue: 0.95, alpha: 1.0))
    ctx.addPath(badgePath)
    ctx.fillPath()
    ctx.restoreGState()
    
    // Transfer arrows in center badge (Right arrow and Left arrow)
    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95))
    
    // Top arrow (Right ->)
    let arrowTop = CGMutablePath()
    arrowTop.move(to: CGPoint(x: 470 * scale, y: 530 * scale))
    arrowTop.addLine(to: CGPoint(x: 530 * scale, y: 530 * scale))
    arrowTop.addLine(to: CGPoint(x: 530 * scale, y: 544 * scale))
    arrowTop.addLine(to: CGPoint(x: 554 * scale, y: 520 * scale))
    arrowTop.addLine(to: CGPoint(x: 530 * scale, y: 496 * scale))
    arrowTop.addLine(to: CGPoint(x: 530 * scale, y: 510 * scale))
    arrowTop.addLine(to: CGPoint(x: 470 * scale, y: 510 * scale))
    arrowTop.closeSubpath()
    ctx.addPath(arrowTop)
    ctx.fillPath()
    
    // Bottom arrow (Left <-)
    let arrowBottom = CGMutablePath()
    arrowBottom.move(to: CGPoint(x: 554 * scale, y: 474 * scale))
    arrowBottom.addLine(to: CGPoint(x: 494 * scale, y: 474 * scale))
    arrowBottom.addLine(to: CGPoint(x: 494 * scale, y: 460 * scale))
    arrowBottom.addLine(to: CGPoint(x: 470 * scale, y: 484 * scale))
    arrowBottom.addLine(to: CGPoint(x: 494 * scale, y: 508 * scale))
    arrowBottom.addLine(to: CGPoint(x: 494 * scale, y: 494 * scale))
    arrowBottom.addLine(to: CGPoint(x: 554 * scale, y: 494 * scale))
    arrowBottom.closeSubpath()
    ctx.addPath(arrowBottom)
    ctx.fillPath()
    
    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert image to PNG")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconsetDir = "MacDroidCommander.iconset"
try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

print("Rendering icon sizes...")
for (name, s) in sizes {
    let img = renderIcon(size: s)
    savePNG(image: img, path: "\(iconsetDir)/\(name)")
}

print("Running iconutil to generate AppIcon.icns...")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", "AppIcon.icns"]
try! task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("✓ Successfully generated AppIcon.icns")
    let targetPath = "build/MacDroid Commander.app/Contents/Resources/AppIcon.icns"
    try? fm.removeItem(atPath: targetPath)
    try! fm.copyItem(atPath: "AppIcon.icns", toPath: targetPath)
    print("✓ Copied AppIcon.icns to \(targetPath)")
} else {
    print("❌ iconutil failed with exit code \(task.terminationStatus)")
}
