import AppKit
import CaffeinateKit

/// The status item's look for one awake and update state.
struct StatusItemIcon: Equatable, Sendable {
    /// Clears the right-hand steam curve, which ends near x = 12.7 on the 18 pt canvas.
    private static let badgeDiameter: CGFloat = 4.5

    let isActive: Bool
    let badge: AppUpdateBadge

    @MainActor
    func image() -> NSImage? {
        guard let base = baseImage() else {
            return nil
        }
        guard let badgeColor else {
            return base
        }
        return badged(base, color: badgeColor)
    }

    var accessibilityValue: String {
        let awakeState = isActive ? "Stay awake on" : "Stay awake off"
        guard let badgeDescription else {
            return awakeState
        }
        return "\(awakeState), \(badgeDescription)"
    }

    var toolTip: String {
        guard let badgeDescription else {
            return "Caffeinate"
        }
        return "Caffeinate (\(badgeDescription))"
    }
}

private extension StatusItemIcon {
    var badgeColor: NSColor? {
        switch badge {
        case .none:
            nil
        case .updateAvailable:
            // Not `controlAccentColor`: a graphite or app-tinted accent would hide the dot against the menu bar.
            .systemBlue
        case .readyToInstall:
            .systemGreen
        }
    }

    var badgeDescription: String? {
        switch badge {
        case .none:
            nil
        case .updateAvailable:
            "update available"
        case .readyToInstall:
            "update ready to install"
        }
    }

    @MainActor
    func baseImage() -> NSImage? {
        if let named = NSImage(named: isActive ? StatusItemController.activeImageName : StatusItemController.idleImageName) {
            // The active icon keeps its own teal/mint colors; macOS tints the idle one.
            named.isTemplate = !isActive
            return named
        }
        // Covers unbundled runs (`swift run`), where the asset catalog is absent; symbols are templates.
        return NSImage(systemSymbolName: isActive ? "cup.and.heat.waves.fill" : "cup.and.heat.waves", accessibilityDescription: nil)
    }

    /// A template image can't carry a colored dot, so the badged image is not a template. It tints the idle glyph
    /// with `labelColor` itself; the drawing handler runs at draw time, so that color and the active icon's asset
    /// variant follow the menu bar's current appearance.
    @MainActor
    func badged(_ base: NSImage, color: NSColor) -> NSImage {
        let tintsBase = base.isTemplate
        let image = NSImage(size: base.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            // A transparency layer keeps the tint from compositing onto whatever is already drawn beneath the icon.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            base.draw(in: rect)
            if tintsBase {
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: rect.maxX - Self.badgeDiameter,
                y: rect.maxY - Self.badgeDiameter,
                width: Self.badgeDiameter,
                height: Self.badgeDiameter
            )).fill()
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = false
        return image
    }
}
