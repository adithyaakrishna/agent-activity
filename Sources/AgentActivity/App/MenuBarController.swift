import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
  private let popoverSize = NSSize(width: 560, height: 298)
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private let store: ActivityStore

  init(store: ActivityStore) {
    self.store = store
    super.init()
  }

  func install() {
    guard let button = statusItem.button else { return }

    button.image = NSImage(
      systemSymbolName: "square.grid.3x3.fill",
      accessibilityDescription: "Agent Activity"
    )
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(togglePopover(_:))
    button.sendAction(on: [.leftMouseUp])
    button.setAccessibilityLabel("Agent Activity")

    let hostingController = NSHostingController(
      rootView: ActivityPopoverView(store: store)
    )
    hostingController.view.frame = NSRect(origin: .zero, size: popoverSize)
    hostingController.view.setFrameSize(popoverSize)

    popover.behavior = .transient
    popover.animates = false
    popover.contentSize = popoverSize
    popover.contentViewController = hostingController
  }

  @objc
  private func togglePopover(_ sender: Any?) {
    guard let button = statusItem.button else { return }

    if popover.isShown {
      popover.performClose(sender)
      return
    }

    // Establish the final size before AppKit publishes the first visible frame.
    popover.contentSize = popoverSize
    popover.contentViewController?.view.setFrameSize(popoverSize)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  deinit {
    NSStatusBar.system.removeStatusItem(statusItem)
  }
}
