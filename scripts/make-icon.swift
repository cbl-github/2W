// 生成 1024x1024 app 图标 PNG。用法: swift scripts/make-icon.swift <输出.png>
//
// 2W 的标志：一个 W 拆成左右两笔，左笔米白、右笔强调蓝，在中峰交汇。
// 双色 = 名字里的 “2”（原文与译文两层），字形 = “W”。
// 只有四道粗笔画，16px 下不糊——细线条和小字在 16px 一律消失，别再往里加东西。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments[1]
let S = 1024

let ctx = CGContext(
    data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// 磁贴：824pt 圆角矩形（macOS 图标网格），带轻微纵向渐变
let tileInset: CGFloat = 100
let tile = CGRect(x: tileInset, y: tileInset, width: 1024 - 2 * tileInset, height: 1024 - 2 * tileInset)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgba(0x2E2E33), rgba(0x141417)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 512, y: 1024 - tileInset),
    end: CGPoint(x: 512, y: tileInset),
    options: [])

// W 的五个顶点（CoreGraphics 原点在左下，y 向上）。
// 中峰 p2 只到 62% 高：W 的中峰压过肩线会显得像两个并排的 V。
let p0 = CGPoint(x: 252, y: 692)
let p1 = CGPoint(x: 382, y: 344)
let p2 = CGPoint(x: 512, y: 556)
let p3 = CGPoint(x: 642, y: 344)
let p4 = CGPoint(x: 772, y: 692)

// 94pt ≈ 16px 图标上的 1.5px：再细就在小尺寸糊成灰块。
// 圆头笔画会向端点外各扩 47pt，字形实际占到磁贴的八成宽，留白刚好。
ctx.setLineWidth(94)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// 先蓝后白：中峰处两笔重叠，后画的压在上面，让米白那笔显得连贯
ctx.setStrokeColor(rgba(0x5B9BFF))
ctx.addLines(between: [p2, p3, p4])
ctx.strokePath()

ctx.setStrokeColor(rgba(0xF5F5F7))
ctx.addLines(between: [p0, p1, p2])
ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
