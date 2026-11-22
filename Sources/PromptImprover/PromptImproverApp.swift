import SwiftUI
import AppKit

@main
struct PromptImproverApp: App {
    @StateObject private var store = EndpointStore()
    @StateObject private var vm = ImproverViewModel()
    @StateObject private var profiles = ProfileStore()

    init() {
        // Build-time hook: `PromptImprover --render-icon <dir.iconset>` renders the logo and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            IconRenderer.render(iconset: args[i + 1])
            exit(0)
        }
        LoginItem.enableOnFirstLaunch()
    }

    var body: some Scene {
        // Menu bar only (LSUIElement in Info.plist hides the Dock icon).
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
                .environmentObject(vm)
                .environmentObject(profiles)
        } label: {
            Image(nsImage: MenuBarIcon.image(busy: vm.isBusy))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store).environmentObject(profiles)
        }
    }
}

/// The logo reduced to a monochrome 18pt template glyph, so macOS tints it for light/dark menu bars.
enum MenuBarIcon {
    private static let idle = make(busy: false)
    private static let working = make(busy: true)

    static func image(busy: Bool) -> NSImage { busy ? working : idle }

    private static func make(busy: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()

            let chevron = NSBezierPath()
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 2.5, y: 6.5))
            chevron.line(to: NSPoint(x: 7.5, y: 10.75))
            chevron.line(to: NSPoint(x: 2.5, y: 15))
            chevron.stroke()

            NSBezierPath(roundedRect: NSRect(x: 9.5, y: 14, width: 5.5, height: 2), xRadius: 1, yRadius: 1).fill()

            // Spark: bigger while the model is working.
            let c = NSPoint(x: 13.5, y: 5)
            let r: CGFloat = busy ? 5 : 4.2
            let spark = NSBezierPath()
            spark.move(to: NSPoint(x: c.x, y: c.y - r))
            for p in [NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y + r),
                      NSPoint(x: c.x - r, y: c.y), NSPoint(x: c.x, y: c.y - r)] {
                spark.curve(to: p, controlPoint1: c, controlPoint2: c)
            }
            spark.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
