#!/usr/bin/env swift
// Self-authored installation artwork. Uses only macOS AppKit/Foundation, with
// no network access, external assets, Apple logos, or changes to the app icon.
// Invoke through scripts/package-dmg.sh to explicitly select XcodeDefault Swift.
// Standalone: xcrun --sdk macosx --toolchain com.apple.dt.toolchain.XcodeDefault swift
//            packaging/dmg-background.swift /absolute/background.tiff
// A multi-resolution TIFF keeps Finder's 680 x 440 point background sharp on
// Retina displays. Bitmap graphics contexts work without a window/login session.
import AppKit
import Foundation

let canvasSize = NSSize(width: 680, height: 440)

enum ArtworkError: Error {
    case invalidArguments
    case bitmapAllocation
    case imageEncoding
}

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

// Author layout in familiar top-left coordinates while AppKit draws bottom-up.
func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasSize.height - top - height, width: width, height: height)
}

func text(_ value: String, top: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, ink: NSColor,
          alignment: NSTextAlignment = .left, tracking: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink,
        .paragraphStyle: paragraph,
        .kern: tracking,
    ]
    (value as NSString).draw(in: rect(40, top, canvasSize.width - 80, size * 1.5),
                            withAttributes: attributes)
}

func drawArtwork() {
    let ink = color(0x202938)
    let muted = color(0x536274)
    let accent = color(0x366DD9)

    color(0xF4F6FA).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

    // A small accent and restrained typography frame the two native Finder icons.
    accent.setFill()
    NSBezierPath(roundedRect: rect(40, 28, 24, 3), xRadius: 1.5, yRadius: 1.5).fill()
    text("INSTALL", top: 19, size: 10, weight: .semibold, ink: muted,
         alignment: .right, tracking: 1.8)
    text("MachOView", top: 49, size: 32, weight: .semibold, ink: ink)
    text("Drag MachOView to Applications.", top: 96, size: 16, ink: muted)

    // The real app and Applications folder icons are positioned by .DS_Store;
    // these quiet panels deliberately contain no baked-in imitation icons.
    for x in [CGFloat(90), CGFloat(430)] {
        let panel = NSBezierPath(roundedRect: rect(x, 139, 160, 178),
                                 xRadius: 22, yRadius: 22)
        color(0xFFFFFF).setFill()
        panel.fill()
        color(0xE1E7F0).setStroke()
        panel.lineWidth = 1
        panel.stroke()
    }

    // A simple, original vector arrow joins the app to its destination.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 301, y: canvasSize.height - 208))
    arrow.line(to: NSPoint(x: 375, y: canvasSize.height - 208))
    arrow.move(to: NSPoint(x: 361, y: canvasSize.height - 194))
    arrow.line(to: NSPoint(x: 375, y: canvasSize.height - 208))
    arrow.line(to: NSPoint(x: 361, y: canvasSize.height - 222))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    accent.setStroke()
    arrow.stroke()

    color(0xDEE4EC).setFill()
    NSBezierPath(rect: rect(40, 349, 600, 1)).fill()
    text("Then open MachOView from Applications.", top: 369, size: 13,
         weight: .medium, ink: ink, alignment: .center)
    text("Eject this disk image when you're done.", top: 393, size: 12,
         ink: muted, alignment: .center)
}

func makeBackground() throws -> Data {
    let image = NSImage(size: canvasSize)
    for scale in [1, 2] {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width) * scale,
            pixelsHigh: Int(canvasSize.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ArtworkError.bitmapAllocation
        }
        bitmap.size = canvasSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawArtwork()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
    }
    guard let data = image.tiffRepresentation else { throw ArtworkError.imageEncoding }
    return data
}

do {
    guard CommandLine.arguments.count == 2,
          (CommandLine.arguments[1] as NSString).isAbsolutePath else {
        throw ArtworkError.invalidArguments
    }
    let destination = URL(fileURLWithPath: CommandLine.arguments[1])
    try makeBackground().write(to: destination, options: .withoutOverwriting)
} catch {
    let message = "error: Could not render DMG artwork: \(error)\nUsage: dmg-background.swift /absolute/background.tiff\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
