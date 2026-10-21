import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MoonDrop icon generator — 1024pt master, crescent moon + falling drop.
// Run from the repository root: swift tools/generate_icons.swift

let root = FileManager.default.currentDirectoryPath
let assetDir = "\(root)/assets/icon"

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func makeContext(_ size: Int, opaque: Bool) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue
                      : CGImageAlphaInfo.premultipliedLast.rawValue
    return CGContext(data: nil, width: size, height: size,
                     bitsPerComponent: 8, bytesPerRow: 0,
                     space: space, bitmapInfo: info)!
}

func save(_ context: CGContext, _ path: String) {
    guard let image = context.makeImage() else { fatalError("no image") }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(
        url, UTType.png.identifier as CFString, 1, nil) else { fatalError("no destination") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("write failed: \(path)") }
    print("wrote \(path)")
}

/// 月亮用的遮罩：白=可见，黑=挖空
func crescentMask(diameter: Int) -> CGImage {
    let context = makeContext(diameter, opaque: true)
    let scale = CGFloat(diameter) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 500 - 240, y: 610 - 240, width: 480, height: 480))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillEllipse(in: CGRect(x: 605 - 240, y: 690 - 240, width: 480, height: 480))
    return context.makeImage()!
}

func dropletPath(center: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
    let radius = width / 2
    let bottomCenter = CGPoint(x: center.x, y: center.y - height / 2 + radius)
    let top = CGPoint(x: center.x, y: center.y + height / 2)
    let path = CGMutablePath()
    path.move(to: top)
    path.addCurve(to: CGPoint(x: center.x - radius, y: center.y),
                  control1: CGPoint(x: center.x - radius * 0.30, y: center.y + height * 0.22),
                  control2: CGPoint(x: center.x - radius, y: center.y + height * 0.08))
    path.addArc(center: bottomCenter, radius: radius,
                startAngle: .pi, endAngle: .pi * 2, clockwise: false)
    path.addCurve(to: top,
                  control1: CGPoint(x: center.x + radius, y: center.y + height * 0.08),
                  control2: CGPoint(x: center.x + radius * 0.30, y: center.y + height * 0.22))
    path.closeSubpath()
    return path
}

func drawMoonAndDrop(in context: CGContext, scale: CGFloat = 1) {
    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    let mask = crescentMask(diameter: 1024)
    context.saveGState()
    context.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 1024), mask: mask)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.restoreGState()

    // 水滴：淡蓝白，带一点点冷色
    let drop = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgba(0xFFFFFF), rgba(0xB9D8FF)] as CFArray,
                          locations: [0, 1])!
    context.saveGState()
    context.addPath(dropletPath(center: CGPoint(x: 655, y: 305), width: 112, height: 158))
    context.clip()
    context.drawLinearGradient(drop,
                               start: CGPoint(x: 640, y: 384),
                               end: CGPoint(x: 640, y: 216),
                               options: [])
    context.restoreGState()

    // 星星
    context.setFillColor(rgba(0xFFFFFF, 0.55))
    for (x, y, r) in [(300.0, 800.0, 7.0), (790.0, 780.0, 5.0), (260.0, 470.0, 4.0)] {
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    context.restoreGState()
}

func drawBackground(in context: CGContext, rect: CGRect, rounded: Bool) {
    context.saveGState()
    if rounded {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil))
        context.clip()
    }

    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [rgba(0x0A1330), rgba(0x173572), rgba(0x2450B8)] as CFArray,
                              locations: [0, 0.58, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.maxX, y: rect.maxY),
                               options: [])

    let halo = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgba(0x6F8DFF, 0.42), rgba(0x6F8DFF, 0.0)] as CFArray,
                          locations: [0, 1])!
    context.drawRadialGradient(halo,
                               startCenter: CGPoint(x: 480, y: 640), startRadius: 0,
                               endCenter: CGPoint(x: 480, y: 640), endRadius: 620,
                               options: [])

    if rounded {
        let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                   colors: [rgba(0xFFFFFF, 0.14), rgba(0xFFFFFF, 0.0)] as CFArray,
                                   locations: [0, 1])!
        context.drawLinearGradient(highlight,
                                   start: CGPoint(x: 512, y: rect.maxY),
                                   end: CGPoint(x: 512, y: rect.midY),
                                   options: [])
    }
    context.restoreGState()
}

// iOS / full-bleed master
do {
    let context = makeContext(1024, opaque: true)
    drawBackground(in: context, rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), rounded: false)
    drawMoonAndDrop(in: context)
    save(context, "\(assetDir)/moondrop-ios-1024.png")
}

// macOS: rounded square with transparent margin
do {
    let context = makeContext(1024, opaque: false)
    let rect = CGRect(x: 84, y: 84, width: 856, height: 856)
    drawBackground(in: context, rect: rect, rounded: true)
    context.saveGState()
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil))
    context.clip()
    context.translateBy(x: 0, y: 0)
    drawMoonAndDrop(in: context)
    context.restoreGState()
    save(context, "\(assetDir)/moondrop-macos-1024.png")
}

// Android adaptive foreground: transparent, art centered in safe zone
do {
    let dimension = 432
    let context = makeContext(dimension, opaque: false)
    let scale = CGFloat(dimension) / 1024
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    drawMoonAndDrop(in: context)
    context.restoreGState()
    save(context, "\(assetDir)/moondrop-foreground-432.png")
}
