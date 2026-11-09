import AppKit

struct Session: Identifiable, Equatable {
    enum State: String { case input, done, running }
    let id: String, state: State, project: String, detail: String, prompt: String, failed: Bool, since: Date

    var waiting: Bool { state != .running }
}

let sessionsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".attention-island/sessions")

// ponytail: age limits stand in for process liveness, so a crashed agent lingers until its entry ages out.
// Upgrade path: record the agent pid in hook.py and check it here.
func readSessions(now: Date = Date()) -> [Session] {
    let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
    let sessions: [Session] = files.compactMap { url in
        guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
              let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = (e["state"] as? String).flatMap(Session.State.init),
              let seen = (e["seen"] ?? e["at"]) as? Double else { return nil }
        if now.timeIntervalSince1970 - seen > (state == .running ? 30 * 60 : 12 * 3600) { return nil }
        let cwd = e["cwd"] as? String ?? ""
        let folder = cwd.isEmpty ? "Claude" : URL(fileURLWithPath: cwd).lastPathComponent
        return Session(id: url.deletingPathExtension().lastPathComponent, state: state,
                       project: (e["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder,
                       detail: e["detail"] as? String ?? "", prompt: e["prompt"] as? String ?? "",
                       failed: e["failed"] as? Bool ?? false,
                       since: Date(timeIntervalSince1970: (e["since"] as? Double) ?? seen))
    }
    let order: [Session.State] = [.input, .done, .running]
    return sessions.sorted { ($0.state == $1.state) ? $0.since > $1.since
        : order.firstIndex(of: $0.state)! < order.firstIndex(of: $1.state)! }
}

/// Claude Desktop keeps one local_<uuid>.json per Code session mapping the CLI session id to its own id,
/// which is what its claude:// link wants. Scanned only on click: there are over a thousand of them.
func openInClaude(_ cliSession: String) {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    let needle = Data(cliSession.utf8)
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json",
              let data = try? Data(contentsOf: url), data.range(of: needle) != nil,
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              meta["cliSessionId"] as? String == cliSession, let local = meta["sessionId"] as? String,
              let link = URL(string: "claude://code/continue?session=\(local)") else { continue }
        NSWorkspace.shared.open(link)
        return
    }
    NSSound.beep()  // a terminal session: Desktop has no link for it
}

func age(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    return s < 60 ? "now" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
}

