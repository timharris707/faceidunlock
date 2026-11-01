import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// The small bar at the top of the screen while a password box is open. Shows no video, floats above
/// password boxes and never takes keyboard focus from them. During the glance it shows on every screen.
@MainActor
final class StatusBarPanel {
    private let panel: NSPanel
    private var visible = false
    private var subscription: AnyCancellable?
    /// The glance's bar on each other screen, while it asks.
    private var copies: [NSPanel] = []
    private var glanceSubscription: AnyCancellable?

    init(controller: AppController) {
        panel = Self.makePanel(controller)
        subscription = controller.$bar.map { $0 != nil }.removeDuplicates().sink { [weak self, weak controller] show in
            if show { self?.show(near: controller?.dialog?.window) } else { self?.hide() }
        }
        // The person faces the camera, which may sit on another screen than the box; turning to read the bar
        // there would itself be a turn, the wrong way half the time. The glance is the only animated bar.
        // Delivered once the new bar is in place, so the copies start with it.
        glanceSubscription = controller.$bar.map { $0?.animated == true }.removeDuplicates()
            .receive(on: DispatchQueue.main).sink { [weak self, weak controller] glancing in
                MainActor.assumeIsolated {
                    if glancing, let controller { self?.showCopies(controller) } else { self?.hideCopies() }
                }
            }
    }

    private static func makePanel(_ controller: AppController) -> NSPanel {
        let panel = NonActivatingPanel(contentRect: NSRect(x: 0, y: 0, width: StatusBarView.width, height: StatusBarView.height),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Password boxes from coreautha sit at window layer 1000.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = FirstClickHostingView(rootView: StatusBarView(controller: controller))
        return panel
    }

    /// A copy of the bar at the top of every screen but the one the bar is on.
    private func showCopies(_ controller: AppController) {
        for screen in NSScreen.screens where !screen.frame.intersects(panel.frame) {
            let copy = Self.makePanel(controller), area = screen.visibleFrame
            copy.setFrameOrigin(NSPoint(x: area.midX - copy.frame.width / 2, y: area.maxY - copy.frame.height - 12))
            copy.orderFrontRegardless()
            copies.append(copy)
        }
    }

    private func hideCopies() {
        copies.forEach { $0.orderOut(nil) }
        copies = []
    }

    private func show(near window: AXUIElement?) {
        let screen = window.flatMap(Self.screen(showing:)) ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        // Slides down 8 pt as it fades in; with Reduce Motion it only fades.
        let frame = NSRect(origin: NSPoint(x: area.midX - panel.frame.width / 2, y: area.maxY - panel.frame.height - 12),
                           size: panel.frame.size)
        let slides = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(slides ? frame.offsetBy(dx: 0, dy: 8) : frame, display: false)
        visible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if slides { panel.animator().setFrame(frame, display: true) }
        }
    }

    private func hide() {
        visible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// The screen holding the centre of the password box, from its Accessibility frame (top-left origin).
    private static func screen(showing window: AXUIElement) -> NSScreen? {
        var position: CFTypeRef?, size: CFTypeRef?
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              let primary = NSScreen.screens.first else { return nil }
        let center = NSPoint(x: origin.x + extent.width / 2, y: primary.frame.maxY - origin.y - extent.height / 2)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }
}

/// Never becomes key or main, so the password box keeps keyboard focus.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the bar's button work on the first click while another app is active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct StatusBarView: View {
    static let width: CGFloat = 400, height: CGFloat = 60
    @ObservedObject var controller: AppController
    /// Liquid Glass where the system has it. Offscreen renders turn it off, as glass draws blank without a window.
    var glass = true
    /// Keeps the last content on screen while the bar fades out.
    @State private var shown: StatusBarContent?
    /// Whether the bar is up, so only a bar already on screen crossfades to new content.
    @State private var showing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 12) {
            if let shown {
                // Filled symbols throughout, whatever the name; "Looking for you…" and the glance arrow pulse.
                Image(systemName: shown.symbol)
                    .font(.system(size: 22)).symbolVariant(.fill)
                    .foregroundStyle(shown.tint.color).frame(width: 30)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating,
                                  isActive: (shown.animated || shown.symbol == "person.crop.circle") && !reduceMotion)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shown.text).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    if let detail = shown.detail {
                        // The bar's own words wrap rather than cut off.
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let requester = shown.requester {
                        // Alone, middle truncation keeps the end, which often names the app asking; beside a
                        // button, the start reads better.
                        Text(requester).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(shown.action == nil ? .middle : .tail)
                    }
                }
                .contentTransition(.opacity)
                Spacer(minLength: 0)
                if let action = shown.action {
                    Button(action.title) { controller.perform(action) }.buttonBorderShape(.capsule)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, shown?.action == nil ? 14 : 10)
        .frame(width: Self.width, height: Self.height)
        .barBackground(shape, glass: glass)
        .overlay {
            if contrast == .increased { shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1) }
        }
        .onReceive(controller.$bar) { content in
            // A bar fading in shows its own content at once, never the last box's message underneath.
            if let content { withAnimation(showing ? .easeInOut(duration: 0.2) : nil) { shown = content } }
            showing = content != nil
        }
    }
}

private extension View {
    /// Liquid Glass on macOS 26 and later, like the system's own floating panels; a material before that.
    @ViewBuilder func barBackground(_ shape: some Shape, glass: Bool) -> some View {
        if #available(macOS 26, *), glass {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

private extension StatusBarContent.Tint {
    var color: Color {
        switch self {
        case .green: return .green
        case .blue: return .blue
        case .orange: return .orange
        }
    }
}
