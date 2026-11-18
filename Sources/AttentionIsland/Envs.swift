import Darwin
import Foundation

/// A local test environment: the tmux dev servers and agent-browser sessions started for one worktree.
struct LocalEnv: Identifiable, Equatable {
    let id: String  // the worktree path, or the browser session name when it matches no worktree
    var name: String
    var tmux: [String] = []
    var browsers: [String] = []
    var started: Date?
    /// Newest Claude transcript write in the worktree: the env is stale once its task's session goes quiet.
    var lastUsed: Date?
    var gone = false
    /// Resident memory and CPU of the dev servers' process trees; test browsers aren't counted.
    var rssKB = 0
    var cpu = 0.0
}

private let home = FileManager.default.homeDirectoryForCurrentUser

/// Dev servers live in tmux sessions run from a worktree's backend/ or frontend/; browsers are named cc-<worktree>-….
func scanEnvs() async -> [LocalEnv] {
    var envs: [String: LocalEnv] = [:]
    let panes = (try? await cli(["tmux", "list-panes", "-a", "-F", "#{session_name}|#{session_created}|#{pane_pid}|#{pane_current_path}"])) ?? Data()
    let usage = processUsage(try? await cli(["ps", "-axo", "pid=,ppid=,rss=,%cpu="]))
    for line in String(decoding: panes, as: UTF8.self).split(separator: "\n") {
        let f = line.split(separator: "|", maxSplits: 3).map(String.init)
        guard f.count == 4 else { continue }
        let root = f[3].replacingOccurrences(of: #"/(backend|frontend)(/.*)?$"#, with: "", options: .regularExpression)
        var env = envs[root] ?? LocalEnv(id: root, name: URL(fileURLWithPath: root).lastPathComponent)
        if !env.tmux.contains(f[0]) { env.tmux.append(f[0]) }
        let created = Date(timeIntervalSince1970: Double(f[1]) ?? 0)
        env.started = min(env.started ?? created, created)
        let tree = usage(Int(f[2]) ?? 0)
        env.rssKB += tree.rssKB
        env.cpu += tree.cpu
        envs[root] = env
    }
    let list = (try? await cli(["agent-browser", "session", "list"])) ?? Data()
    for line in String(decoding: list, as: UTF8.self).split(separator: "\n") {
        let session = line.trimmingCharacters(in: .whitespaces)
        guard session.hasPrefix("cc-") else { continue }
        // Longest worktree name wins: one can be a prefix of another.
        let key = envs.values.filter { session.hasPrefix("cc-\($0.name)") }.max { $0.name.count < $1.name.count }?.id ?? session
        envs[key, default: LocalEnv(id: session, name: session)].browsers.append(session)
    }
    let projects = home.appendingPathComponent(".claude/projects")
    let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
    for key in envs.keys where key.hasPrefix("/") {
        envs[key]!.gone = key.contains("/.ccd-trash") || !FileManager.default.fileExists(atPath: key)
        // A trashed worktree's folder name means nothing; its tmux sessions say which ticket it was.
        if envs[key]!.gone { envs[key]!.name = envs[key]!.tmux.joined(separator: ", ") }
        let encoded = key.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        envs[key]!.lastUsed = dirs.filter { $0.hasPrefix(encoded) }.compactMap { newestFile(in: projects.appendingPathComponent($0)) }.max()
    }
    return envs.values.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
}

private func newestFile(in dir: URL) -> Date? {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
}

/// Kills each tmux session's whole process tree first: next dev and beam can outlive a bare kill-session.
func killEnv(_ env: LocalEnv) async throws {
    for session in env.tmux {
        let script = """
        tree() { for c in $(pgrep -P "$1"); do tree "$c"; done; echo "$1"; }
        pids=$(for p in $(tmux list-panes -s -t "$1" -F '#{pane_pid}'); do tree "$p"; done)
        tmux kill-session -t "$1"
        kill -TERM $pids 2>/dev/null; sleep 2; kill -KILL $pids 2>/dev/null; true
        """
        _ = try await cli(["sh", "-c", script, "sh", "=" + session])
    }
    for browser in env.browsers {
        _ = try? await cli(["agent-browser", "--session", browser, "close"])
    }
}

/// Sums a process and all its descendants from one `ps` snapshot.
private func processUsage(_ ps: Data?) -> (Int) -> (rssKB: Int, cpu: Double) {
    var children: [Int: [Int]] = [:], own: [Int: (Int, Double)] = [:]
    for line in String(decoding: ps ?? Data(), as: UTF8.self).split(separator: "\n") {
        let f = line.split(separator: " ")
        guard f.count == 4, let pid = Int(f[0]), let ppid = Int(f[1]) else { continue }
        children[ppid, default: []].append(pid)
        own[pid] = (Int(f[2]) ?? 0, Double(f[3]) ?? 0)
    }
    return { root in
        var stack = [root], total = (rssKB: 0, cpu: 0.0)
        while let pid = stack.popLast() {
            if let o = own[pid] { total.rssKB += o.0; total.cpu += o.1 }
            stack += children[pid] ?? []
        }
        return total
    }
}

/// Whole-machine CPU busy fraction since the previous sample, from the kernel's tick counters.
struct CPUSampler {
    private var last: host_cpu_load_info?

    mutating func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        defer { last = info }
        guard let p = last?.cpu_ticks else { return nil }
        let t = info.cpu_ticks  // user, system, idle, nice
        let busy = Double((t.0 &- p.0) &+ (t.1 &- p.1) &+ (t.3 &- p.3)), idle = Double(t.2 &- p.2)
        return busy + idle > 0 ? busy / (busy + idle) : nil
    }
}

/// Activity Monitor's "Memory Used": app memory + wired + compressed, as a fraction of RAM.
func memoryInUse() -> Double? {
    var s = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard r == KERN_SUCCESS else { return nil }
    let pages = UInt64(s.internal_page_count) - UInt64(s.purgeable_count) + UInt64(s.wire_count) + UInt64(s.compressor_page_count)
    return Double(pages * UInt64(vm_kernel_page_size)) / Double(ProcessInfo.processInfo.physicalMemory)
}
