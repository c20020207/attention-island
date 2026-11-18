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
    /// Memory footprint (Activity Monitor's "Memory", compressed pages included) and CPU of its process trees.
    var bytes: UInt64 = 0
    var cpu = 0.0
}

private let home = FileManager.default.homeDirectoryForCurrentUser

/// Dev servers live in tmux sessions run from a worktree's backend/ or frontend/; browsers are named cc-<worktree>-….
func scanEnvs() async -> [LocalEnv] {
    var envs: [String: LocalEnv] = [:]
    let panes = (try? await cli(["tmux", "list-panes", "-a", "-F", "#{session_name}|#{session_created}|#{pane_pid}|#{pane_current_path}"])) ?? Data()
    let usage = processUsage(try? await cli(["ps", "-axo", "pid=,ppid=,%cpu="]))
    for line in String(decoding: panes, as: UTF8.self).split(separator: "\n") {
        let f = line.split(separator: "|", maxSplits: 3).map(String.init)
        guard f.count == 4 else { continue }
        let root = f[3].replacingOccurrences(of: #"/(backend|frontend)(/.*)?$"#, with: "", options: .regularExpression)
        var env = envs[root] ?? LocalEnv(id: root, name: URL(fileURLWithPath: root).lastPathComponent)
        if !env.tmux.contains(f[0]) { env.tmux.append(f[0]) }
        let created = Date(timeIntervalSince1970: Double(f[1]) ?? 0)
        env.started = min(env.started ?? created, created)
        let tree = usage(Int(f[2]) ?? 0)
        env.bytes += tree.bytes
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
        // The session's daemon pid; Chrome and its helpers run under it.
        if let pid = (try? String(contentsOf: home.appendingPathComponent(".agent-browser/\(session).pid"), encoding: .utf8))
            .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            let tree = usage(pid)
            envs[key]!.bytes += tree.bytes
            envs[key]!.cpu += tree.cpu
        }
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

/// Sums a process and all its descendants: tree from one `ps` snapshot, memory from each pid's footprint.
private func processUsage(_ ps: Data?) -> (Int) -> (bytes: UInt64, cpu: Double) {
    var children: [Int: [Int]] = [:], cpu: [Int: Double] = [:]
    for line in String(decoding: ps ?? Data(), as: UTF8.self).split(separator: "\n") {
        let f = line.split(separator: " ")
        guard f.count == 3, let pid = Int(f[0]), let ppid = Int(f[1]) else { continue }
        children[ppid, default: []].append(pid)
        cpu[pid] = Double(f[2]) ?? 0
    }
    return { root in
        var stack = [root], total = (bytes: UInt64(0), cpu: 0.0)
        while let pid = stack.popLast() {
            guard let c = cpu[pid] else { continue }
            total.cpu += c
            total.bytes += footprint(Int32(pid))
            stack += children[pid] ?? []
        }
        return total
    }
}

private func footprint(_ pid: Int32) -> UInt64 {
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return r == 0 ? info.ri_phys_footprint : 0
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

/// Below this the memory badge hides.
let memoryThreshold = 0.8

struct CleanupReport: Decodable {
    struct Stopped: Decodable { let name: String, why: String }
    let stopped: [Stopped]
    let summary: String
}

private let cleanupSchema = """
{"type":"object","additionalProperties":false,"required":["stopped","summary"],
 "properties":{"summary":{"type":"string"},
  "stopped":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","why"],
   "properties":{"name":{"type":"string"},"why":{"type":"string"}}}}}}
"""

/// Has Claude look at what is using memory and stop what's stale. `dryRun` takes away the tools that stop things,
/// so the report says what it would have stopped.
func runCleanup(_ envs: [LocalEnv], memory: Double?, dryRun: Bool = false) async throws -> CleanupReport {
    var lines: [String] = []
    for env in envs {
        var branch = ""
        if env.id.hasPrefix("/"), !env.gone,
           let out = try? await cli(["git", "-C", env.id, "branch", "--show-current"]) {
            branch = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lines.append("""
        - \(env.name) (\(env.id))
          branch: \(branch.isEmpty ? "unknown" : branch)
          dev servers (tmux sessions): \(env.tmux.isEmpty ? "none" : env.tmux.joined(separator: ", "))
          test browsers (agent-browser sessions): \(env.browsers.isEmpty ? "none" : env.browsers.joined(separator: ", "))
          started: \(env.started.map { age($0) + " ago" } ?? "unknown")
          last Claude session activity in the worktree: \(env.lastUsed.map { age($0) + " ago" } ?? "never")
          worktree deleted: \(env.gone)
          memory: \(String(format: "%.1f GB", Double(env.bytes) / 1_073_741_824))
        """)
    }
    let prompt = """
    This Mac is using \(memory.map { "\(Int($0 * 100))%" } ?? "a lot") of its memory. \(dryRun ? "Work out" : "Free some up by stopping") \
    what is stale. Start with `top -l 1 -o mem -n 40 -stats pid,command,mem,cmprs` to see what is using it.

    Local test environments of FreshXYZ/code, grouped by git worktree:
    \(lines.joined(separator: "\n"))

    Stale: environments whose worktree is deleted; test browsers with no dev servers; environments with no Claude \
    activity for 3 hours or more; environments whose branch's PR is merged or closed (check with \
    `gh pr list --repo FreshXYZ/code --head <branch> --state all`); and other leftover background processes such as \
    orphaned dev servers, watchers or test runners. Stop an environment with `tmux kill-session -t <session>` for each \
    of its dev servers (then kill any of their processes still alive) and `agent-browser --session <name> close` for \
    each browser.

    Never touch: anything with Claude activity in the last 30 minutes; GUI apps (don't quit them, mention them in the \
    summary if they are heavy); the Claude desktop app, its virtual machine or running claude CLI sessions; system \
    processes; databases and proxies (postgres, alloydb-auth-proxy). Prefer the biggest stale users. When unsure, leave it.
    \(dryRun ? "This is a dry run: stop nothing, list what you would stop." : "")
    Report what you stopped (name and a short why) and one or two sentences on what is still using memory.
    """
    var tools = ["Bash(top:*)", "Bash(ps:*)", "Bash(lsof:*)", "Bash(tmux list-sessions:*)", "Bash(tmux list-panes:*)",
                 "Bash(agent-browser session list:*)", "Bash(gh pr list:*)", "Bash(gh pr view:*)"]
    if !dryRun { tools += ["Bash(tmux kill-session:*)", "Bash(agent-browser --session:*)", "Bash(kill:*)", "Bash(pkill:*)"] }
    let data = try await cli(["claude", "-p", prompt, "--output-format", "json", "--json-schema", cleanupSchema,
                              "--no-session-persistence", "--allowedTools"] + tools, cwd: home)
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw GHError(errorDescription: "claude returned no JSON")
    }
    if envelope["is_error"] as? Bool == true { throw GHError(errorDescription: envelope["result"] as? String ?? "claude failed") }
    guard let structured = envelope["structured_output"] else { throw GHError(errorDescription: "claude returned no report") }
    return try JSONDecoder().decode(CleanupReport.self, from: JSONSerialization.data(withJSONObject: structured))
}
