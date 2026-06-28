#!/usr/bin/env swift
/// Run from the project root:  swift generate-icon.swift
/// Generates all macOS AppIcon PNG sizes and writes them into
/// Sources/SocktainerProbeUI/Assets.xcassets/AppIcon.appiconset/

import AppKit
import CoreGraphics
import Foundation

// ─── Color helpers ────────────────────────────────────────────────────────────

func cgc(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    var n: UInt64 = 0
    Scanner(string: s).scanHexInt64(&n)
    let r = CGFloat((n >> 16) & 0xFF) / 255
    let g = CGFloat((n >> 8)  & 0xFF) / 255
    let b = CGFloat(n & 0xFF) / 255
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func lgrad(_ cs: CGColorSpace, _ stops: [(String, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: cs,
               colors: stops.map { cgc($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

// ─── Apple superellipse (n=5) ─────────────────────────────────────────────────

func squirclePath(size: CGFloat) -> CGPath {
    let n: CGFloat = 5
    let c = size / 2
    let path = CGMutablePath()
    for i in 0...200 {
        let t = CGFloat(i) / 200.0 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let px = c + c * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2/n)
        let py = c + c * (st >= 0 ? 1 : -1) * pow(abs(st), 2/n)
        i == 0 ? path.move(to: CGPoint(x: px, y: py)) : path.addLine(to: CGPoint(x: px, y: py))
    }
    path.closeSubpath()
    return path
}

// ─── Main draw ────────────────────────────────────────────────────────────────
// All layout coordinates are expressed in CG space (Y increases upward).
// Design origin was top-left (canvas-style), so Y_CG = W - Y_canvas.

func drawIcon(ctx: CGContext, W: CGFloat) {
    let cs = CGColorSpaceCreateDeviceRGB()

    // ── Squircle clip ──────────────────────────────────────────────────────────
    ctx.addPath(squirclePath(size: W))
    ctx.clip()

    // ── Background — deep blue-black, top-lit ─────────────────────────────────
    // Canvas light source: (W*0.50, W*0.22 from top) → CG: (W*0.50, W*0.78 from bottom)
    ctx.drawRadialGradient(
        lgrad(cs, [("1E3358",1,0),("111C30",1,0.38),("090D18",1,0.75),("050810",1,1)]),
        startCenter: CGPoint(x: W*0.50, y: W*0.78), startRadius: 0,
        endCenter:   CGPoint(x: W*0.50, y: W*0.45), endRadius:   W*0.82,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Top-surface sheen (CG: gradient from top → W*0.78 down to W*0.56)
    if W >= 64 {
        ctx.drawLinearGradient(
            lgrad(cs, [("FFFFFF",0.055,0),("FFFFFF",0,1)]),
            start: CGPoint(x: 0, y: W),
            end:   CGPoint(x: 0, y: W*0.78),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // ── Layout (CG coordinates) ────────────────────────────────────────────────
    // Canvas: bx=W*0.150, by=W*0.272, bw=W*0.415, bh=W*0.415
    let bx: CGFloat = W * 0.150
    let bh: CGFloat = W * 0.415
    let bw: CGFloat = W * 0.415
    let by: CGFloat = W - W*0.272 - bh          // CG: W*(1-0.272-0.415) = W*0.313
    let cr: CGFloat = max(1, W * 0.036)
    let lw: CGFloat = max(1, W * 0.0178)

    // Arc origin: right edge midpoint of box
    let arcX: CGFloat = bx + bw               // W*0.565
    let arcY: CGFloat = by + bh * 0.50        // W*0.5205

    // ── Drop shadow ────────────────────────────────────────────────────────────
    if W >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -W*0.022),
                      blur: W*0.055,
                      color: cgc("000000", 0.55))
        let boxPath = CGPath(roundedRect: CGRect(x: bx, y: by, width: bw, height: bh),
                             cornerWidth: cr, cornerHeight: cr, transform: nil)
        ctx.addPath(boxPath)
        ctx.setStrokeColor(cgc("FFFFFF", 0.001))
        ctx.setLineWidth(lw)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // ── Container box — outline, no fill ──────────────────────────────────────
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Top edge (brighter — in CG, "top of box" = higher Y value = by+bh)
    let topEdge = CGMutablePath()
    topEdge.move(to:    CGPoint(x: bx + cr,      y: by + bh))
    topEdge.addLine(to: CGPoint(x: bx + bw - cr, y: by + bh))
    topEdge.addQuadCurve(to:      CGPoint(x: bx + bw, y: by + bh - cr),
                         control: CGPoint(x: bx + bw, y: by + bh))
    ctx.addPath(topEdge)
    ctx.setStrokeColor(cgc("EEF2FF", 0.95))
    ctx.strokePath()

    // Other three sides (slightly dimmer — in shadow relative to top light)
    let otherSides = CGMutablePath()
    otherSides.move(to:    CGPoint(x: bx + bw, y: by + bh - cr))
    otherSides.addLine(to: CGPoint(x: bx + bw, y: by + cr))
    otherSides.addQuadCurve(to:      CGPoint(x: bx + bw - cr, y: by),
                            control: CGPoint(x: bx + bw,      y: by))
    otherSides.addLine(to: CGPoint(x: bx + cr, y: by))
    otherSides.addQuadCurve(to:      CGPoint(x: bx, y: by + cr),
                            control: CGPoint(x: bx, y: by))
    otherSides.addLine(to: CGPoint(x: bx, y: by + bh - cr))
    otherSides.addQuadCurve(to:      CGPoint(x: bx + cr, y: by + bh),
                            control: CGPoint(x: bx,      y: by + bh))
    ctx.addPath(otherSides)
    ctx.setStrokeColor(cgc("DCE2F8", 0.78))
    ctx.strokePath()

    // Shelf line — Canvas: shelfY = by_canvas + bh*0.32 = W*(0.272+0.1328) = W*0.4048
    // CG: W - W*0.4048 = W*0.5952
    if W >= 48 {
        let shelfY: CGFloat = W - W * 0.4048
        let shelf = CGMutablePath()
        shelf.move(to:    CGPoint(x: bx + cr * 1.2, y: shelfY))
        shelf.addLine(to: CGPoint(x: bx + bw - cr * 1.2, y: shelfY))
        ctx.addPath(shelf)
        ctx.setStrokeColor(cgc("FFFFFF", 0.13))
        ctx.setLineWidth(max(0.5, lw * 0.52))
        ctx.setLineCap(.butt)
        ctx.strokePath()
        ctx.setLineCap(.round)
        ctx.setLineWidth(lw)
    }

    // ── Arcs — two concentric right-facing semicircles ────────────────────────
    // CG: from PI/2 (top) clockwise to -PI/2 (bottom) = right semicircle
    let r1: CGFloat = W * 0.185
    let r2: CGFloat = W * 0.295

    // Outer (subdued)
    let arc2 = CGMutablePath()
    arc2.addArc(center: CGPoint(x: arcX, y: arcY),
                radius: r2, startAngle: .pi/2, endAngle: -.pi/2, clockwise: true)
    ctx.addPath(arc2)
    ctx.setStrokeColor(cgc("F5B340", 0.32))
    ctx.setLineWidth(lw)
    ctx.strokePath()

    // Inner (primary)
    let arc1 = CGMutablePath()
    arc1.addArc(center: CGPoint(x: arcX, y: arcY),
                radius: r1, startAngle: .pi/2, endAngle: -.pi/2, clockwise: true)
    ctx.addPath(arc1)
    ctx.setStrokeColor(cgc("F5B340", 0.92))
    ctx.strokePath()

    // ── Dot — probe contact point ─────────────────────────────────────────────
    let dotR: CGFloat = max(2, W * 0.0255)

    if W >= 48 {
        ctx.drawRadialGradient(
            lgrad(cs, [("FFB932",0.28,0),("FFB932",0.08,0.5),("FFB932",0,1)]),
            startCenter: CGPoint(x: arcX, y: arcY), startRadius: dotR * 0.5,
            endCenter:   CGPoint(x: arcX, y: arcY), endRadius:   dotR * 3.8,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    ctx.addEllipse(in: CGRect(x: arcX-dotR, y: arcY-dotR, width: dotR*2, height: dotR*2))
    ctx.setFillColor(cgc("F5B340"))
    ctx.fillPath()

    // Specular highlight
    if W >= 64 {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: arcX-dotR, y: arcY-dotR, width: dotR*2, height: dotR*2))
        ctx.clip()
        ctx.drawRadialGradient(
            lgrad(cs, [("FFFFDC",0.55,0),("FFFFDC",0,1)]),
            startCenter: CGPoint(x: arcX - dotR*0.3, y: arcY + dotR*0.3), startRadius: 0,
            endCenter:   CGPoint(x: arcX, y: arcY), endRadius: dotR,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // ── Squircle inner top gloss ───────────────────────────────────────────────
    if W >= 64 {
        ctx.saveGState()
        ctx.addPath(squirclePath(size: W))
        ctx.clip()
        ctx.drawLinearGradient(
            lgrad(cs, [("FFFFFF",0.10,0),("FFFFFF",0,1)]),
            start: CGPoint(x: 0, y: W),
            end:   CGPoint(x: 0, y: W*0.88),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

// ─── Render and save ──────────────────────────────────────────────────────────

let outputDir = "Sources/SocktainerProbeUI/Assets.xcassets/AppIcon.appiconset"
try! FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),   // same as @2x above — both named differently in Contents.json
    ("icon_32x32@2x",   64),
    ("icon_128x128",   128),
    ("icon_128x128@2x",256),
    ("icon_256x256",   256),
    ("icon_256x256@2x",512),
    ("icon_512x512",   512),
    ("icon_512x512@2x",1024),
]

for spec in specs {
    let px = spec.pixels
    let W  = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("✗ Failed to create context for \(spec.name)"); continue
    }

    drawIcon(ctx: ctx, W: W)

    guard let img = ctx.makeImage() else { print("✗ No image for \(spec.name)"); continue }
    let bmp = NSBitmapImageRep(cgImage: img)
    guard let png = bmp.representation(using: .png, properties: [:]) else {
        print("✗ PNG encoding failed for \(spec.name)"); continue
    }
    let path = "\(outputDir)/\(spec.name).png"
    try! png.write(to: URL(fileURLWithPath: path))
    print("✓  \(spec.name).png  (\(px)px)")
}

// ─── Contents.json ────────────────────────────────────────────────────────────

let contentsJSON = """
{
  "images" : [
    { "filename" : "icon_16x16.png",     "idiom" : "mac", "scale" : "1x", "size" : "16x16"   },
    { "filename" : "icon_16x16@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "16x16"   },
    { "filename" : "icon_32x32.png",     "idiom" : "mac", "scale" : "1x", "size" : "32x32"   },
    { "filename" : "icon_32x32@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "32x32"   },
    { "filename" : "icon_128x128.png",   "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png","idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",   "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png","idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",   "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png","idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contentsJSON.data(using: .utf8)!
    .write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("✓  Contents.json")
print("\nDone — icon written to \(outputDir)")
