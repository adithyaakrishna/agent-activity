import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
  enum StatusItemAction {
    case togglePopover
    case showQuitMenu
  }

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
    button.action = #selector(handleStatusItemAction(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

  static func action(for eventType: NSEvent.EventType?) -> StatusItemAction {
    eventType == .rightMouseUp ? .showQuitMenu : .togglePopover
  }

  func makeQuitMenu() -> NSMenu {
    let menu = NSMenu()
    let quitItem = NSMenuItem(
      title: "Quit AgentActivity",
      action: #selector(quitApplication(_:)),
      keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    quitItem.target = self
    menu.addItem(quitItem)
    return menu
  }

  @objc
  func quitApplication(_ sender: Any?) {
    NSApplication.shared.terminate(sender)
  }

  @objc
  private func handleStatusItemAction(_ sender: Any?) {
    switch Self.action(for: NSApplication.shared.currentEvent?.type) {
    case .togglePopover:
      togglePopover(sender)
    case .showQuitMenu:
      showQuitMenu(sender)
    }
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

  private func showQuitMenu(_ sender: Any?) {
    if popover.isShown {
      popover.performClose(sender)
    }

    guard let button = statusItem.button else { return }
    makeQuitMenu().popUp(
      positioning: nil,
      at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
      in: button
    )
  }

  deinit {
    NSStatusBar.system.removeStatusItem(statusItem)
  }
}
