import AppKit
import XCTest

@testable import AgentActivity

@MainActor
final class MenuBarControllerTests: XCTestCase {
  func testStatusItemEventRouting() {
    XCTAssertEqual(MenuBarController.action(for: .leftMouseUp), .togglePopover)
    XCTAssertEqual(MenuBarController.action(for: .rightMouseUp), .showQuitMenu)
    XCTAssertEqual(MenuBarController.action(for: nil), .togglePopover)
  }

  func testQuitMenuConstruction() throws {
    let controller = MenuBarController(store: ActivityStore(loadsLiveData: false))

    let menu = controller.makeQuitMenu()

    XCTAssertEqual(menu.items.count, 1)
    let item = try XCTUnwrap(menu.items.first)
    XCTAssertEqual(item.title, "Quit AgentActivity")
    XCTAssertEqual(item.keyEquivalent, "q")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    XCTAssertEqual(item.action, #selector(MenuBarController.quitApplication(_:)))
    XCTAssertTrue(item.target === controller)
  }
}
