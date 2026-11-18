import SwiftUI

/// The island's PR mode: every open PR, as in the old GitHub Toolbox window, with details unfolding in place.
struct PullRequestList: View {
    let store: Store
    let readingHeight: CGFloat
    let openDetails: (PR) -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var confirmRelease = false
    @State private var releasing = false

    var body: some View {
        if let pr = selected {
            reading(pr)
        } else {
            ScrollView {
                rows.background(GeometryReader { g in Color.clear.onAppear { contentHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in contentHeight = h } })
            }
            .scrollIndicators(.never)
            // ScrollView takes all the height it is offered, so size it to its content up to a cap.
            .frame(height: min(max(contentHeight, 60), 470))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
    }

    private var selected: PR? { (store.requested + store.mine).first { $0.id == store.selection } }

    /// Reading size: the list narrows to a column and the PR gets the rest, down to near the bottom of the screen.
    private func reading(_ pr: PR) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { rows }
                .scrollIndicators(.never)
                .frame(width: Layout.readingListWidth)
            Rectangle().fill(Palette.rim).frame(width: 1).padding(.vertical, 4)
            PullRequestDetail(store: store, pr: pr, mine: store.mine.contains { $0.id == pr.id }, openDetails: openDetails)
                .id(pr.id)
                .padding(.leading, 16)
        }
        .frame(height: readingHeight)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("Review requested", store.requested.count)
            if store.requested.isEmpty { empty("Nothing waiting on you") }
            ForEach(store.requested) { PullRequestRow(store: store, pr: $0, mine: false) }
            Rectangle().fill(Palette.rim).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 6)
            header("My PRs", store.mine.count)
            if store.mine.isEmpty { empty("No open PRs") }
            ForEach(store.mine) { PullRequestRow(store: store, pr: $0, mine: true) }
            Rectangle().fill(Palette.rim).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 6)
            header("Local environments", store.envs.count)
            if store.envs.isEmpty { empty("None running") }
            ForEach(store.envs) { EnvRow(store: store, env: $0) }
            footer
        }
    }

    private func header(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.35)).padding(.horizontal, 8).padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.refreshing {
                Text("Refreshing…")
            } else if let error = store.error {
                Text(error).foregroundStyle(Palette.red).lineLimit(1)
            } else if let at = store.updatedAt {
                TimelineView(.periodic(from: .now, by: 10)) { _ in Text("Updated \(age(at)) ago".replacingOccurrences(of: "now ago", with: "just now")) }
            }
            Spacer()
            releaseButton
            IslandButton(title: "Refresh", symbol: "arrow.clockwise") { Task { await store.refresh() } }
                .disabled(store.refreshing)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.35))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    /// Dispatches the prod release with its default inputs and opens the run list to watch it.
    /// Two-step like posting findings: one stray click shouldn't ship prod.
    private var releaseButton: some View {
        IslandButton(title: confirmRelease ? "Click again to release prod" : "Release prod",
                     symbol: "shippingbox", tint: confirmRelease ? Palette.orange : nil) {
            guard confirmRelease else { return confirmRelease = true }
            releasing = true
            Task {
                do {
                    _ = try await cli(["gh", "workflow", "run", "release-prod.yml", "--repo", "FreshXYZ/code", "--ref", "main"])
                    NSWorkspace.shared.open(URL(string: "https://github.com/FreshXYZ/code/actions/workflows/release-prod.yml")!)
                } catch {
                    store.error = error.localizedDescription
                }
                releasing = false
                confirmRelease = false
            }
        }
        .disabled(releasing)
    }
}

struct PullRequestRow: View {
    let store: Store
    let pr: PR
    let mine: Bool
    @State private var hovered = false

    private var open: Bool { store.selection == pr.id }
    private var review: ReviewState? { store.reviews[pr.reviewKey] }

    var body: some View {
        summary
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(open ? 0.06 : hovered ? 0.07 : 0)))
        .onHover { hovered = $0 }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 11) {
            Circle().fill(ciColor).frame(width: 8, height: 8).frame(width: 22, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pr.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    Spacer(minLength: 0)
                    if pr.isDraft { IslandTag(text: "Draft", tint: .gray) }
                    reviewBadge
                }
                (Text("\(pr.repoName)#\(String(pr.number)) · ") + who + Text(" · \(age(pr.createdAt))"))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = pr.id }
    }

    /// On my own PRs the author is always me, so the slot shows who is reviewing instead.
    private var who: Text {
        guard mine else { return Text(pr.authorLogin) }
        let names = pr.reviewers.map(\.name)
        return names.isEmpty ? Text("no reviewer").foregroundColor(Palette.orange) : Text("→ " + names.joined(separator: ", "))
    }

    @ViewBuilder private var reviewBadge: some View {
        switch review {
        case .queued: Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        case .running: Spinner(tint: Palette.purple).frame(width: 12, height: 12)
        case .done(let r) where r.verdict == "ok": Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(Palette.green)
        case .done(let r): IslandTag(text: "\(r.items.count) to check", tint: Palette.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Palette.red)
        case nil: EmptyView()
        }
    }

    private var ciColor: Color {
        switch pr.ciState {
        case "SUCCESS": Palette.green
        case "FAILURE", "ERROR": Palette.red
        case "PENDING", "EXPECTED": Palette.orange
        default: .white.opacity(0.25)
        }
    }

}

/// One worktree's dev servers and test browsers, stalest first, with a two-click kill.
struct EnvRow: View {
    let store: Store
    let env: LocalEnv
    @State private var hovered = false
    @State private var confirm = false
    @State private var killing = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "server.rack").font(.system(size: 12)).foregroundStyle(env.gone ? Palette.red : Palette.secondary)
                .frame(width: 22, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(env.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                (Text(parts).foregroundColor(.white.opacity(0.42))
                    + Text(env.gone ? " · worktree deleted" : "").foregroundColor(Palette.red))
                    .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if killing {
                Spinner(tint: Palette.red).frame(width: 12, height: 12)
            } else {
                IslandButton(title: confirm ? "Click again to kill" : "", symbol: "trash", tint: confirm ? Palette.red : nil) {
                    guard confirm else { return confirm = true }
                    killing = true
                    Task { await store.kill(env); killing = false; confirm = false }
                }
                .help("Stop its dev servers and close its test browsers")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovered ? 0.07 : 0)))
        .onHover { hovered = $0; if !$0 { confirm = false } }
        .help((env.tmux + env.browsers).joined(separator: ", "))
    }

    private var parts: String {
        var bits: [String] = []
        if !env.tmux.isEmpty { bits.append(env.tmux.map { $0.hasSuffix("-be") ? "BE" : $0.hasSuffix("-fe") ? "FE" : $0 }.joined(separator: "+")) }
        if !env.browsers.isEmpty { bits.append("\(env.browsers.count) browser\(env.browsers.count == 1 ? "" : "s")") }
        if let s = env.started { bits.append("started \(age(s)) ago") }
        bits.append(env.lastUsed.map { "used \(age($0)) ago" } ?? "no Claude session")
        return bits.joined(separator: " · ").replacingOccurrences(of: "now ago", with: "just now")
    }
}

/// The right-hand pane of the reading size: everything about one PR, its description filling the height left.
struct PullRequestDetail: View {
    let store: Store
    let pr: PR
    let mine: Bool
    let openDetails: (PR) -> Void
    @State private var working = false
    @State private var confirmPost = false

    private var review: ReviewState? { store.reviews[pr.reviewKey] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(pr.repository.nameWithOwner)#\(String(pr.number)) by \(pr.authorLogin) · opened \(age(pr.createdAt)) ago")
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer(minLength: 0)
                IslandButton(title: "", symbol: "xmark") { store.selection = nil }.help("Back to the list")
            }
            reviewers
            checks
            if !mine { ScrollView { agentReview }.frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true) }
            actions
            if !pr.bodyHTML.isEmpty {
                HTMLView(key: pr.id, html: pr.bodyHTML, dark: true, fontSize: 14)
                    .padding(10)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.top, 6)
    }

    private var reviewers: some View {
        HStack(spacing: 6) {
            Text("Reviewers").foregroundStyle(Palette.secondary)
            if pr.reviewers.isEmpty { Text("none yet").foregroundStyle(.white.opacity(0.35)) }
            ForEach(pr.reviewers, id: \.name) { reviewer in
                switch reviewer.state {
                case "APPROVED": IslandTag(text: "\(reviewer.name) approved", tint: Palette.green)
                case "CHANGES_REQUESTED": IslandTag(text: "\(reviewer.name) requested changes", tint: Palette.red)
                case "WAITING": IslandTag(text: "\(reviewer.name) waiting", tint: Palette.orange)
                case "DISMISSED": IslandTag(text: "\(reviewer.name) dismissed", tint: .gray)
                default: IslandTag(text: "\(reviewer.name) commented", tint: Palette.blue)
                }
            }
        }
    }

    private var checks: some View {
        let all = pr.checks
        let failed = all.filter { $0.bucket == .failed }, running = all.filter { $0.bucket == .running }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(all.isEmpty ? "No checks" :
                    "\(all.count - failed.count - running.count) passed · \(failed.count) failed · \(running.count) running")
                    .foregroundStyle(.white.opacity(0.75))
                Link("All checks", destination: pr.url.appendingPathComponent("checks")).foregroundStyle(Palette.blue)
            }
            ForEach(Array(failed.prefix(5).enumerated()), id: \.offset) { _, check in
                checkLink(check, symbol: "xmark.circle.fill", tint: Palette.red)
            }
        }
    }

    @ViewBuilder private func checkLink(_ check: Check, symbol: String, tint: Color) -> some View {
        let label = Label(check.title, systemImage: symbol).foregroundStyle(tint)
        if let url = check.link { Link(destination: url) { label } } else { label }
    }

    @ViewBuilder private var agentReview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                switch review {
                case .queued, nil: Text("\(ReviewEngine.selected.name) review queued").foregroundStyle(Palette.secondary)
                case .running: Text("\(ReviewEngine.selected.name) is reviewing, usually a few minutes").foregroundStyle(Palette.secondary)
                case .done(let r) where r.verdict == "ok":
                    Text("\(r.engineName) found nothing that needs a closer look").foregroundStyle(Palette.green)
                case .done(let r):
                    Text("\(r.engineName) flagged \(r.items.count) thing\(r.items.count == 1 ? "" : "s") to check")
                        .foregroundStyle(Palette.orange)
                case .failed(let message): Text("Review failed: \(message)").foregroundStyle(Palette.red).lineLimit(2)
                }
                Spacer(minLength: 0)
                if case .done = review { IslandButton(title: "Re-run") { store.rerunReview(pr) } }
                if case .failed = review { IslandButton(title: "Re-run") { store.rerunReview(pr) } }
            }
            if case .done(let r) = review {
                if !r.summary.isEmpty { Text(r.summary).foregroundStyle(.white.opacity(0.6)) }
                ForEach(Array(r.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Link("\(item.file):\(String(item.line))", destination: blobURL(item))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.blue)
                        Text(item.why).foregroundStyle(.white.opacity(0.7))
                    }
                }
                if let at = r.postedAt {
                    Text("Posted as changes requested \(age(at)) ago").foregroundStyle(Palette.secondary)
                } else if !r.items.isEmpty {
                    // Two-step: posting notifies the author, so one stray click shouldn't do it.
                    IslandButton(title: confirmPost ? "Click again to post as changes requested" : "Post findings to PR",
                                 tint: confirmPost ? Palette.orange : nil) {
                        if confirmPost {
                            working = true
                            Task { await store.postFindings(pr, r); working = false; confirmPost = false }
                        } else {
                            confirmPost = true
                        }
                    }
                    .disabled(working)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
    }

    private var actions: some View {
        HStack(spacing: 6) {
            IslandButton(title: "GitHub", symbol: "arrow.up.right") { NSWorkspace.shared.open(pr.url) }
            if mine {
                IslandButton(title: pr.isDraft ? "Ready for review" : "Make draft") {
                    perform(["pr", "ready", pr.url.absoluteString] + (pr.isDraft ? [] : ["--undo"]))
                }
                requestReview
                IslandButton(title: "Close", tint: Palette.red) { perform(["pr", "close", pr.url.absoluteString], hiding: true) }
            } else {
                IslandButton(title: "Approve", tint: Palette.green, prominent: true) {
                    perform(["pr", "review", pr.url.absoluteString, "--approve"], hiding: true)
                }
            }
            IslandButton(title: "Ask Claude", symbol: "bubble.left", tint: Palette.claude) { askClaude() }
                .help("Start a Claude Code session about this PR, with the agent review if it has finished")
            IslandButton(title: "Details") { openDetails(pr) }
            if working { Spinner(tint: Palette.purple).frame(width: 12, height: 12) }
        }
        .disabled(working)
    }

    /// Opens a new Claude Code session in the Claude app with the PR link, plus the agent review when one has finished.
    private func askClaude() {
        var prompt = "Let's talk about this pull request (read it with gh): \(pr.url.absoluteString)\n\"\(pr.title)\""
        if case .done(let r) = review {
            prompt += "\n\n\(r.engineName) pre-review (\(r.verdict == "ok" ? "nothing flagged" : "\(r.items.count) flagged")): \(r.summary)"
            for item in r.items { prompt += "\n- \(item.file):\(item.line) \(item.why)" }
        }
        var url = URLComponents(string: "claude://code/new")!
        url.queryItems = [URLQueryItem(name: "q", value: prompt)]
        // ponytail: one known checkout; other repos open without a folder
        if pr.repository.nameWithOwner == "FreshXYZ/code" {
            url.queryItems?.append(URLQueryItem(name: "folder", value: NSHomeDirectory() + "/Develop/code"))
        }
        if let link = url.url { NSWorkspace.shared.open(link) }
    }

    private var requestReview: some View {
        let candidates = pr.reviewerCandidates
        return Menu {
            Section("Suggested") { ForEach(candidates.suggested, id: \.login, content: reviewerButton) }
            Section("Everyone") { ForEach(candidates.others, id: \.login, content: reviewerButton) }
        } label: {
            IslandButton.label(title: "Request review", symbol: "chevron.down", tint: nil, prominent: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func reviewerButton(_ user: PR.User) -> some View {
        Button(user.name.map { "\($0) (\(user.login))" } ?? user.login) {
            perform(["api", "--method", "POST", "repos/\(pr.repository.nameWithOwner)/pulls/\(pr.number)/requested_reviewers",
                     "-f", "reviewers[]=\(user.login)"])
        }
    }

    private func blobURL(_ item: Review.Item) -> URL {
        URL(string: "https://github.com/\(pr.repository.nameWithOwner)/blob/\(pr.headRefOid)/\(item.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.file)#L\(item.line)")!
    }

    private func perform(_ args: [String], hiding: Bool = false) {
        working = true
        Task {
            await store.run(args, hiding: hiding ? pr : nil)
            working = false
        }
    }
}

struct IslandTag: View {
    let text: String, tint: Color

    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.18)))
    }
}

/// A capsule button that sits on the island's black.
struct IslandButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color? = nil
    var prominent = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) { Self.label(title: title, symbol: symbol, tint: tint, prominent: prominent, hovered: hovered) }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
    }

    static func label(title: String, symbol: String?, tint: Color?, prominent: Bool, hovered: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title)
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(prominent ? .black : tint ?? .white.opacity(0.85))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(prominent ? (tint ?? .white).opacity(hovered ? 1 : 0.9)
                                             : (tint ?? .white).opacity(hovered ? 0.2 : 0.1)))
    }
}
