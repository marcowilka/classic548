#!/usr/bin/env swift
import AppKit
import Foundation

/// Generates a Retina DMG background for ClassicAFP.
/// Logical window content: 660×400 → bitmap 1320×800 @2x.
/// Icon slots (logical, Finder coords from top): app ~160,145 · Applications ~500,145
///
/// Original artwork. The Applications folder icon is drawn by Finder from the
/// symlink; we do not embed Apple's icon resources.

let scale: CGFloat = 2
let logicalW: CGFloat = 660
let logicalH: CGFloat = 400
let width = Int(logicalW * scale)
let height = Int(logicalH * scale)

guard CommandLine.arguments.count >= 2 else {
  fputs("usage: generate_background.swift <out.png>\n", stderr)
  exit(1)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
  data: nil,
  width: width,
  height: height,
  bitsPerComponent: 8,
  bytesPerRow: 0,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  fputs("error: could not create bitmap context\n", stderr)
  exit(1)
}

// Top-left origin so layout matches Finder icon coordinates.
ctx.translateBy(x: 0, y: CGFloat(height))
ctx.scaleBy(x: scale, y: -scale)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(red: r, green: g, blue: b, alpha: a)
}

// Warm paper → soft teal: classic Mac networking / AFP feel.
let top = rgb(0.96, 0.94, 0.90)
let bottom = rgb(0.82, 0.88, 0.86)
let ink = rgb(0.18, 0.22, 0.24)
let inkMuted = rgb(0.38, 0.42, 0.44)
let accent = rgb(0.10, 0.48, 0.52)

let colors = [top, bottom] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
  ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: logicalW, y: logicalH),
    options: []
  )
}

ctx.setFillColor(rgb(0.10, 0.48, 0.52, 0.04))
ctx.fill(CGRect(x: 0, y: 0, width: logicalW, height: logicalH))

// Arrow between icon centers (Finder y≈145).
let arrowY: CGFloat = 145
let arrowStartX: CGFloat = 250
let arrowEndX: CGFloat = 410
let head: CGFloat = 18

ctx.setStrokeColor(accent)
ctx.setFillColor(accent)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - head * 0.55, y: arrowY))
ctx.strokePath()

let tip = CGMutablePath()
tip.move(to: CGPoint(x: arrowEndX, y: arrowY))
tip.addLine(to: CGPoint(x: arrowEndX - head, y: arrowY - head * 0.7))
tip.addLine(to: CGPoint(x: arrowEndX - head, y: arrowY + head * 0.7))
tip.closeSubpath()
ctx.addPath(tip)
ctx.fillPath()

let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx

let para = NSMutableParagraphStyle()
para.alignment = .center

let caption = "Drag to Applications to install" as NSString
caption.draw(
  in: CGRect(x: 100, y: 262, width: 460, height: 28),
  withAttributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(cgColor: inkMuted) ?? .darkGray,
    .paragraphStyle: para,
  ]
)

let hint = "Then open ClassicAFP → enable File System Extensions" as NSString
hint.draw(
  in: CGRect(x: 60, y: 288, width: 540, height: 22),
  withAttributes: [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(cgColor: inkMuted) ?? .darkGray,
    .paragraphStyle: para,
  ]
)

let brand = "ClassicAFP" as NSString
brand.draw(
  in: CGRect(x: 180, y: 24, width: 300, height: 22),
  withAttributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
    .foregroundColor: NSColor(cgColor: ink) ?? .black,
    .paragraphStyle: para,
  ]
)

NSGraphicsContext.restoreGraphicsState()

guard let cgImage = ctx.makeImage() else {
  fputs("error: could not make image\n", stderr)
  exit(1)
}

let rep = NSBitmapImageRep(cgImage: cgImage)
rep.size = NSSize(width: logicalW, height: logicalH)
guard let data = rep.representation(using: .png, properties: [:]) else {
  fputs("error: could not encode PNG\n", stderr)
  exit(1)
}

do {
  try data.write(to: outURL, options: .atomic)
  fputs("wrote \(outURL.path) (\(width)×\(height))\n", stderr)
} catch {
  fputs("error: \(error)\n", stderr)
  exit(1)
}
