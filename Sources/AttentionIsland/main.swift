import AppKit
import SwiftUI

struct Counts: Equatable { var running = 0, input = 0 }

final class Model: ObservableObject { @Published var counts = Counts() }

let sessionsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".attention-island/sessions")

// ponytail: age limits stand in for process liveness, so a crashed agent lingers until its entry ages out.
// Upgrade path: record the agent pid in hook.py and check it here.
func readCounts(now: Date = Date()) -> Counts {
    var counts = Counts()
    let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
    for url in files where url.pathExtension == "json" {
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = entry["state"] as? String, let at = entry["at"] as? Double else { continue }
        let age = now.timeIntervalSince1970 - at
        if state == "running", age < 30 * 60 { counts.running += 1 }
        if state == "input", age < 12 * 3600 { counts.input += 1 }
    }
    return counts
}

struct IslandView: View {
    @ObservedObject var model: Model
    let gap: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            wing(model.counts.running, color: .green)
            Color.clear.frame(width: gap)
            wing(model.counts.input, color: .orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
    }

    private func wing(_ count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .opacity(count == 0 ? 0.35 : 1)
        .frame(maxWidth: .infinity)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        place()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.place() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Wraps the notch on the built-in screen; without a notch it sits centred on the menu bar.
    func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        var gap: CGFloat = 12, height = NSStatusBar.system.thickness
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            gap = screen.frame.width - left.width - right.width
            height = screen.safeAreaInsets.top
        }
        let width = gap + 2 * 52
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
        panel.contentView = NSHostingView(rootView: IslandView(model: model, gap: gap))
    }

    func refresh() {
        let counts = readCounts()
        if counts != model.counts { model.counts = counts }
        if counts.running + counts.input == 0 { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
