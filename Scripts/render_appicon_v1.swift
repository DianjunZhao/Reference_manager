#!/usr/bin/env swift
import AppKit
import Foundation

// Deterministic rasterizer for the editable AppIcon-master.svg composition.
// It deliberately uses only macOS system frameworks so the release workflow
// does not fetch assets or depend on an image service.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
// Keep the reviewable contact sheet beside the editable SVG master at the
// project root.  The catalog PNGs remain the only build resources.
let contactSheet = root.appendingPathComponent("AppIcon-contact-sheet.png")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func point(_ x: CGFloat, _ y: CGFloat, scale: CGFloat) -> NSPoint { .init(x: x * scale, y: y * scale) }

func icon(size: Int) -> NSImage {
    let image = NSImage(size: .init(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    let s = CGFloat(size) / 1024
    let rect = NSRect(x: 48 * s, y: 48 * s, width: 928 * s, height: 928 * s)
    let background = NSBezierPath(roundedRect: rect, xRadius: 205 * s, yRadius: 205 * s)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0x11/255, green: 0x1A/255, blue: 0x3A/255, alpha: 1), ending: NSColor(calibratedRed: 0x24/255, green: 0x58/255, blue: 0xA6/255, alpha: 1))!
    gradient.draw(in: background, angle: -45)
    let cyan = NSColor(calibratedRed: 0x45/255, green: 0xD7/255, blue: 0xE8/255, alpha: 1)
    let gold = NSColor(calibratedRed: 0xF5/255, green: 0xB9/255, blue: 0x4C/255, alpha: 1)
    let paper = NSColor(calibratedRed: 0xF7/255, green: 0xFA/255, blue: 0xFF/255, alpha: 1)
    let ink = NSColor(calibratedRed: 0x20/255, green: 0x32/255, blue: 0x5B/255, alpha: 1)
    let lattice = [[(210,292),(480,292)],[(210,512),(480,512)],[(210,732),(480,732)],[(210,292),(210,732)],[(345,292),(345,732)],[(480,292),(480,732)]]
    cyan.setStroke(); NSBezierPath.defaultLineCapStyle = .round
    for line in lattice { let p = NSBezierPath(); p.lineWidth = 24*s; p.move(to: point(CGFloat(line[0].0), CGFloat(line[0].1), scale:s)); p.line(to: point(CGFloat(line[1].0), CGFloat(line[1].1), scale:s)); p.stroke() }
    for x in [210,345,480] { for y in [292,512,732] { cyan.setFill(); NSBezierPath(ovalIn: NSRect(x: CGFloat(x)*s-31*s, y: CGFloat(y)*s-31*s, width: 62*s, height: 62*s)).fill() } }
    paper.setFill(); NSBezierPath(rect: NSRect(x: 541*s, y: 305*s, width: 294*s, height: 354*s)).fill()
    NSColor(calibratedWhite: 0.88, alpha: 1).setFill(); let fold = NSBezierPath(); fold.move(to: point(757,305,scale:s)); fold.line(to: point(835,383,scale:s)); fold.line(to: point(757,383,scale:s)); fold.close(); fold.fill()
    ink.setStroke(); for (index, width) in [176,176,122].enumerated() { let p = NSBezierPath(); p.lineWidth = 25*s; let y = CGFloat(471 + index * 74); p.move(to: point(600,y,scale:s)); p.line(to: point(CGFloat(600 + width),y,scale:s)); p.stroke() }
    gold.setStroke(); let lens = NSBezierPath(ovalIn: NSRect(x: (639-207)*s, y: (570-207)*s, width: 414*s, height: 414*s)); lens.lineWidth = 58*s; lens.stroke()
    let handle = NSBezierPath(); handle.lineWidth = 64*s; handle.move(to: point(785,716,scale:s)); handle.line(to: point(891,822,scale:s)); handle.stroke()
    image.isTemplate = false
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "LatticeLensIcon", code: 1) }
    try png.write(to: url, options: .atomic)
}

let assets: [(String, Int)] = [("appicon_16.png",16),("appicon_16@2x.png",32),("appicon_32@2x.png",64),("appicon_128.png",128),("appicon_128@2x.png",256),("appicon_256@2x.png",512),("appicon_512@2x.png",1024)]
// AppKit's TIFF bridge renders at the backing (2x) scale.  Draw at half the
// target pixel width so each catalog filename has exactly the documented
// physical dimensions and is never an upscale.
for (name, pixels) in assets { try writePNG(icon(size: pixels / 2), to: iconset.appendingPathComponent(name)) }
let sheet = NSImage(size: .init(width: 380, height: 90)); sheet.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0,y: 0,width: 380,height:90)).fill(); let sizes = [16,32,128,512]
for (index, size) in sizes.enumerated() { let preview = icon(size: max(8, size / 2)); let target = NSRect(x: CGFloat(index)*95 + 15, y: 8, width: 75, height: 75); preview.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }; sheet.unlockFocus(); try writePNG(sheet, to: contactSheet)
print("rendered \(assets.count) AppIcon PNG assets and contact sheet")
