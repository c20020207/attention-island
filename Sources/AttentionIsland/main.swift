import AppKit
import Combine
import SwiftUI

enum Palette {
    static let green = Color(red: 0.36, green: 0.86, blue: 0.56)
    static let orange = Color(red: 1.0, green: 0.68, blue: 0.26)
    static let blue = Color(red: 0.47, green: 0.62, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let purple = Color(red: 0.73, green: 0.58, blue: 1.0)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let surface = Color(white: 0.045)
    static let rim = Color.white.opacity(0.09)
    static let secondary = Color.white.opacity(0.5)
}

enum Layout {
    static let wing: CGFloat = 112, ear: CGFloat = 6, expandedWidth: CGFloat = 420, pullRequestWidth: CGFloat = 520, readingWidth: CGFloat = 920, readingListWidth: CGFloat = 300, maxRows = 7
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.84)
}

extension Session {
    var approval: Bool { detail.hasPrefix("Needs approval") }
    var tint: Color {
        switch state {
        case .input: Palette.orange
        case .done: failed ? Palette.red : Palette.blue
        case .running: Palette.green
        case .watching: Palette.secondary
        }
    }
    var symbol: String {
        switch state {
        case .input: approval ? "hand.raised" : "questionmark.bubble"
        case .done: failed ? "exclamationmark.triangle" : "arrowshape.turn.up.left"
        case .running: ""
        case .watching: "eye"
        }
    }
    var status: String {
        switch state {
        case .input: approval ? "Approval needed" : "Question"
        case .done: failed ? "Error" : "Your turn"
        case .running: "Working"
        case .watching: "Watching"
        }
    }
    var summary: String {
        let raw = switch state {
        case .input: detail.replacingOccurrences(of: #"^(Needs approval|Asking) · "#, with: "", options: .regularExpression)
        case .done: detail
        case .running: prompt.hasPrefix("<") ? "" : prompt  // app-injected events, not something I typed
        case .watching: detail.isEmpty ? (prompt.hasPrefix("<") ? "" : prompt) : detail
        }
        return plain(raw)
    }
}

/// Last turns are markdown; the island shows them as plain text.
func plain(_ text: String) -> String {
    text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\*\*|__|`|(^|\s)#+\s"#, with: "$1", options: .regularExpression)
}

/// One row on the island: a Claude session or a pull request.
struct Item: Identifiable, Equatable {
    enum Group: Int { case needsYou, pullRequests, running, watching }
    enum Target: Equatable { case claude(String), pr(String), allPullRequests, details(String), sessions, environments }

    /// Also the dismissal key, so it must change whenever the thing needs me afresh.
    let id: String
    let group: Group, title: String, status: String, summary: String, tint: Color
    let symbol: String?  // nil draws a spinner
    let since: Date, waiting: Bool, target: Target
}

extension Session {
    var item: Item {
        Item(id: "\(id)@\(since.timeIntervalSince1970)", group: waiting ? .needsYou : state == .watching ? .watching : .running, title: project,
             status: status, summary: summary, tint: tint, symbol: state == .running ? nil : symbol,
             since: since, waiting: waiting, target: .claude(id))
    }
}

/// The same rule the GitHub Toolbox menu bar count used, plus failed pre-reviews: those still need my review.
@MainActor func pullRequestItems(_ store: Store) -> [Item] {
    func item(_ pr: PR, _ kind: String, status: String, summary: String, waiting: Bool) -> Item {
        Item(id: "pr:\(kind):\(pr.reviewKey)", group: .pullRequests, title: pr.title, status: status,
             summary: "\(pr.repoName)#\(pr.number)" + (summary.isEmpty ? "" : " · " + summary), tint: Palette.purple,
             symbol: waiting ? "arrow.triangle.pull" : nil, since: pr.createdAt, waiting: waiting, target: .pr(pr.id))
    }
    let requested = store.requested.map { pr in
        switch store.reviews[pr.reviewKey] {
        case .done(let r) where r.verdict == "ok":
            item(pr, "review", status: "Review", summary: "\(r.engineName) found nothing to check", waiting: true)
        case .done(let r):
            item(pr, "review", status: "Review", summary: "\(r.engineName) flagged \(r.items.count) to check", waiting: true)
        case .failed:
            item(pr, "review", status: "Review", summary: "pre-review failed", waiting: true)
        case .queued, .running, nil:
            item(pr, "review", status: "Pre-reviewing", summary: "", waiting: false)
        }
    }
    let unassigned = store.mine.filter { !$0.isDraft && $0.ciState == "SUCCESS" && $0.reviewers.isEmpty }.map {
        item($0, "mine", status: "No reviewer", summary: "CI passed", waiting: true)
    }
    let changesRequested = store.mine.compactMap { pr in
        let names = pr.changesRequestedBy
        return names.isEmpty ? nil : item(pr, "changes", status: "Changes requested",
                                          summary: names.joined(separator: ", "), waiting: true)
    }
    return requested.filter(\.waiting) + changesRequested + unassigned + requested.filter { !$0.waiting }
}

/// What one screen's island is doing. The rows are shared through Model; this is not.
final class IslandState: ObservableObject {
    @Published var hovering = false
    /// PR mode: the island lists every PR and stays open until I click its badge or anywhere outside.
    @Published var pullRequestsOpen = false
    /// Environments mode: same stay-open behaviour as PR mode.
    @Published var environmentsOpen = false
    var panelOpen: Bool { pullRequestsOpen || environmentsOpen }
    var size = CGSize.zero
}

final class Model: ObservableObject {
    /// Shown rows: sessions and pull requests minus what I dismissed.
    @Published private(set) var items: [Item] = []
    private var all: [Item] = []
    private var dismissed = Set(UserDefaults.standard.stringArray(forKey: "dismissed") ?? [])
    private var pullRequestsLoaded = false

    /// `pullRequestsLoaded` is false until GitHub first answers: an empty list then must not forget PR dismissals.
    func update(_ items: [Item], pullRequestsLoaded: Bool) {
        all = items
        self.pullRequestsLoaded = pullRequestsLoaded
        let current = Set(items.map(\.id))
        dismissed = dismissed.filter { current.contains($0) || ($0.hasPrefix("pr:") && !pullRequestsLoaded) }
        UserDefaults.standard.set(Array(dismissed), forKey: "dismissed")
        let kept = all.filter { !dismissed.contains($0.id) }
        let shown = [Item.Group.needsYou, .pullRequests, .running, .watching].flatMap { g in kept.filter { $0.group == g } }
        if shown != self.items { self.items = shown }
    }

    func dismiss(_ item: Item) {
        dismissed.insert(item.id)
        update(all, pullRequestsLoaded: pullRequestsLoaded)
    }

    /// Pull requests count only when they wait on me; every other group counts all its rows.
    func count(_ group: Item.Group) -> Int { items.filter { $0.group == group && ($0.waiting || group != .pullRequests) }.count }
    var waitingTint: Color { items.contains { $0.group == .needsYou && $0.tint == Palette.orange } ? Palette.orange : Palette.blue }
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
    @ObservedObject var state: IslandState
    let gap: CGFloat, barHeight: CGFloat, readingHeight: CGFloat
    let store: Store
    let open: (Item.Target) -> Void

    private var expanded: Bool { state.panelOpen || (state.hovering && !model.items.isEmpty) }
    private var reading: Bool { state.pullRequestsOpen && (store.requested + store.mine).contains { $0.id == store.selection } }
    private var width: CGFloat {
        reading ? Layout.readingWidth : state.panelOpen ? Layout.pullRequestWidth : expanded ? Layout.expandedWidth : gap + 2 * Layout.wing + 2 * Layout.ear
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    if (store.memory ?? 0) >= memoryThreshold || state.environmentsOpen {
                        MemoryBadge(memory: store.memory) { open(.environments) }
                    }
                }
                .padding(.horizontal, 2)
                .frame(width: Layout.wing, alignment: .leading)
                Color.clear.frame(width: gap)
                HStack(spacing: 9) {
                    PullRequestBadge(count: model.count(.pullRequests)) { open(.allPullRequests) }
                    WingButton(tint: Palette.claude, help: "Claude sessions") { open(.sessions) } label: {
                        HStack(spacing: 5) {
                            ClaudeMark().fill(Palette.claude).frame(width: 13, height: 13)
                                .opacity(model.count(.needsYou) == 0 ? 0.55 : 1)
                            CountRing(count: model.count(.needsYou), tint: model.waitingTint, spinning: false)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: Layout.wing, alignment: .trailing)
            }
            .frame(height: barHeight)
            if state.pullRequestsOpen {
                PullRequestList(store: store, readingHeight: readingHeight) { open(.details($0.id)) }.transition(.opacity)
            } else if state.environmentsOpen {
                EnvList(store: store).transition(.opacity)
            } else if expanded {
                list.transition(.opacity)
            }
        }
        .padding(.horizontal, Layout.ear)
        .frame(width: width)
        .background(GeometryReader { g in Color.clear.onAppear { state.size = g.size }
            .onChange(of: g.size) { _, size in state.size = size } })
        .background {
            IslandShape(radius: expanded ? 22 : 12).fill(Palette.surface)
                .overlay(IslandShape(radius: expanded ? 22 : 12).stroke(Palette.rim, lineWidth: 1))
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 18, y: 8)
        }
        .animation(Layout.spring, value: expanded)
        .animation(Layout.spring, value: state.pullRequestsOpen)
        .animation(Layout.spring, value: state.environmentsOpen)
        .animation(Layout.spring, value: reading)
        .animation(Layout.spring, value: model.items)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var list: some View {
        let shown = Array(model.items.prefix(Layout.maxRows))
        let groups: [(Item.Group, String)] = [(.needsYou, "Needs you"), (.pullRequests, "Pull requests"), (.running, "Running"), (.watching, "Watching")]
        let present = groups.filter { g in shown.contains { $0.group == g.0 } }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(present.enumerated()), id: \.element.0) { index, group in
                if index > 0 {
                    Rectangle().fill(Palette.rim).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 6)
                }
                section(group.1, count: model.count(group.0), rows: shown.filter { $0.group == group.0 })
            }
            if model.items.count > shown.count {
                Text("+\(model.items.count - shown.count) more").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .padding(.leading, 8).padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func section(_ title: String, count: Int, rows: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            ForEach(rows) { row in
                ItemRow(item: row, dismiss: { model.dismiss(row) }, open: {
                    // Opening a session is dealing with it; its id changes when it next needs me, so it comes back then.
                    if case .claude = row.target { model.dismiss(row) }
                    open(row.target)
                })
            }
        }
    }
}

/// Claude's starburst: uneven rays round a centre, drawn so no logo file is needed.
struct ClaudeMark: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), outer = min(r.width, r.height) / 2
        let lengths: [CGFloat] = [1, 0.78, 0.94, 0.72, 1, 0.84, 0.92, 0.7, 0.98, 0.8, 0.9, 0.76]
        var p = Path()
        for (i, length) in lengths.enumerated() {
            let a = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi - .pi / 2
            let end = CGPoint(x: c.x + cos(a) * outer * length, y: c.y + sin(a) * outer * length)
            p.move(to: c)
            p.addLine(to: end)
        }
        return p.strokedPath(StrokeStyle(lineWidth: outer * 0.24, lineCap: .round))
    }
}

/// A clickable group in a wing, with a faint capsule behind it on hover.
struct WingButton<Label: View>: View {
    let tint: Color
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(hovered ? 0.18 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Memory in use, tinted by how full it is; clicking opens CPU, memory and the running worktrees.
struct MemoryBadge: View {
    let memory: Double?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        let tint = usageTint(memory ?? 0)
        Button(action: open) {
            HStack(spacing: 3) {
                Image(systemName: "memorychip").font(.system(size: 10, weight: .semibold))
                Text(memory.map { "\(Int($0 * 100))%" } ?? "–").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(hovered ? 0.2 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Memory in use · local environments and cleanup")
    }
}

func usageTint(_ fraction: Double) -> Color { fraction >= 0.85 ? Palette.red : fraction >= 0.7 ? Palette.orange : Palette.green }

/// The PR count beside the notch; clicking it opens every PR, like the old menu bar icon.
struct PullRequestBadge: View {
    let count: Int
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 10.5, weight: .semibold))
                Text("\(count)").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .foregroundStyle(count == 0 && !hovered ? Palette.secondary : Palette.purple)
            .opacity(count == 0 && !hovered ? 0.7 : 1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Palette.purple.opacity(hovered ? 0.2 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Pull requests")
    }
}

struct ItemRow: View {
    let item: Item
    let dismiss: () -> Void
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            icon.frame(width: 22, height: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(age(item.since)).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    if item.waiting {
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
                (Text(item.status).foregroundColor(item.waiting ? item.tint : Palette.secondary)
                    + Text(item.summary.isEmpty ? "" : "  " + item.summary).foregroundColor(.white.opacity(0.42)))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(item.group == .needsYou ? 2 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovered ? 0.07 : 0)))
        .opacity(item.group == .watching ? 0.6 : 1)  // quiet: it only kept an eye on something for me
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
    }

    @ViewBuilder private var icon: some View {
        if let symbol = item.symbol {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(item.tint)
        } else {
            Spinner(tint: item.tint).frame(width: 17, height: 17)
        }
    }
}

final class FirstMouseHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // the panel is never key
}

/// One screen's island: a fixed transparent panel hanging from the top centre, the island inside growing and shrinking.
@MainActor
final class Island {
    let state = IslandState()
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var subscription: AnyCancellable?

    init() {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        subscription = state.$hovering.sink { [weak panel] in panel?.ignoresMouseEvents = !$0 }
    }

    /// Wraps the notch on a screen that has one, or sits on the menu bar of a screen without.
    func place(on screen: NSScreen, model: Model, store: Store, open: @escaping (Item.Target) -> Void) {
        var gap: CGFloat = 12
        var barHeight = screen.frame.maxY - screen.visibleFrame.maxY  // this screen's own menu bar
        if barHeight <= 0 { barHeight = NSStatusBar.system.thickness }  // menu bar set to hide
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            gap = screen.frame.width - left.width - right.width
            barHeight = screen.safeAreaInsets.top
        }
        let size = NSSize(width: max(Layout.readingWidth, gap + 2 * Layout.wing + 2 * Layout.ear) + 60,
                          height: min(screen.frame.height - 40, 980))
        let readingHeight = size.height - barHeight - 60  // room for the bottom padding and shadow
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.contentView = FirstMouseHostingView(rootView: IslandView(
            model: model, state: state, gap: gap, barHeight: barHeight, readingHeight: readingHeight, store: store, open: open))
        panel.orderFrontRegardless()  // always shown: the badges are the way in
    }

    func trackPointer() {
        if state.panelOpen {
            if !state.hovering { state.hovering = true }  // keeps the panel taking clicks while PR mode is open
            return
        }
        let pointer = NSEvent.mouseLocation, frame = panel.frame
        let fromTop = frame.maxY - pointer.y
        let inside = abs(pointer.x - frame.midX) <= state.size.width / 2 + 2 && fromTop >= -1 && fromTop <= state.size.height + 2
        if inside != state.hovering { state.hovering = inside }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let store = Store()
    /// The GitHub Toolbox window, opened from a PR's Details button.
    lazy var pullRequestWindow: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Pull requests"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environment(store))
        window.center()
        return window
    }()
    var islands: [CGDirectDisplayID: Island] = [:]
    /// --expanded pins the list open, for screenshots without moving the mouse.
    let pinned = CommandLine.arguments.contains("--expanded")
    /// --pull-requests opens PR mode with the first PR unfolded, also for screenshots.
    let pinnedPullRequests = CommandLine.arguments.contains("--pull-requests")
    /// --environments opens the environments list, also for screenshots.
    let pinnedEnvironments = CommandLine.arguments.contains("--environments")

    func applicationDidFinishLaunching(_ notification: Notification) {
        placeIslands()
        if pinnedEnvironments {
            islands.values.forEach { $0.state.environmentsOpen = true }
        } else if pinnedPullRequests {
            islands.values.forEach { $0.state.pullRequestsOpen = true }
            Task {
                while store.updatedAt == nil { try? await Task.sleep(for: .milliseconds(300)) }
                store.selection = (store.requested + store.mine).first?.id
            }
        } else {
            // A click anywhere but an island (another app, or our own PR window) closes the panels.
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanels() }
            }
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, !self.islands.values.contains(where: { $0.panel === event.window }) { self.closePanels() }
                }
                return event
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.placeIslands() } }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        // ponytail: polls the pointer instead of event monitors, which miss moves over a non-key panel.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.pinned == false { self?.islands.values.forEach { $0.trackPointer() } } }
        }
        refresh()
    }

    /// One island per screen; screens plugged in or out add or drop theirs.
    func placeIslands() {
        var current = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            current.insert(id)
            let island = islands[id] ?? Island()
            if islands[id] == nil {
                island.state.hovering = pinned
                islands[id] = island
            }
            island.place(on: screen, model: model, store: store) { [weak self, weak island] target in
                if let island { self?.open(target, from: island) }
            }
        }
        for (id, island) in islands where !current.contains(id) {
            island.panel.orderOut(nil)
            islands[id] = nil
        }
    }

    func closePanels() {
        islands.values.forEach { $0.state.pullRequestsOpen = false; $0.state.environmentsOpen = false }
    }

    func open(_ target: Item.Target, from island: Island) {
        switch target {
        case .claude(let session): openInClaude(session)
        case .pr(let id):
            store.selection = id
            showPullRequests(on: island)
        case .environments:
            let wasOpen = island.state.environmentsOpen
            for other in islands.values { other.state.pullRequestsOpen = false; other.state.environmentsOpen = false }
            island.state.environmentsOpen = !wasOpen
            if !wasOpen { Task { store.envs = await scanEnvs() } }
        case .sessions:
            island.state.environmentsOpen = false
            island.state.pullRequestsOpen = false  // the pointer is on the island, so hovering shows the session list
        case .allPullRequests:
            if island.state.pullRequestsOpen {
                island.state.pullRequestsOpen = false
            } else {
                store.selection = nil  // the badge always opens on the list
                showPullRequests(on: island)
            }
        case .details(let id):
            island.state.pullRequestsOpen = false
            store.selection = id
            NSApp.activate(ignoringOtherApps: true)
            pullRequestWindow.makeKeyAndOrderFront(nil)
        }
    }

    /// Only one screen at a time gets the big PR panel.
    private func showPullRequests(on island: Island) {
        for other in islands.values where other !== island { other.state.pullRequestsOpen = false }
        island.state.environmentsOpen = false
        island.state.pullRequestsOpen = true
    }

    func refresh() {
        model.update(readSessions().map(\.item) + pullRequestItems(store), pullRequestsLoaded: store.updatedAt != nil)
    }
}

// --plan-cleanup prints what a cleanup would stop, without stopping anything.
if CommandLine.arguments.contains("--plan-cleanup") {
    Task {
        do {
            let report = try await runCleanup(await scanEnvs(), memory: memoryInUse(), dryRun: true)
            for s in report.stopped { print("WOULD STOP \(s.name): \(s.why)") }
            print("SUMMARY: \(report.summary)")
        } catch { print("ERROR: \(error.localizedDescription)") }
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }  // top-level code runs on the main thread
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
