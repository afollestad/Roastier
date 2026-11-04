import AppKit
import CaffeinateKit
import SwiftUI

/// Owns the menu bar status item and the anchored popover it toggles.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    /// Must match the imagesets in `Resources/Assets.xcassets`.
    static let activeImageName = "CoffeeMenuBarActive"
    static let idleImageName = "CoffeeMenuBarIdleTemplate"

    private let launchAtLogin: LaunchAtLogin
    private let updates: AppUpdateManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var iconTask: Task<Void, Never>?

    init(awake: AwakeController, launchAtLogin: LaunchAtLogin, updates: AppUpdateManager) {
        self.launchAtLogin = launchAtLogin
        self.updates = updates
        super.init()

        let hostingController = NSHostingController(
            rootView: PopoverView(awake: awake, launchAtLogin: launchAtLogin, updates: updates)
        )
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("Caffeinate")
        }
        updateIcon(StatusItemIcon(isActive: awake.isActive, badge: updates.badge))
        iconTask = Task { [weak self] in
            for await icon in Observations({ StatusItemIcon(isActive: awake.isActive, badge: updates.badge) }) {
                self?.updateIcon(icon)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        updates.dismissManualCheckFeedback()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        launchAtLogin.refresh()
        // The popover's window can only become key once the app is active; until then its controls render dimmed.
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        sender.highlight(true)
    }

    private func updateIcon(_ icon: StatusItemIcon) {
        guard let button = statusItem.button else {
            return
        }
        let image = icon.image()
        button.image = image
        // Offers a template copy for the highlighted state, so macOS can tint the colored icons there.
        let highlightedImage = image?.copy() as? NSImage
        highlightedImage?.isTemplate = true
        button.alternateImage = highlightedImage
        button.setAccessibilityValue(icon.accessibilityValue)
        button.toolTip = icon.toolTip
    }
}
