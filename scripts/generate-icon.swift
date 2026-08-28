#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = CommandLine.arguments
let sourcePath = arguments.count > 1 ? arguments[1] : "assets/icon.svg"
let outputPath = arguments.count > 2 ? arguments[2] : "assets/icon.png"
let side = 1024

let sourceURL = URL(fileURLWithPath: sourcePath)
let outputURL = URL(fileURLWithPath: outputPath)
guard let image = NSImage(contentsOf: sourceURL) else {
    fputs("Could not load SVG source at \(sourcePath)\n", stderr)
    exit(1)
}
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not allocate icon bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create icon graphics context\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()
image.draw(
    in: NSRect(x: 0, y: 0, width: side, height: side),
    from: .zero,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode icon PNG\n", stderr)
    exit(1)
}
do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    fputs("Could not write \(outputPath): \(error)\n", stderr)
    exit(1)
}
print("Rendered \(sourcePath) -> \(outputPath) (\(side)x\(side))")
