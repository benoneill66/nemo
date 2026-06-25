#!/usr/bin/env swift
// Generates AppIcon.icns for Nemo — a glassmorphic blue→purple squircle with a
// white "ear" glyph (matching the menu-bar symbol). Reproducible: run `swift make-icon.swift`.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// Continuous rounded-rect (squircle-ish) background, inset like Big Sur icons.
let inset: CGFloat = size * 0.10
let rect = NSRect(x: inset, y: inset, width: size - inset*2, height: size - inset*2)
let radius = rect.width * 0.2237
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
path.addClip()

// Blue → purple gradient (app palette: hue 0.60 → 0.74).
let g = NSGradient(colors: [
    NSColor(hue: 0.62, saturation: 0.70, brightness: 0.95, alpha: 1),
    NSColor(hue: 0.74, saturation: 0.72, brightness: 0.62, alpha: 1),
])!
g.draw(in: rect, angle: -90)

// Soft top highlight for a glassy sheen.
ctx.saveGState()
let sheen = NSGradient(colors: [
    NSColor(white: 1, alpha: 0.28),
    NSColor(white: 1, alpha: 0.0),
])!
sheen.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2), angle: -90)
ctx.restoreGState()

// White "ear" glyph, centered, with a drop shadow.
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
if let sym = NSImage(systemSymbolName: "ear", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let glyph = NSImage(size: NSSize(width: size*0.5, height: size*0.5))
    glyph.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: glyph.size)
    sym.draw(in: r)
    r.fill(using: .sourceAtop)   // tint the template symbol white
    glyph.unlockFocus()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()

    let gw = size * 0.46, gh = size * 0.46
    glyph.draw(in: NSRect(x: (size-gw)/2, y: (size-gh)/2, width: gw, height: gh))
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: "icon-1024.png"))
print("✓ wrote icon-1024.png")
