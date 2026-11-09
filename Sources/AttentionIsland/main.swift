import AppKit
import Combine
import SwiftUI

enum Palette {
    static let green = Color(red: 0.36, green: 0.86, blue: 0.56)
    static let orange = Color(red: 1.0, green: 0.68, blue: 0.26)
    static let blue = Color(red: 0.47, green: 0.62, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let surface = Color(white: 0.045)
    static let rim = Color.white.opacity(0.09)
    static let secondary = Color.white.opacity(0.5)
}

enum Layout {
    static let wing: CGFloat = 84, ear: CGFloat = 6, expandedWidth: CGFloat = 400, maxRows = 6
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.84)
}

extension Session {
    var approval: Bool { detail.hasPrefix("Needs approval") }
    var tint: Color {
        switch state {
        case .input: Palette.orange
        case .done: failed ? Palette.red : Palette.blue
        case .running: Palette.green
        }
    }
    var symbol: String {
        switch state {
        case .input: approval ? "hand.raised" : "questionmark.bubble"
        case .done: failed ? "exclamationmark.triangle" : "arrowshape.turn.up.left"
        case .running: ""
        }
    }
    var status: String {
        switch state {
        case .input: approval ? "Approval needed" : "Question"
        case .done: failed ? "Error" : "Your turn"
        case .running: "Working"
        }
    }
    var summary: String {
        let raw = switch state {
        case .input: detail.replacingOccurrences(of: #"^(Needs approval|Asking) · "#, with: "", options: .regularExpression)
        case .done: detail
        case .running: prompt.hasPrefix("<") ? "" : prompt  // app-injected events, not something I typed
        }
        return plain(raw)
    }
}

/// Last turns are markdown; the island shows them as plain text.
func plain(_ text: String) -> String {
    text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\*\*|__|`|(^|\s)#+\s"#, with: "$1", options: .regularExpression)
}

final class Model: ObservableObject {
    /// Shown sessions: everything read from disk minus what I dismissed.
    @Published private(set) var sessions: [Session] = []
    @Published var hovering = false
    var islandSize = CGSize.zero
    private var all: [Session] = []
    /// "<id>@<since>": a dismissal covers one state only, so the next turn or approval brings it back.
    private var dismissed = Set(UserDefaults.standard.stringArray(forKey: "dismissed") ?? [])

    private func key(_ s: Session) -> String { "\(s.id)@\(s.since.timeIntervalSince1970)" }

    func update(_ sessions: [Session]) {
        all = sessions
        dismissed.formIntersection(sessions.map(key))  // forget dismissals whose state has moved on
        UserDefaults.standard.set(Array(dismissed), forKey: "dismissed")
        let shown = all.filter { !dismissed.contains(key($0)) }
        if shown != self.sessions { self.sessions = shown }
    }

    func dismiss(_ session: Session) {
        dismissed.insert(key(session))
        update(all)
    }
    var running: [Session] { sessions.filter { !$0.waiting } }
    var waiting: [Session] { sessions.filter(\.waiting) }
    var waitingTint: Color { waiting.contains { $0.state == .input } ? Palette.orange : Palette.blue }
}

/// Black island whose top corners flare into the screen edge like the notch's own.
struct IslandShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }

    func path(in r: CGRect) -> Path {
        let e = Layout.ear, b = min(radius, (r.height - e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.minX + e, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: b)
        p.addArc(tangent1End: CGPoint(x: r.maxX - e, y: r.maxY), tangent2End: CGPoint(x: r.maxX - e, y: r.minY), radius: b)
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// A track with an arc going round it. Core Animation spins it in the render server:
/// a SwiftUI repeatForever animation redraws every frame and kept this always-on app at ~5% CPU.
struct Spinner: NSViewRepresentable {
    let tint: Color

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(tint: NSColor(tint)) }
    func updateNSView(_ view: SpinnerView, context: Context) {}
}

final class SpinnerView: NSView {
    private let track = CAShapeLayer(), arc = CAShapeLayer()

    init(tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineWidth = 2
            layer.lineCap = .round
            self.layer?.addSublayer(layer)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        arc.strokeColor = tint.cgColor
        arc.strokeEnd = 0.3
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.4
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        for layer in [track, arc] {
            layer.frame = bounds
            layer.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        }
    }
}

/// A ring with the count inside; it spins while anything in it is running.
struct CountRing: View {
    let count: Int, tint: Color, spinning: Bool

    var body: some View {
        ZStack {
            if spinning && count > 0 {
                Spinner(tint: tint)
            } else {
                Circle().stroke(count == 0 ? Color.white.opacity(0.14) : tint, lineWidth: 2)
            }
            Text("\(count)").font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(count == 0 ? Palette.secondary : .white)
        }
        .frame(width: 19, height: 19)
    }
}

struct IslandView: View {
    @ObservedObject var model: Model
    let gap: CGFloat, barHeight: CGFloat

    private var expanded: Bool { model.hovering && !model.sessions.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                wing(ring: CountRing(count: model.running.count, tint: Palette.green, spinning: true),
                     label: "running", leading: true)
                Color.clear.frame(width: gap)
                wing(ring: CountRing(count: model.waiting.count, tint: model.waitingTint, spinning: false),
                     label: "for you", leading: false)
            }
            .frame(height: barHeight)
            if expanded { list.transition(.opacity) }
        }
        .padding(.horizontal, Layout.ear)
        .frame(width: expanded ? Layout.expandedWidth : gap + 2 * Layout.wing + 2 * Layout.ear)
        .background(GeometryReader { g in Color.clear.onAppear { model.islandSize = g.size }
            .onChange(of: g.size) { _, size in model.islandSize = size } })
        .background {
            IslandShape(radius: expanded ? 22 : 12).fill(Palette.surface)
                .overlay(IslandShape(radius: expanded ? 22 : 12).stroke(Palette.rim, lineWidth: 1))
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 18, y: 8)
        }
        .animation(Layout.spring, value: expanded)
        .animation(Layout.spring, value: model.sessions)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func wing(ring: some View, label: String, leading: Bool) -> some View {
        HStack(spacing: 6) {
            if leading { ring }
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
            if !leading { ring }
        }
        .padding(.horizontal, 8)
        .frame(width: Layout.wing, alignment: leading ? .leading : .trailing)
    }

    private var list: some View {
        let shown = Array(model.sessions.prefix(Layout.maxRows))
        let waiting = shown.filter(\.waiting), running = shown.filter { !$0.waiting }
        return VStack(alignment: .leading, spacing: 0) {
            if !waiting.isEmpty { section("Needs you", count: model.waiting.count, rows: waiting) }
            if !waiting.isEmpty && !running.isEmpty {
                Rectangle().fill(Palette.rim).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 6)
            }
            if !running.isEmpty { section("Running", count: model.running.count, rows: running) }
            if model.sessions.count > shown.count {
                Text("+\(model.sessions.count - shown.count) more").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .padding(.leading, 8).padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func section(_ title: String, count: Int, rows: [Session]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            ForEach(rows) { row in SessionRow(session: row) { model.dismiss(row) } }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let dismiss: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            icon.frame(width: 22, height: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.project).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(age(session.since)).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    if session.waiting {
                        Button(action: dismiss) {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(hovered ? 0.75 : 0.35))
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(.white.opacity(hovered ? 0.12 : 0.06)))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss until it changes")
                    }
                }
                (Text(session.status).foregroundColor(session.state == .running ? Palette.secondary : session.tint)
                    + Text(session.summary.isEmpty ? "" : "  " + session.summary).foregroundColor(.white.opacity(0.42)))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(session.waiting ? 2 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovered ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { openInClaude(session.id) }
    }

    @ViewBuilder private var icon: some View {
        if session.state == .running {
            Spinner(tint: Palette.green).frame(width: 17, height: 17)
        } else {
            Image(systemName: session.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(session.tint)
        }
    }
}

final class FirstMouseHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // the panel is never key
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    /// --expanded pins the list open, for screenshots without moving the mouse.
    let pinned = CommandLine.arguments.contains("--expanded")
    var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        model.hovering = pinned
        installView()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.installView() }
        model.$hovering.sink { [weak self] in self?.panel.ignoresMouseEvents = !$0 }.store(in: &subscriptions)
        model.$sessions.sink { [weak self] in
            if $0.isEmpty { self?.panel.orderOut(nil) } else { self?.panel.orderFrontRegardless() }
        }.store(in: &subscriptions)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        // ponytail: polls the pointer instead of event monitors, which miss moves over a non-key panel.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.trackPointer() }
        refresh()
    }

    var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    /// A fixed transparent panel hangs from the top centre; the island inside grows and shrinks.
    /// It wraps the notch on the built-in screen, or sits on the menu bar of a screen without one.
    func installView() {
        guard let screen else { return }
        var gap: CGFloat = 12, barHeight = NSStatusBar.system.thickness
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            gap = screen.frame.width - left.width - right.width
            barHeight = screen.safeAreaInsets.top
        }
        let size = NSSize(width: max(Layout.expandedWidth, gap + 2 * Layout.wing + 2 * Layout.ear) + 60, height: 520)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.contentView = FirstMouseHostingView(rootView: IslandView(model: model, gap: gap, barHeight: barHeight))
    }

    func trackPointer() {
        guard !pinned, panel.isVisible else { return }
        let pointer = NSEvent.mouseLocation, frame = panel.frame, island = model.islandSize
        let fromTop = frame.maxY - pointer.y
        let inside = abs(pointer.x - frame.midX) <= island.width / 2 + 2 && fromTop >= -1 && fromTop <= island.height + 2
        if inside != model.hovering { model.hovering = inside }
    }

    func refresh() { model.update(readSessions()) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
