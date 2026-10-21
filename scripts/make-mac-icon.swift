#!/usr/bin/env swift
// Renders the Mac app icon slots from the iPhone icon (spec 009 section 6.15, amendment 0.2 item 15).
//
//   swift scripts/make-mac-icon.swift
//
// The iPhone icon is a full-bleed square that iOS masks itself. A Mac icon is its own rounded-square
// tile with a transparent margin and a soft shadow, so this draws the same art into that tile at the
// five Mac sizes, each at 1x and 2x, next to the iPhone images in AppIcon.appiconset, and writes the
// matching "mac" entries into its Contents.json.
//
// This is a PLACEHOLDER built from existing art. The redrawn Mac mark is an asset task and needs the
// owner's sign-off. Run it again after the art changes; it is deterministic.

import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appending(path: "iclean/Resources/Assets.xcassets/AppIcon.appiconset")
let source = set.appending(path: "icon.png")

guard let art = NSImage(contentsOf: source),
    let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("Cannot read \(source.path)\n".utf8))
    exit(1)
}

/// The tile is 824 of 1024 points: Apple's grid leaves about 10% on every side for the shadow.
let tileFraction: CGFloat = 824.0 / 1024.0
/// Continuous-corner approximation: the corner radius is 22.37% of the tile.
let cornerFraction: CGFloat = 0.2237

func render(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard
        let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high

    let tileSide = size * tileFraction
    let tile = CGRect(
        x: (size - tileSide) / 2, y: (size - tileSide) / 2, width: tileSide, height: tileSide)
    let radius = tileSide * cornerFraction
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // The soft shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.025,
        color: CGColor(gray: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // The art, clipped to the tile.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(cg, in: tile)
    ctx.restoreGState()

    // A hairline of light along the edge, as system icons have.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(max(size / 512, 0.5))
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

struct Slot {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { "icon_mac_\(points)x\(points)@\(scale)x.png" }
}

let slots = [16, 32, 128, 256, 512].flatMap {
    [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)]
}

for slot in slots {
    guard let png = render(pixels: slot.pixels) else {
        FileHandle.standardError.write(Data("Cannot render \(slot.filename)\n".utf8))
        exit(1)
    }
    try png.write(to: set.appending(path: slot.filename))
    print("wrote \(slot.filename) (\(slot.pixels) px)")
}

// Contents.json: keep every non-Mac entry exactly as it is, and put the Mac ones after them.
let contentsURL = set.appending(path: "Contents.json")
var contents =
    try JSONSerialization.jsonObject(with: Data(contentsOf: contentsURL)) as! [String: Any]
var images = (contents["images"] as! [[String: Any]]).filter { ($0["idiom"] as? String) != "mac" }
for slot in slots {
    images.append([
        "filename": slot.filename, "idiom": "mac", "scale": "\(slot.scale)x",
        "size": "\(slot.points)x\(slot.points)",
    ])
}
contents["images"] = images
let data = try JSONSerialization.data(
    withJSONObject: contents, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try data.write(to: contentsURL)
print("updated Contents.json")
