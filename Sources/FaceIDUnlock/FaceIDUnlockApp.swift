import AppKit
import Combine
import SwiftUI

@main
struct FaceIDUnlockMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = AppDelegate.mainMenu()
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// A menu bar app: the menu, the Settings window, the status bar and the hidden Home Test window. Opens
/// Settings at launch until set up.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let controller = AppController()
    private var statusItem: NSStatusItem?
    private var statusBar: StatusBarPanel?
    private var settingsWindow: NSWindow?
    private var homeTestWindow: NSWindow?
    private var iconDimming: AnyCancellable?

    /// The lens-and-keyhole glyph drawn for the menu bar (docs/design/icon/menubar.svg), shown as a template so it
    /// follows the menu bar's colour. A build without the app bundle falls back to a system symbol.
    private static func menuBarIcon() -> NSImage? {
        guard let icon = Bundle.main.image(forResource: "MenuBarIcon") else {
            return NSImage(systemSymbolName: "person.crop.circle.badge.checkmark", accessibilityDescription: "Face ID Unlock")
        }
        icon.size = NSSize(width: 18, height: 18)
        icon.isTemplate = true
        icon.accessibilityDescription = "Face ID Unlock"
        return icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        // The glyph dims while face unlock is off, as inactive menu bar items do.
        iconDimming = controller.$paused.combineLatest(controller.$lockout).sink { [weak item] paused, lockout in
            item?.button?.appearsDisabled = paused || lockout != nil
        }
        statusBar = StatusBarPanel(controller: controller)
        controller.openSettings = { [weak self] in self?.openSettings() }
        Task {
            await controller.launch()
            if controller.statusText != "Ready" { openSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { controller.quit() }

    /// With no Dock icon, opening the app again is the way back to Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// Rebuilt each time it opens; holding Option adds the extras.
    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.refreshPermissions()
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item(controller.pauseItemTitle, #selector(pauseItemChosen)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        if NSEvent.modifierFlags.contains(.option) {
            menu.addItem(.separator())
            menu.addItem(item("Show Score Log", #selector(showScoreLog)))
            menu.addItem(item("Home Test…", #selector(showHomeTest)))
            menu.addItem(item("Forget My Face", #selector(forgetFace)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SetupView(controller: controller, camera: controller.camera)))
            // The title stays for VoiceOver and Mission Control; the header in the window shows the name.
            window.title = "Face ID Unlock"
            window.styleMask = [.titled, .closable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The hidden Home Test (decision L5). A new window always starts by asking for the Mac password.
    func openHomeTest() {
        if homeTestWindow == nil {
            controller.lockHomeTest()
            let view = HomeTestView(controller: controller) { [weak self] in self?.homeTestWindow?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Home Test"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            homeTestWindow = window
        }
        NSApp.activate()
        homeTestWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === homeTestWindow {
            controller.lockHomeTest()
            homeTestWindow = nil
            return
        }
        controller.settingsClosed()
        settingsWindow = nil
    }

    /// Settings grows downward when face setup starts; this moves it up so the ring and Cancel stay above the Dock.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow,
              let area = window.screen?.visibleFrame else { return }
        let y = min(max(window.frame.minY, area.minY), area.maxY - window.frame.height)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: y))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func pauseItemChosen() { controller.pauseItemChosen() }
    @objc private func showSettings() { openSettings() }
    @objc private func showScoreLog() { controller.showScoreLog() }
    @objc private func showHomeTest() { openHomeTest() }
    @objc private func forgetFace() { controller.forgetFace() }

    /// Quit, Close and the Edit commands, so Command-V works in the password field of a menu bar app.
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Face ID Unlock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for submenu in [appMenu, fileMenu, editMenu] {
            let holder = NSMenuItem()
            holder.submenu = submenu
            main.addItem(holder)
        }
        return main
    }
}
