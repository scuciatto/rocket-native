import SwiftUI
import AppKit

// Fuselage design tokens (RocketChat/fuselage packages/fuselage-tokens),
// mapped to the app's chrome/content split: Liquid Glass owns the chrome,
// these tokens own the content layer.

/// Appearance-dynamic color without an asset catalog: the app bundle is
/// hand-assembled by the Makefile (CLT-only machine, no actool), so tokens
/// resolve through NSColor's dynamic provider instead of a compiled .car.
private func rcDynamic(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(rcHex: dark)
            : NSColor(rcHex: light)
    })
}

private func rcFixed(_ hex: UInt32) -> Color {
    Color(nsColor: NSColor(rcHex: hex))
}

private extension NSColor {
    convenience init(rcHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Color {
    // Brand (fixed in both appearances, per Fuselage button tokens)
    static let rcPrimary = rcFixed(0x1D74F5)
    static let rcDanger = rcFixed(0xF5455C)

    // Surfaces
    static let rcSurfaceLight = rcDynamic(light: 0xFFFFFF, dark: 0x262931)
    static let rcSurfaceTint = rcDynamic(light: 0xF7F8FA, dark: 0x1F2329)
    static let rcSurfaceNeutral = rcDynamic(light: 0xE4E7EA, dark: 0x2D3039)
    static let rcSurfaceHover = rcDynamic(light: 0xF2F3F5, dark: 0x1A1E23)
    static let rcSurfaceSelected = rcDynamic(light: 0xD7DBE0, dark: 0x4C5362)

    // Fonts
    static let rcFontDefault = rcDynamic(light: 0x2F343D, dark: 0xC1C7D0)
    static let rcFontTitlesLabels = rcDynamic(light: 0x1F2329, dark: 0xF2F3F5)
    static let rcFontSecondaryInfo = rcDynamic(light: 0x6C727A, dark: 0x9EA2A8)
    static let rcFontAnnotation = rcFixed(0x9EA2A8)
    static let rcFontInfo = rcDynamic(light: 0x1D74F5, dark: 0x6292DA)

    // Strokes
    static let rcStrokeExtraLight = rcDynamic(light: 0xEBECEF, dark: 0x333842)
    static let rcStrokeLight = rcDynamic(light: 0xCBCED1, dark: 0x404754)
    static let rcStrokeHighlight = rcDynamic(light: 0x1D74F5, dark: 0x6292DA)
    static let rcShadowHighlight = rcDynamic(light: 0xD1EBFE, dark: 0x1D74F5)

    // Status
    static let rcStatusWarning = rcDynamic(light: 0xB68D00, dark: 0xFFD031)

    // Badges (Fuselage unread variants: mention / thread / group / plain)
    static let rcBadgeMention = rcDynamic(light: 0xF5455C, dark: 0xB43C4C)
    static let rcBadgeThread = rcDynamic(light: 0x1D74F5, dark: 0x2C65BA)
    static let rcBadgeGroupMention = rcDynamic(light: 0xF38C39, dark: 0x955828)
    static let rcBadgePlain = rcDynamic(light: 0x6C727A, dark: 0x484C51)
}

extension Font {
    static let rcBody = Font.system(size: 14)                     // p2
    static let rcSenderName = Font.system(size: 14, weight: .bold) // h5
    static let rcTimestamp = Font.system(size: 12)                 // c1
    static let rcCaption = Font.system(size: 12)                   // c1
    static let rcCaptionBold = Font.system(size: 12, weight: .semibold) // c2
    static let rcMono = Font.system(size: 13, design: .monospaced)
}

enum RCRadius {
    static let small: CGFloat = 2
    static let medium: CGFloat = 4
    static let large: CGFloat = 8
}

enum RCSpace {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x5: CGFloat = 20
}
