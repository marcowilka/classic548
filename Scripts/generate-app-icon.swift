#!/usr/bin/env swift
import AppKit
import Foundation

/// Scale source to 1024×1024 and apply rounded corners
/// (radius = 0.22 × side, 4× supersampled mask).

guard CommandLine.arguments.count >= 3 else {
  fputs("usage: generate-app-icon.swift <src.png> <out-1024.png>\n", stderr)
  exit(1)
}

let srcPath = CommandLine.arguments[1]
let dstPath = CommandLine.arguments[2]
guard let img = NSImage(contentsOf: URL(fileURLWithPath: srcPath)),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  fputs("error: could not load \(srcPath)\n", stderr)
  exit(1)
}

let outSize = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let squareCtx = CGContext(
  data: nil,
  width: outSize,
  height: outSize,
  bitsPerComponent: 8,
  bytesPerRow: 0,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  fputs("error: square context\n", stderr)
  exit(1)
}
squareCtx.interpolationQuality = .high
squareCtx.clear(CGRect(x: 0, y: 0, width: outSize, height: outSize))
squareCtx.draw(cg, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))
guard let square = squareCtx.makeImage() else {
  fputs("error: square image\n", stderr)
  exit(1)
}

let radius = CGFloat(outSize) * 0.22
let scale = 4
let maskW = outSize * scale
let maskH = outSize * scale
guard let maskCtx = CGContext(
  data: nil,
  width: maskW,
  height: maskH,
  bitsPerComponent: 8,
  bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceGray(),
  bitmapInfo: CGImageAlphaInfo.none.rawValue
) else {
  fputs("error: mask context\n", stderr)
  exit(1)
}
maskCtx.setFillColor(gray: 0, alpha: 1)
maskCtx.fill(CGRect(x: 0, y: 0, width: maskW, height: maskH))
maskCtx.setFillColor(gray: 1, alpha: 1)
let maskPath = CGPath(
  roundedRect: CGRect(x: 0, y: 0, width: maskW, height: maskH),
  cornerWidth: radius * CGFloat(scale),
  cornerHeight: radius * CGFloat(scale),
  transform: nil
)
maskCtx.addPath(maskPath)
maskCtx.fillPath()
guard let maskHi = maskCtx.makeImage() else {
  fputs("error: mask image\n", stderr)
  exit(1)
}

guard let outCtx = CGContext(
  data: nil,
  width: outSize,
  height: outSize,
  bitsPerComponent: 8,
  bytesPerRow: 0,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  fputs("error: out context\n", stderr)
  exit(1)
}
outCtx.interpolationQuality = .high
outCtx.clear(CGRect(x: 0, y: 0, width: outSize, height: outSize))
outCtx.saveGState()
outCtx.clip(to: CGRect(x: 0, y: 0, width: outSize, height: outSize), mask: maskHi)
outCtx.draw(square, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))
outCtx.restoreGState()

guard let result = outCtx.makeImage() else {
  fputs("error: makeImage\n", stderr)
  exit(1)
}

let rep = NSBitmapImageRep(cgImage: result)
rep.size = NSSize(width: outSize, height: outSize)
guard let data = rep.representation(using: .png, properties: [:]) else {
  fputs("error: encode PNG\n", stderr)
  exit(1)
}
try data.write(to: URL(fileURLWithPath: dstPath), options: .atomic)
fputs("wrote \(dstPath) (\(outSize)×\(outSize), corner radius \(Int(radius)))\n", stderr)
