// ContextMeter — tiny always-on-top gauge of how full each Claude Code conversation's context is.
// Past a threshold it asks: "start fresh?" → writes a handoff, copies a ready-to-paste prompt that
// continues exactly where you left off, renames the new chat "<name> v2" and archives the old one.
import Cocoa
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser.path
let appDir = Bundle.main.bundleURL.deletingLastPathComponent().path   // the folder holding ContextMeter.app (config, logs, cache)
let handoffDir = home + "/Documents/Claude/handoffs"
let sessionsRoot = home + "/Library/Application Support/Claude/claude-code-sessions"
let projectsRoot = home + "/.claude/projects"

func log(_ s: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
    let path = appDir + "/debug.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
    else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
}

/// Self-update: the app folder is a git clone. Check origin now and then; "Update" pulls and rebuilds (build.sh relaunches the app).
var updateAvailable = false
func git(_ args: [String]) -> (ok: Bool, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", appDir] + args
    // Never ask for a login: if the repo moves or goes private, the update check just fails quietly.
    p.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/true", "SSH_ASKPASS": "/usr/bin/true"]) { $1 }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (false, "") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus == 0, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
func checkForUpdate(_ done: @escaping () -> Void) {
    DispatchQueue.global().async {
        guard FileManager.default.fileExists(atPath: appDir + "/.git"), git(["fetch", "--quiet", "origin"]).ok else { return }
        let behind = Int(git(["rev-list", "--count", "HEAD..@{u}"]).out) ?? 0
        if behind > 0 && !updateAvailable { log("update: \(behind) new commit(s) on origin") }
        DispatchQueue.main.async { updateAvailable = behind > 0; done() }
    }
}
func installUpdate() {
    DispatchQueue.global().async {
        let pull = git(["pull", "--ff-only", "--quiet"])
        log("update: pull \(pull.ok ? "ok" : "failed: " + pull.out)")
        guard pull.ok else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [appDir + "/build.sh"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()   // build.sh compiles, then kills this app and opens the new one
    }
}

struct Config { var ask = 40.0, red = 60.0, group = "Archive", snooze = 20.0, window: Double? = nil, pinFiles: [String] = []
    static func load() -> Config {
        var c = Config()
        if let d = FileManager.default.contents(atPath: appDir + "/config.json"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            c.ask = (j["askAtPercent"] as? Double) ?? c.ask; c.red = (j["redAtPercent"] as? Double) ?? c.red
            c.group = (j["archiveGroup"] as? String) ?? c.group; c.snooze = (j["snoozeMinutes"] as? Double) ?? c.snooze
            c.window = j["windowOverride"] as? Double; c.pinFiles = (j["pinFiles"] as? [String]) ?? []
        }
        return c
    }
}

struct Sess { var appId: String, cliId: String, title: String, cwd: String, model: String, last: Double, tokens: Int = 0, window: Int = 200_000, effort = "", mode = ""
    var cost = 0.0, lastCost = 0.0, lastAt = 0.0, saved = 0.0
    var busy = false   // mid-turn or touched in the last minute: Replace waits
    var pct: Double { min(100, Double(tokens) / Double(window) * 100) }
    /// Claude Code caches a chat for 1 hour; after that the next message re-sends the whole chat at the cache-write price.
    var cold: Bool { tokens >= 100_000 && lastAt > 0 && Date().timeIntervalSince1970 - lastAt > 3600 }
    var coldResumeCost: Double { Double(tokens) * modelPrice(model).inp * 2 / 1e6 } }

/// List prices per million tokens (Anthropic API; extra usage is billed at these rates). Cache write 1h = 2x input, 5m = 1.25x.
struct Price { let inp: Double, out: Double, read: Double }
func modelPrice(_ model: String) -> Price {
    let m = model.lowercased()
    if m.contains("fable") || m.contains("mythos") { return Price(inp: 10, out: 50, read: 0.25) }
    if m.contains("sonnet") { return Price(inp: 2, out: 10, read: 0.20) }
    if m.contains("haiku-5") { return Price(inp: 0.10, out: 0.50, read: 0.01) }
    if m.contains("haiku") { return Price(inp: 1, out: 5, read: 0.10) }
    return Price(inp: 4, out: 20, read: 0.20)   // Opus 5.5 (and the default)
}

/// Running money per transcript, read incrementally (only new bytes each tick).
final class ChatCost { var offset: UInt64 = 0, total = 0.0, lastCost = 0.0, lastId = "", lastDay = "", lastAt = 0.0, saved = 0.0
    var byDay: [String: Double] = [:], savedByDay: [String: Double] = [:] }
var chatCosts: [String: ChatCost] = [:]
let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

/// baseline = context size of the chat this one replaced; every message below it counts as money saved by Replace.
func updateCost(_ path: String, baseline: Int?) -> ChatCost {
    let c = chatCosts[path] ?? ChatCost(); chatCosts[path] = c
    autoreleasepool { readCost(path, c, baseline) }
    return c
}
func readCost(_ path: String, _ c: ChatCost, _ baseline: Int?) {
    guard let h = FileHandle(forReadingAtPath: path) else { return }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    while size > c.offset {
      let more = autoreleasepool { () -> Bool in
        try? h.seek(toOffset: c.offset)
        guard let data = try? h.read(upToCount: 8_000_000), !data.isEmpty, let nl = data.lastIndex(of: 10) else { return false }
        c.offset += UInt64(nl - data.startIndex + 1)
        for line in data[data.startIndex..<nl].split(separator: 10) {
        guard line.count > 200, line.count < 400_000, line.range(of: Data("\"usage\"".utf8)) != nil, line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil,
              let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let m = o["message"] as? [String: Any],
              let u = m["usage"] as? [String: Any] else { continue }
        let n: (String) -> Double = { (u[$0] as? Double) ?? Double((u[$0] as? Int) ?? 0) }
        let pr = modelPrice((m["model"] as? String) ?? "")
        let cc = u["cache_creation"] as? [String: Any]
        let w5 = Double((cc?["ephemeral_5m_input_tokens"] as? Int) ?? 0)
        let w1 = cc == nil ? n("cache_creation_input_tokens") : Double((cc?["ephemeral_1h_input_tokens"] as? Int) ?? 0)
        var cost = (n("input_tokens") * pr.inp + w5 * pr.inp * 1.25 + w1 * pr.inp * 2 + n("cache_read_input_tokens") * pr.read + n("output_tokens") * pr.out) / 1e6
        if (u["speed"] as? String) == "fast" { cost *= 2 }
        let ts = (o["timestamp"] as? String) ?? "", day = String(ts.prefix(10)), id = (m["id"] as? String) ?? ""
        if !id.isEmpty && id == c.lastId { c.total -= c.lastCost; c.byDay[c.lastDay, default: 0] -= c.lastCost }   // same message, later line: replace it
        else if let b = baseline, (o["isSidechain"] as? Bool) != true {
            let ctx = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            if Double(b) > ctx { let sv = (Double(b) - ctx) * pr.read / 1e6; c.saved += sv; c.savedByDay[day, default: 0] += sv }
        }
        c.total += cost; c.byDay[day, default: 0] += cost; c.lastCost = cost; c.lastId = id; c.lastDay = day
        if let t = isoFrac.date(from: ts) { c.lastAt = t.timeIntervalSince1970 }
        }
        return true
      }
      if !more { break }
    }
}

/// A chat is free to Replace only when its last turn finished (last reply ended with end_turn) and it's been quiet a minute.
/// Anything else (a tool call in flight, a message just sent) counts as busy, unless it's been silent for 15 minutes.
func isBusy(_ path: String, lastActivityMs: Double) -> Bool {
    let quiet = Date().timeIntervalSince1970 - lastActivityMs / 1000
    if quiet > 900 { return false }
    if quiet < 60 { return true }
    guard let h = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 600_000 ? size - 600_000 : 0)
    guard let data = try? h.readToEnd() else { return false }
    for line in data.split(separator: 10).reversed() {
        guard line.range(of: Data("\"isSidechain\":true".utf8)) == nil,
              line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil || line.range(of: Data("\"type\":\"user\"".utf8)) != nil,
              let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let t = o["type"] as? String, t == "assistant" || t == "user" else { continue }
        return !(t == "assistant" && ((o["message"] as? [String: Any])?["stop_reason"] as? String) == "end_turn")
    }
    return false
}

/// Replace remembers the old chat's size so the new chat's savings can be counted.
func replaceBaselines() -> [String: Int] {
    guard let d = FileManager.default.contents(atPath: appDir + "/replaces.json"), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [:] }
    var out: [String: Int] = [:]
    for r in a { if let id = r["newAppId"] as? String, let b = r["baseline"] as? Int { out[id] = b } }
    return out
}
func recordReplace(newAppId: String, baseline: Int) {
    var a = ((try? JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: appDir + "/replaces.json") ?? Data())) as? [[String: Any]]) ?? []
    guard !a.contains(where: { ($0["newAppId"] as? String) == newAppId }) else { return }
    a.append(["newAppId": newAppId, "baseline": baseline, "at": Date().timeIntervalSince1970])
    if let d = try? JSONSerialization.data(withJSONObject: a) { try? d.write(to: URL(fileURLWithPath: appDir + "/replaces.json")) }
}

/// Weekly money picture for the pill and the Sunday Slack summary (stats.json next to the app).
struct WeekStats { var spent = 0.0, saved = 0.0, top: [(String, Double)] = [], coldNow = 0 }
var weekStats = WeekStats()
var statsWrittenAt = Date.distantPast

func shortTok(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }

func transcriptPath(_ cli: String) -> String? {
    guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) else { return nil }
    for d in dirs { let p = "\(projectsRoot)/\(d)/\(cli).jsonl"; if FileManager.default.fileExists(atPath: p) { return p } }
    return nil
}

/// Last good reading per transcript, so a chat never flashes to 0% while its newest lines are huge (screenshots, big tool output).
var lastGoodTokens: [String: Int] = [:]
var tokenSizeSeen: [String: UInt64] = [:]   // unchanged file size = same answer, skip re-reading idle chats

/// Context size = last assistant turn's input + cache read + cache creation (matches the app's own number).
/// Reads from the end of the file in growing windows until it finds a usage line.
func contextTokens(_ path: String) -> Int {
    guard let h = FileHandle(forReadingAtPath: path) else { return lastGoodTokens[path] ?? 0 }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    if tokenSizeSeen[path] == size, let t = lastGoodTokens[path] { return t }
    tokenSizeSeen[path] = size
    for window: UInt64 in [600_000, 6_000_000, 40_000_000] {
        let start = size > window ? size - window : 0
        try? h.seek(toOffset: start)
        if let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self) as String? {
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"usage\""), let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], (o["isSidechain"] as? Bool) != true,
                      let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
                func n(_ k: String) -> Int { (u[k] as? Int) ?? 0 }
                let total = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
                if total > 0 { lastGoodTokens[path] = total; return total }
            }
        }
        if start == 0 { break }
    }
    return lastGoodTokens[path] ?? 0
}

/// Sidebar groups from the desktop prefs: group id → name, and session id → group id.
func sidebarGroups() -> (names: [String: String], assign: [String: String]) {
    let path = home + "/Library/Application Support/Claude/claude_desktop_config.json"
    guard let d = FileManager.default.contents(atPath: path),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let prefs = j["preferences"] as? [String: Any], let ep = prefs["epitaxyPrefs"] as? [String: Any],
          let scopes = ep["dframe-group-scopes"] else { return ([:], [:]) }
    var names = [String: String](), assign = [String: String]()
    // The prefs nest the {groups, assignments} pair at varying depth, so walk until we find it.
    func walk(_ node: Any) {
        guard let dict = node as? [String: Any] else { return }
        if let groups = dict["groups"] as? [[String: Any]], let asg = dict["assignments"] as? [String: String] {
            for g in groups { if let id = g["id"] as? String, let n = g["name"] as? String { names[id] = n } }
            for (k, v) in asg { assign[k.hasPrefix("code:") ? String(k.dropFirst(5)) : k] = v }
            return
        }
        for (_, v) in dict { walk(v) }
    }
    walk(scopes)
    return (names, assign)
}

/// Session ids filed under the archive group in the app's sidebar.
func archivedIds(_ group: String) -> Set<String> {
    let g = sidebarGroups()
    guard let gid = g.names.first(where: { $0.value == group })?.key else { return [] }
    return Set(g.assign.filter { $0.value == gid }.keys)
}

/// Optional: other tools that pin a chat by link (a JSON file with a "chatLink" key, listed in config.json → "pinFiles")
/// follow the new chat when the pinned one is replaced.
func retargetPins(from old: String, to new: String) {
    for raw in Config.load().pinFiles { retargetPin(raw.hasPrefix("~") ? home + raw.dropFirst() : raw, from: old, to: new) }
}
func retargetPin(_ path: String, from old: String, to new: String) {
    guard let d = FileManager.default.contents(atPath: path),
          var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let link = j["chatLink"] as? String, link.hasSuffix(old) else { return }
    j["chatLink"] = link.replacingOccurrences(of: old, with: new)
    if let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) { try? out.write(to: URL(fileURLWithPath: path), options: .atomic); log("pinned chat link moved \(old) -> \(new)") }
}

/// App session id of the newest session with exactly this title, if any.
func findSession(title: String, createdAfter: Double = 0) -> String? {
    guard let en = FileManager.default.enumerator(atPath: sessionsRoot) else { return nil }
    var best: (Double, String)?
    for case let rel as String in en where rel.hasSuffix(".json") && rel.contains("local_") {
        guard let d = FileManager.default.contents(atPath: sessionsRoot + "/" + rel),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (j["title"] as? String) == title, let id = j["sessionId"] as? String else { continue }
        let t = (j["createdAt"] as? Double) ?? 0
        if t >= createdAfter && t > (best?.0 ?? 0) { best = (t, id) }
    }
    return best?.1
}

func loadSessions(_ cfg: Config) -> [Sess] {
    var out: [Sess] = []
    let hidden = archivedIds(cfg.group)
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: sessionsRoot) else { return [] }
    let cutoff = Date().timeIntervalSince1970 * 1000 - 7 * 24 * 3600 * 1000   // list chats active in the last week
    let baselines = replaceBaselines()
    var week = WeekStats(), perChat: [(String, Double)] = []
    let days: Set<String> = Set((0..<7).map { String(isoFrac.string(from: Date().addingTimeInterval(-Double($0) * 86400)).prefix(10)) })
    for case let rel as String in en where rel.hasSuffix(".json") && rel.contains("local_") {
        guard let d = fm.contents(atPath: sessionsRoot + "/" + rel),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let cli = j["cliSessionId"] as? String,
              let last = j["lastActivityAt"] as? Double, last > cutoff else { continue }
        let appId = (j["sessionId"] as? String) ?? ""
        var cc: ChatCost?
        if let p = transcriptPath(cli) {
            let c = updateCost(p, baseline: baselines[appId]); cc = c
            let w = c.byDay.filter { days.contains($0.key) }.values.reduce(0, +)
            week.spent += w; week.saved += c.savedByDay.filter { days.contains($0.key) }.values.reduce(0, +)
            if w > 0.005 { perChat.append(((j["title"] as? String) ?? "Untitled", w)) }
        }
        guard (j["isArchived"] as? Bool) != true, !hidden.contains(appId) else { continue }
        let model = (j["model"] as? String) ?? ""
        var s = Sess(appId: (j["sessionId"] as? String) ?? "", cliId: cli, title: (j["title"] as? String) ?? "Untitled",
                     cwd: (j["cwd"] as? String) ?? home, model: model, last: last)
        s.effort = (j["effort"] as? String) ?? ""; s.mode = (j["permissionMode"] as? String) ?? ""
        s.window = Int(cfg.window ?? (model.range(of: #"(opus|sonnet|fable)-5"#, options: .regularExpression) != nil || model.contains("[1m]") ? 1_000_000 : 200_000))
        if let p = transcriptPath(cli) { s.tokens = contextTokens(p) }
        if let c = cc { s.cost = c.total; s.lastCost = c.lastCost; s.lastAt = c.lastAt; s.saved = c.saved }
        if let p = transcriptPath(cli) { s.busy = isBusy(p, lastActivityMs: last) }
        if s.cold { week.coldNow += 1 }
        out.append(s)
    }
    week.top = Array(perChat.sorted { $0.1 > $1.1 }.prefix(5))
    weekStats = week
    if Date().timeIntervalSince(statsWrittenAt) > 300 {
        statsWrittenAt = Date()
        let j: [String: Any] = ["at": Date().timeIntervalSince1970, "weekSpent": week.spent, "weekSaved": week.saved, "coldNow": week.coldNow,
                                "top": week.top.map { ["title": $0.0, "cost": $0.1] }]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: appDir + "/stats.json")) }
    }
    return out.sorted { $0.last > $1.last }
}

func nextTitle(_ t: String) -> String {
    if let r = t.range(of: #" v(\d+)$"#, options: .regularExpression), let n = Int(t[r].dropFirst(2)) { return t[..<r.lowerBound] + " v\(n + 1)" }
    return t + " v2"
}

/// "$2,193 of $3.5k" -> (2193, 3500)
func parseDollars(_ s: String) -> (Double, Double) {
    let parts = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").components(separatedBy: " of ")
    func num(_ t: String) -> Double { let t = t.trimmingCharacters(in: .whitespaces); return t.hasSuffix("k") ? (Double(t.dropLast()) ?? 0) * 1000 : Double(t) ?? 0 }
    return parts.count == 2 ? (num(parts[0]), num(parts[1])) : (0, 0)
}
struct Acct { var pct: Double; var sub: String; var used: Double = 0; var limit: Double = 0 }

/// Account dollars over time (usage-history.json, about one sample an hour), so the pace follows recent spending, not the month's average.
var usageHistory: [[Double]] = {
    guard let d = FileManager.default.contents(atPath: appDir + "/usage-history.json"), let h = try? JSONSerialization.jsonObject(with: d) as? [[Double]] else { return [] }
    return h.filter { $0.count == 2 }
}()
func recordUsage(_ used: Double) {
    let now = Date().timeIntervalSince1970
    if let last = usageHistory.last, used < last[1] - 1 { usageHistory = [] }          // the limit reset: start over
    if let last = usageHistory.last, now - last[0] < 3600 { return }
    usageHistory.append([now, used]); usageHistory = usageHistory.filter { now - $0[0] < 35 * 86400 }
    if let d = try? JSONSerialization.data(withJSONObject: usageHistory) { try? d.write(to: URL(fileURLWithPath: appDir + "/usage-history.json")) }
}
/// Dollars per second over the last 7 days, once there are at least 36 hours of samples; nil until then.
func recentRate(_ used: Double) -> Double? {
    let now = Date().timeIntervalSince1970
    guard let first = usageHistory.first(where: { now - $0[0] <= 7 * 86400 }), now - first[0] >= 36 * 3600 else { return nil }
    return max(0, used - first[1]) / (now - first[0])
}

/// Whole-account usage from Anthropic, using the Claude Code login already in the Keychain (read-only, never logged).
var cachedToken: String?, cachedExpiry: Double = 0

func fetchAccount() -> Acct? {
    // Read through Apple's own `security` tool: its signature never changes, so the Keychain approval survives every rebuild of this app.
    // The token is only held in memory and refreshed when it expires.
    if cachedToken == nil || cachedExpiry < Date().timeIntervalSince1970 * 1000 + 60_000 {
        // Stray entries (e.g. account "unknown") can shadow the real login, so try this Mac user's entry first, then any entry.
        var found: [String: Any]?, status: Int32 = 0
        for acct in [NSUserName(), nil] as [String?] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", "Claude Code-credentials"] + (acct.map { ["-a", $0] } ?? []) + ["-w"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { log("usage: cannot run security"); return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            status = p.terminationStatus
            if status == 0, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let o = j["claudeAiOauth"] as? [String: Any], o["accessToken"] is String { found = o; break }
        }
        guard let o = found, let t = o["accessToken"] as? String else { log("usage: keychain read failed (\(status))"); return nil }
        cachedToken = t; cachedExpiry = (o["expiresAt"] as? Double) ?? 0
        if cachedExpiry < Date().timeIntervalSince1970 * 1000 { log("usage: token expired, waiting for Claude to refresh it"); cachedToken = nil; return nil }
    }
    guard let tok = cachedToken else { return nil }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
    req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization"); req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Accept"); req.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
    var result: Acct?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { d, resp, _ in
        defer { sem.signal() }
        guard let d, (resp as? HTTPURLResponse)?.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { log("usage: request failed"); cachedToken = nil; return }
        // Subscription windows (5-hour / weekly) when the plan has them, otherwise the extra-usage budget.
        var best: (Double, String)?
        for (k, label) in [("five_hour", "5h"), ("seven_day", "week")] {
            if let w = j[k] as? [String: Any], let u = w["utilization"] as? Double, u > (best?.0 ?? -1) { best = (u, label) }
        }
        if let b = best { result = Acct(pct: b.0, sub: b.1); return }
        if let e = j["extra_usage"] as? [String: Any], (e["is_enabled"] as? Bool) == true, let u = e["utilization"] as? Double {
            let dec = pow(10.0, Double((e["decimal_places"] as? Int) ?? 2))
            let used = ((e["used_credits"] as? Double) ?? 0) / dec, lim = ((e["monthly_limit"] as? Double) ?? 0) / dec
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            let usedS = f.string(from: NSNumber(value: used)) ?? "0"
            let limS = lim >= 1000 ? String(format: "%.1fk", lim / 1000) : f.string(from: NSNumber(value: lim)) ?? ""
            result = Acct(pct: u, sub: "$\(usedS) of $\(limS)", used: used, limit: lim)
        }
    }.resume()
    sem.wait()
    return result
}

/// Cubic-bezier easing (same maths as CSS / Flow curves).
func bezier(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ t: CGFloat) -> CGFloat {
    func pt(_ a: CGFloat, _ b: CGFloat, _ u: CGFloat) -> CGFloat { 3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u }
    var lo: CGFloat = 0, hi: CGFloat = 1
    for _ in 0..<24 { let m = (lo + hi) / 2; if pt(x1, x2, m) < t { lo = m } else { hi = m } }
    return pt(y1, y2, (lo + hi) / 2)
}
let flowIn: (CGFloat) -> CGFloat = { bezier(0, 0.48, 0.02, 0.99, $0) }      // Flow 6
let flowOut: (CGFloat) -> CGFloat = { bezier(1, 0.002, 0.992, 0.588, $0) }  // Flow 9

enum Look {
    static let blue = NSColor(calibratedRed: 0.20, green: 0.53, blue: 0.96, alpha: 1)
    static let amber = NSColor(calibratedRed: 1, green: 0.70, blue: 0.20, alpha: 1)
    static let red = NSColor(calibratedRed: 1, green: 0.34, blue: 0.34, alpha: 1)
    static func font(_ s: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { NSFont(name: "ABCFavoritSS-Book", size: s) ?? .systemFont(ofSize: s, weight: w) }
}

enum Mode { case idle, expanded, help, asking, working, done }

final class MeterView: NSView {
    var cfg = Config.load(), sessions: [Sess] = [], mode = Mode.idle, message = "", handoffText = ""
    var doneTitle = "Copied to clipboard ✓", doneSub = "Open a new chat and paste (⌘V)."
    var snoozed: [String: Date] = [:], asked = Set<String>()
    var hits: [(NSRect, () -> Void)] = []
    var onResize: ((CGSize) -> Void)?
    /// Card width the user sees. The window is only resized when hover starts/ends; the reveal itself is just drawing.
    var logicalWidth: CGFloat = 168, lastWindowSize = CGSize.zero
    var cw: CGFloat { drawW }
    // Animated card size: the window jumps once, the drawn card eases between sizes.
    var drawW: CGFloat = 168, drawH: CGFloat = 40, drawMode: Mode = .idle, prevMode: Mode = .idle
    var tween: (fw: CGFloat, fh: CGFloat, tw: CGFloat, th: CGFloat, start: Date, dur: Double)?
    var lastTarget = CGSize.zero, lastInside = Date(), doneSince: Date?
    var loadBusy = false
    var frozen = false, profiling = ProcessInfo.processInfo.environment["CM_PROFILE"] != nil
    // Hover reveal for the Replace option on a row.
    var rowT = [CGFloat](repeating: 0, count: 8), pinned = -1, lastStep = Date()   // one eased value per row, so scrubbing glides
    let baseListWidth: CGFloat = 304, revealWidth: CGFloat = 92, paceH: CGFloat = 20
    func ease(_ t: CGFloat) -> CGFloat { bezier(0.65, 0, 0.35, 1, t) }   // smooth ease in-out
    var sweepStart = Date()
    // Edge dock: drag the pill to a screen edge and it tucks in as a thin line; hover opens it, a coloured line means look at it.
    var dock = UserDefaults.standard.integer(forKey: "dock")   // -1 left edge, 1 right edge, 0 free
    var docked: Bool { dock != 0 }
    var peek = false, peekUntil = Date.distantPast, lastOX: CGFloat = 0
    let sliverW: CGFloat = 5, edgeReach: CGFloat = 24
    /// 0 = fine, 1 = amber (a chat is full, or the account passed 65%), 2 = red (a chat is nearly out, or the account passed 85%).
    var alertLevel: Int {
        let acctL = (acct?.pct ?? 0) >= 85 ? 2 : (acct?.pct ?? 0) >= 65 ? 1 : 0
        return max(acctL, chatAlert)
    }
    var chatAlert: Int { fullChats.contains { $0.pct >= cfg.red } ? 2 : fullChats.isEmpty ? 0 : 1 }
    func alertColor() -> NSColor { switch alertLevel { case 2: return Look.red; case 1: return Look.amber; default: return NSColor(white: 1, alpha: 0.5) } }
    /// Where the card sits inside its window: flush right when docked on the right (the window can be wider than the card mid-animation).
    func cardOffset() -> CGFloat { dock == 1 ? bounds.width - drawW : 0 }
    func snapDock() {
        guard let w = window, let scr = w.screen ?? NSScreen.main else { return }
        let f = w.frame, e = scr.frame
        let nd = f.minX <= e.minX + edgeReach ? -1 : f.maxX >= e.maxX - edgeReach ? 1 : 0
        if nd != dock { dock = nd; UserDefaults.standard.set(nd, forKey: "dock"); peek = nd != 0; peekUntil = Date().addingTimeInterval(0.9); if nd != 0 { mini = false } }
        relayout(); onResize?(lastWindowSize)
    }
    // List ↔ guide swap: rows fade and rise in one after another; the "?" lights up under the pointer.
    var swapStart = Date.distantPast, helpHover: CGFloat = 0, helpRect = NSRect.zero
    let swapStagger = 0.035, swapDur = 0.34
    func rowIn(_ i: Int) -> CGFloat {
        let t = Date().timeIntervalSince(swapStart) - Double(i) * swapStagger
        return bezier(0.2, 0.7, 0.2, 1, CGFloat(max(0, min(1, t / swapDur))))   // quick out, long soft landing
    }
    /// Draws one row of the list or guide at its entrance progress: faded and a few points low until it lands.
    func entering(_ i: Int, _ body: () -> Void) {
        let p = rowIn(i)
        guard p < 1, let cg = NSGraphicsContext.current?.cgContext else { body(); return }
        cg.saveGState(); cg.setAlpha(p); cg.translateBy(x: 0, y: -7 * (1 - p)); body(); cg.restoreGState()
    }
    func stepAnim() {
        let now = Date(); let dt = CGFloat(now.timeIntervalSince(lastStep)); lastStep = now
        if now.timeIntervalSince(swapStart) < swapDur + 10 * swapStagger + 0.05 { needsDisplay = true }
        if let w = window {
            var mp = convert(w.mouseLocationOutsideOfEventStream, from: nil); mp.x -= lastOX
            let over: CGFloat = (mode == .expanded || mode == .help) && helpRect.insetBy(dx: -6, dy: -6).contains(mp) ? 1 : 0
            if helpHover != over { helpHover = over > helpHover ? min(over, helpHover + dt / 0.12) : max(over, helpHover - dt / 0.18); needsDisplay = true }
        }
        if let t = tween {                                        // ease the drawn card between sizes
            let p = min(1, CGFloat(now.timeIntervalSince(t.start) / t.dur))
            let edge = docked && mode == .idle && (t.fw <= sliverW + 0.5 || t.tw <= sliverW + 0.5)
            let opening = t.tw > t.fw
            let e = edge && opening ? 1 - exp(-6 * p) * (cos(6.2 * p) + 0.968 * sin(6.2 * p))   // line → pill: a soft start, a quick pull out, one small settle (damped spring)
                  : edge ? bezier(0.5, 0, 0.2, 1, p)                                          // pill → line: eased fold, words leave first
                  : tweenFlow ? bezier(0.45, 0, 0.15, 1, p) : bezier(0.65, 0, 0.35, 1, p)   // circle morph: soft start, long calm settle
            drawW = t.fw + (t.tw - t.fw) * e; drawH = t.fh + (t.th - t.fh) * e
            if p >= 1 {
                tween = nil; tweenFlow = false; drawW = t.tw; drawH = t.th; drawMode = mode
                let size = CGSize(width: t.tw, height: t.th)       // shrink the window once, at the end
                if size != lastWindowSize { lastWindowSize = size; onResize?(size) }
            }
            needsDisplay = true
        }
        // Close by itself: the list after the pointer leaves, the finished card after a few seconds.
        let inside = window?.frame.contains(NSEvent.mouseLocation) ?? false
        var zone = window?.frame ?? .zero
        if docked && !peek && mode == .idle { zone = zone.insetBy(dx: -18, dy: -12) }          // the line wakes up as the pointer nears it
        let near = zone.contains(NSEvent.mouseLocation)
        if let w = window {
            let target: CGFloat = inside || mode != .idle ? 1 : docked ? (alertLevel > 0 ? 1 : 0.75) : 0.5
            if abs(w.alphaValue - target) > 0.005 { w.alphaValue += (target - w.alphaValue) * min(1, dt * 7) } else if w.alphaValue != target { w.alphaValue = target }
        }
        if docked && mode == .idle && !profiling && !frozen {                // the line opens while the pointer is on it, closes half a second after
            if near { peekUntil = now.addingTimeInterval(0.5) }
            let want = near || now < peekUntil
            if want != peek { peek = want; relayout() }
            if !peek && chatAlert > 0 { needsDisplay = true }       // the line breathes while a chat needs Replace
        }
        if (mode == .expanded || mode == .help) && pinned < 0 && !profiling && !frozen {
            if inside { lastInside = now } else if now.timeIntervalSince(lastInside) > 1.0 { mode = .idle; relayout() }
        }
        if mode == .done {
            if doneSince == nil { doneSince = now }
            if inside { doneSince = now } else if now.timeIntervalSince(doneSince!) > 6 { mode = .idle; doneSince = nil; relayout() }
        } else { doneSince = nil }
        if mode != .expanded { if rowT.contains(where: { $0 != 0 }) { rowT = [CGFloat](repeating: 0, count: 8); needsDisplay = true }; return }
        var under = -1
        if pinned >= 0 { under = pinned }
        else if profiling { under = Int(Date().timeIntervalSince(sweepStart) / 0.35) % 8 }
        else if let w = window, w.frame.contains(NSEvent.mouseLocation) { var mp = convert(w.mouseLocationOutsideOfEventStream, from: nil); mp.x -= lastOX; under = rowAt(mp) }
        var moved = false
        for i in 0..<rowT.count {
            let target: CGFloat = i == under ? 1 : 0
            let rate = dt / (target > rowT[i] ? 0.20 : 0.26)           // opens a touch faster than it closes
            let next = target > rowT[i] ? min(target, rowT[i] + rate) : max(target, rowT[i] - rate)
            if next != rowT[i] { rowT[i] = next; moved = true }
        }
        if moved { needsDisplay = true }
    }
    func rowAt(_ pt: NSPoint) -> Int {
        guard mode == .expanded else { return -1 }
        let top = bounds.height - 40
        for i in 0..<min(sessions.count, 8) where NSRect(x: 0, y: top - paceH - 26 * CGFloat(i + 1), width: cw, height: 26).contains(pt) { return i }
        return -1
    }
    /// Last good account usage (kept on disk) so the pill never falls back to a chat percent when the login is briefly expired.
    var acct: Acct? = {
        guard let d = FileManager.default.contents(atPath: appDir + "/usage-cache.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let p = j["pct"] as? Double, let sub = j["sub"] as? String else { return nil }
        var a = Acct(pct: p, sub: sub, used: (j["used"] as? Double) ?? 0, limit: (j["limit"] as? Double) ?? 0)
        if a.limit == 0 { (a.used, a.limit) = parseDollars(sub) }   // older cache: read "$2,193 of $3.5k"
        return a
    }(), acctFetched = Date.distantPast, acctBusy = false
    // The header is always account money, never a chat's tokens: last known dollars (kept on disk), or a dash until the first reading.
    var headPct: Double { acct?.pct ?? 0 }
    var headPctText: String { acct == nil ? "–%" : "\(Int(headPct.rounded()))%" }
    var headSub: String { acct?.sub ?? "$ –" }
    func headColor() -> NSColor { acct == nil ? NSColor(white: 0.4, alpha: 1) : headPct >= 85 ? Look.red : headPct >= 65 ? Look.amber : Look.blue }
    func measure(_ s: String, _ size: CGFloat, _ w: NSFont.Weight = .regular) -> CGFloat { (s as NSString).size(withAttributes: [.font: Look.font(size, w)]).width }
    /// Width of the header strip: ring + percent + tokens, sized to its content.
    var headerWidth: CGFloat {
        guard primary != nil || acct != nil else { return 140 }
        return 42 + measure(headPctText, 14, .semibold) + 10 + measure(headSub, 12) + 18
    }
    var primary: Sess? { sessions.first }
    /// Chats worth replacing: at or past the Replace line, not archived (loadSessions drops those), used in the last day. The count everywhere comes from here.
    var fullChats: [Sess] { sessions.filter { $0.pct >= cfg.ask && $0.last > Date().timeIntervalSince1970 * 1000 - 24 * 3600 * 1000 } }
    var fullCount: Int { fullChats.count }
    /// Exactly one full chat and it is the one in front: the pill offers Replace for it. Otherwise it shows "N full" and opens the list.
    var needsReplace: Bool { fullCount == 1 && (primary?.pct ?? 0) >= cfg.ask }
    var otherFull: Bool { !needsReplace && fullCount > 0 }

    func color(_ pct: Double) -> NSColor { pct >= cfg.red ? Look.red : pct >= cfg.ask ? Look.amber : Look.blue }

    func tick() {
        cfg = Config.load()
        if !acctBusy, Date().timeIntervalSince(acctFetched) > (acct == nil ? 60 : 120) {
            acctBusy = true
            DispatchQueue.global().async {
                let a = fetchAccount()
                DispatchQueue.main.async {
                    if let a { self.acct = a; recordUsage(a.used); try? JSONSerialization.data(withJSONObject: ["pct": a.pct, "sub": a.sub, "used": a.used, "limit": a.limit, "at": Date().timeIntervalSince1970]).write(to: URL(fileURLWithPath: appDir + "/usage-cache.json")) }
                    self.acctFetched = Date(); self.acctBusy = false; self.relayout() }
            }
        }
        if loadBusy { return }
        loadBusy = true
        DispatchQueue.global().async {
            let s = loadSessions(self.cfg)
            DispatchQueue.main.async {
                self.loadBusy = false
                self.sessions = s
                if !self.frozen, !self.docked, self.mode == .idle || self.mode == .expanded, let p = s.first, p.pct >= self.cfg.ask, !p.busy,
                   (self.snoozed[p.appId] ?? .distantPast) < Date(), !self.asked.contains(p.appId) {
                    self.mode = .asking; self.asked.insert(p.appId); NSSound(named: "Tink")?.play()
                }
                if let p = s.first, p.pct < self.cfg.ask * 0.6 { self.asked.remove(p.appId) }
                self.relayout()
            }
        }
    }

    /// The short guide: icon key + one line each.
    let helpRows: [(String, String)] = [
        ("ring", "Your account this month: % used and dollars"),
        ("pace", "Where this month is heading · what Replace saved"),
        ("bar", "How full a chat is. Amber = time to Replace"),
        ("cold", "Idle 1h+: the next message costs 20–40× more"),
        ("replace", "Hover a chat → Replace: fresh chat, same work"),
        ("money", "What that chat has cost so far"),
        ("dock", "Drag to a screen edge: hides as a line, hover opens"),
        ("top", "Click the top to open · click the ring to shrink"),
    ]
    /// Small round "?" at the bottom right: opens the guide, or goes back to the list.
    func helpButton(active: Bool) {
        let base = NSRect(x: cw - 14 - 16, y: bounds.height - drawH + 5, width: 16, height: 16)
        helpRect = base
        let h = ease(helpHover), pop = 1 - rowIn(0)                  // grows a little on hover, pulses as the view swaps
        let r = base.insetBy(dx: -1.5 * h - 2 * pop, dy: -1.5 * h - 2 * pop)
        (active ? Look.blue : NSColor(white: 1, alpha: 0.12 + 0.16 * h)).setFill(); NSBezierPath(ovalIn: r).fill()
        let q = NSAttributedString(string: active ? "✕" : "?", attributes: [.font: NSFont.systemFont(ofSize: active ? 8 : 10, weight: .bold), .foregroundColor: NSColor(white: 1, alpha: active ? 1 : 0.7 + 0.3 * h)])
        q.draw(at: NSPoint(x: r.midX - q.size().width / 2, y: r.midY - q.size().height / 2))
        hits.append((base.insetBy(dx: -10, dy: -8), { [weak self] in self?.mode = active ? .expanded : .help; self?.relayout() }))
    }
    func money(_ x: Double) -> String { x >= 1000 ? String(format: "$%.1fk", x / 1000) : x >= 10 ? String(format: "$%.0f", x) : String(format: "$%.2f", x) }
    /// "On pace for $3.1k this month · saved $42 this week" — red when this month's pace runs past the limit.
    func paceLine() -> (String, NSColor)? {
        var parts: [String] = [], c = NSColor(white: 0.55, alpha: 1)
        if let a = acct, a.limit > 0, a.used > 0, let m = Calendar.current.dateInterval(of: .month, for: Date()) {
            // Last 7 days' spend rate when we have it (reacts to new habits), else the month's average so far.
            let el = Date().timeIntervalSince(m.start), rate = recentRate(a.used) ?? a.used / max(el, 0.02 * m.duration)
            let proj = a.used + rate * m.end.timeIntervalSinceNow, wk = recentRate(a.used) != nil ? "this week's" : "this"
            if a.used >= a.limit { parts.append("Limit reached · \(money(a.used - a.limit)) over"); c = Look.red }
            else if proj > a.limit {
                let f = DateFormatter(); f.dateFormat = "MMM d"
                parts.append("At \(wk) pace you hit \(money(a.limit)) ~\(f.string(from: Date().addingTimeInterval((a.limit - a.used) / rate)))"); c = Look.red
            } else { parts.append("On \(wk) pace: \(money(proj)) this month") }
        } else if weekStats.spent > 0 { parts.append("\(money(weekStats.spent)) this week") }
        if weekStats.saved >= 0.5 { parts.append("saved \(money(weekStats.saved))") }
        return parts.isEmpty ? nil : (parts.joined(separator: " · "), c)
    }

    /// Minimised: just the ring, as a 40pt circle (remembered). Click the ring to shrink, click the circle to grow back.
    var mini = UserDefaults.standard.bool(forKey: "mini") { didSet { UserDefaults.standard.set(mini, forKey: "mini"); tweenFlow = true } }
    var tweenFlow = false   // the circle morph gets its own softer, slower curve

    func relayout() {
        var h: CGFloat = 40, w: CGFloat = headerWidth
        switch mode {
        case .idle:
            if docked && !peek { w = sliverW }
            else if mini && !docked { w = 40 } else if needsReplace || otherFull { w += 92 }
        case .expanded:
            h = 40 + paceH + CGFloat(min(sessions.count, 8)) * 26 + 8 + 18   // + pace line + credit line
            w = max(headerWidth + 16, baseListWidth)
        case .help: h = 40 + 30 + CGFloat(helpRows.count) * 24 + 8 + 18; w = max(headerWidth + 16, baseListWidth)
        case .asking: h = 40 + 124; w = 312
        case .working: h = 40 + 62; w = 312
        case .done: h = 40 + 124; w = 312
        }
        logicalWidth = w
        let target = CGSize(width: w, height: h)
        if mode == .expanded && prevMode != .expanded { lastInside = Date() }
        let swap = (mode == .help && prevMode == .expanded) || (mode == .expanded && prevMode == .help)
        if swap { swapStart = Date(); lastInside = Date() }
        prevMode = mode
        if lastTarget == .zero {                                  // first layout: no animation
            lastTarget = target; drawW = w; drawH = h; drawMode = mode
            lastWindowSize = target; onResize?(target)
        } else if target != lastTarget {
            let shrinking = h < drawH
            lastTarget = target
            if !shrinking || swap { drawMode = mode }             // keep old content while closing; list ↔ guide swaps at once
            let edgeMove = docked && mode == .idle && (drawW <= sliverW + 0.5 || w <= sliverW + 0.5)
            tween = (drawW, drawH, w, h, Date(), edgeMove ? (w > drawW ? 0.7 : 0.4) : tweenFlow ? 0.6 : shrinking ? 0.26 : 0.30)
            let big = CGSize(width: max(w, drawW), height: max(h, drawH))
            if big != lastWindowSize { lastWindowSize = big; onResize?(big) }
        } else if tween == nil || swap { drawMode = mode }
        needsDisplay = true
    }

    func ring(_ c: NSPoint, _ r: CGFloat, _ pct: Double, _ col: NSColor, _ lw: CGFloat) {
        let bg = NSBezierPath(); bg.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360); bg.lineWidth = lw
        NSColor(white: 1, alpha: 0.14).setStroke(); bg.stroke()
        let a = NSBezierPath(); a.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - CGFloat(max(pct, 2) / 100 * 360), clockwise: true)
        a.lineWidth = lw; a.lineCapStyle = .round; col.setStroke(); a.stroke()
    }

    func spinner(_ c: NSPoint, _ r: CGFloat, _ col: NSColor) {
        let t = Date().timeIntervalSinceReferenceDate
        let bg = NSBezierPath(); bg.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360); bg.lineWidth = 3.2
        NSColor(white: 1, alpha: 0.14).setStroke(); bg.stroke()
        let start = CGFloat(-(t * 330).truncatingRemainder(dividingBy: 360))
        let a = NSBezierPath(); a.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: start - 110, clockwise: true)
        a.lineWidth = 3.2; a.lineCapStyle = .round; col.setStroke(); a.stroke()
    }

    /// Soft light that glides across a thin track — the "working" shimmer.
    func shimmer(_ r: NSRect) {
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(white: 1, alpha: 0.08).setFill(); track.fill()
        let t = Date().timeIntervalSinceReferenceDate / 1.5
        let f = CGFloat(t - floor(t))
        let e = f < 0.5 ? 4 * f * f * f : 1 - pow(-2 * f + 2, 3) / 2          // ease in-out
        let sw: CGFloat = 110
        let x = r.minX - sw + (r.width + sw) * e
        NSGraphicsContext.saveGraphicsState(); track.addClip()
        NSGradient(colors: [Look.blue.withAlphaComponent(0), Look.blue, Look.blue.withAlphaComponent(0)])?
            .draw(in: NSRect(x: x, y: r.minY, width: sw, height: r.height), angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }

    func text(_ s: String, _ p: NSPoint, _ size: CGFloat, _ col: NSColor = .white, _ w: NSFont.Weight = .regular, width: CGFloat? = nil) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let at: [NSAttributedString.Key: Any] = [.font: Look.font(size, w), .foregroundColor: col, .paragraphStyle: para]
        if let width { NSAttributedString(string: s, attributes: at).draw(in: NSRect(x: p.x, y: p.y, width: width, height: size * 1.4)) }
        else { NSAttributedString(string: s, attributes: at).draw(at: p) }
    }

    func button(_ label: String, _ r: NSRect, _ fill: NSColor, _ act: @escaping () -> Void) {
        let b = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2); fill.setFill(); b.fill()
        let sz = (label as NSString).size(withAttributes: [.font: Look.font(12, .medium)])
        text(label, NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), 12, .white, .medium)
        hits.append((r, act))
    }

    var drawTimes: [Double] = []
    override func draw(_ dirtyRect: NSRect) {
        let t0 = CACurrentMediaTime(); defer {
            if profiling { drawTimes.append((CACurrentMediaTime() - t0) * 1000); if drawTimes.count == 120 { log("draw ms avg=\(drawTimes.reduce(0, +) / 120) max=\(drawTimes.max() ?? 0)"); drawTimes = [] } }
        }
        hits = []
        lastOX = cardOffset()
        if lastOX != 0 { NSGraphicsContext.current?.cgContext.translateBy(x: lastOX, y: 0) }
        // Docked: the card's outer side runs off the screen edge, so it reads as a tab attached to the edge; narrowed to a line it turns into the status colour.
        var cr = NSRect(x: 0, y: bounds.height - drawH, width: cw, height: drawH)
        if dock == 1 { cr.size.width += 30 } else if dock == -1 { cr.origin.x -= 30; cr.size.width += 30 }
        let rad: CGFloat = docked ? min(20, max(2.5, cw / 2)) : 20
        let line: CGFloat = docked && drawMode == .idle ? max(0, min(1, (drawW - sliverW) / 30)) : 1   // 0 = the line, 1 = the card
        let pulse: CGFloat = docked && !peek && chatAlert > 0 ? 0.72 + 0.28 * CGFloat(sin(Date().timeIntervalSinceReferenceDate * 2.8)) : 1
        let card = NSBezierPath(roundedRect: cr.insetBy(dx: 0.5, dy: 0.5), xRadius: rad, yRadius: rad)
        NSColor(calibratedWhite: 0.105, alpha: 1).setFill(); card.fill()
        NSColor(white: 1, alpha: 0.12 * line).setStroke(); card.lineWidth = 1; card.stroke()
        card.addClip()   // content never spills outside the card while it grows or shrinks
        if docked {      // the status line stays on the attached side as the card opens, so the card reads as growing out of the line
            let sw = 5 - 2 * line
            let r = NSRect(x: dock == 1 ? cw - sw : -30, y: bounds.height - drawH, width: dock == 1 ? sw + 30 : sw + 30, height: drawH)
            alertColor().withAlphaComponent(alertLevel > 0 ? pulse : 1).setFill(); r.fill()
        }
        let opened: CGFloat = docked && drawMode == .idle ? max(0, min(1, (drawW - 0.4 * headerWidth) / max(1, 0.6 * headerWidth))) : 1   // words arrive once the card is mostly out, leave first on the way back
        let dockFade = opened * opened * (3 - 2 * opened)
        if dockFade < 1 {
            let cg = NSGraphicsContext.current?.cgContext
            cg?.setAlpha(dockFade); cg?.translateBy(x: (1 - dockFade) * 16 * (dock == 1 ? 1 : -1), y: 0)   // they slide in from the edge
        }
        let top = bounds.height - 40   // header strip is the top 40pt (y-up)
        // m = how far the pill has morphed into the circle (0 = full header, 1 = circle), read from the drawn width.
        let fullW = headerWidth + ((needsReplace || otherFull) ? 92 : 0)
        let m: CGFloat = mode == .idle && drawMode == .idle && !docked ? max(0, min(1, (fullW - drawW) / max(1, fullW - 40))) : 0
        let wantsReplace = needsReplace || otherFull
        if m > 0.001 && wantsReplace {   // amber dot = a chat wants Replace
            Look.amber.withAlphaComponent(min(1, m * 1.6)).setFill()
            NSBezierPath(ovalIn: NSRect(x: 27 + 4 * (1 - m), y: top + 26, width: 7, height: 7)).fill()
        }
        if m >= 0.999 {
            ring(NSPoint(x: 20, y: top + 20), 9, headPct, headColor(), 3.2)
            if wantsReplace { Look.amber.setFill(); NSBezierPath(ovalIn: NSRect(x: 27, y: top + 26, width: 7, height: 7)).fill() }
            hits.append((NSRect(x: 0, y: top, width: cw, height: 40), { [weak self] in self?.mini = false; self?.relayout() }))
            return
        }
        if let p = primary {
            if mode == .working { spinner(NSPoint(x: 24, y: top + 20), 9, Look.blue) }
            else { ring(NSPoint(x: 24 - 4 * m, y: top + 20), 9, headPct, headColor(), 3.2) }
            NSGraphicsContext.current?.cgContext.setAlpha(dockFade * max(0, 1 - m * 1.8))   // words and buttons leave first, come back last
            text(headPctText, NSPoint(x: 42, y: top + 11), 14, .white, .semibold)
            text(headSub, NSPoint(x: 42 + measure(headPctText, 14, .semibold) + 10, y: top + 12), 12, NSColor(white: 0.62, alpha: 1))
            // Chat name only in the ask card, placed after the usage text so they never overlap.
            let tx = 42 + measure(headPctText, 14, .semibold) + 10 + measure(headSub, 12) + 16
            if mode == .asking, cw - tx - 18 > 40 { text(p.title, NSPoint(x: tx, y: top + 12), 12, NSColor(white: 0.45, alpha: 1), width: cw - tx - 18) }
        } else { text("no active chats", NSPoint(x: 16, y: top + 12), 12, NSColor(white: 0.62, alpha: 1)) }
        hits.append((NSRect(x: 0, y: top, width: cw, height: 40), { [weak self] in
            guard let s = self else { return }
            if s.mode == .idle { s.mode = .expanded } else if s.mode == .expanded || s.mode == .help || s.mode == .asking || s.mode == .done { s.mode = .idle }
            s.relayout() }))
        if mode == .idle && !docked { hits.append((NSRect(x: 4, y: top + 4, width: 40, height: 32), { [weak self] in self?.mini = true; self?.relayout() })) }   // the ring shrinks the pill

        if drawMode == .asking || drawMode == .done || drawMode == .working {
            NSColor(white: 1, alpha: 0.08).setFill(); NSRect(x: 18, y: top, width: cw - 36, height: 1).fill()
        }
        if needsReplace, let p = primary, mode != .working, mode != .asking {
            button("Replace", NSRect(x: (m > 0 ? fullW : cw) - 84, y: top + 8, width: 72, height: 24), color(p.pct)) { [weak self] in self?.startHandoff(p) }
        }

        if otherFull && mode == .idle {
            button("\(fullCount) full", NSRect(x: (m > 0 ? fullW : cw) - 84, y: top + 8, width: 72, height: 24), Look.red) { [weak self] in self?.mode = .expanded; self?.relayout() }
        }

        switch drawMode {
        case .expanded:
            if let (t, c) = paceLine() { entering(0) { text(t, NSPoint(x: 16, y: top - paceH + 2), 11, c, width: cw - 32) } }
            for (i, s) in sessions.prefix(8).enumerated() { entering(i + 1) {
                let y = top - paceH - 26 * CGFloat(i + 1)
                let e: CGFloat = i < rowT.count ? ease(rowT[i]) : 0
                if e > 0 { NSColor(white: 1, alpha: 0.07 * e).setFill(); NSBezierPath(roundedRect: NSRect(x: 8, y: y + 1, width: cw - 16, height: 24), xRadius: 9, yRadius: 9).fill() }
                text(s.title, NSPoint(x: 16, y: y + 4), 12, .white, .regular, width: 112)
                let bh: CGFloat = 5 + 3 * e
                let tw: CGFloat = 60 + 14 * e                      // the bar grows on hover
                let bar = NSRect(x: 134, y: y + 13 - bh / 2, width: tw, height: bh)
                NSColor(white: 1, alpha: 0.14).setFill(); NSBezierPath(roundedRect: bar, xRadius: bh / 2, yRadius: bh / 2).fill()
                color(s.pct).setFill(); NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * CGFloat(s.pct / 100)), height: bh), xRadius: bh / 2, yRadius: bh / 2).fill()
                if e < 0.98 {
                    // ❄ = idle over an hour: the cache is gone, the next message re-sends the whole chat at full price
                    text(s.cold ? "❄ \(Int(s.pct.rounded()))%" : "\(Int(s.pct.rounded()))%", NSPoint(x: s.cold ? 196 : 200, y: y + 4), 12,
                         s.cold ? NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: 1 - e) : NSColor(white: 0.7, alpha: 1 - e))
                }
                let money = NSAttributedString(string: money(s.cost), attributes: [.font: Look.font(11), .foregroundColor: NSColor(white: 0.5, alpha: 1)])
                money.draw(at: NSPoint(x: cw - 14 - money.size().width, y: y + 5))
                if e > 0.02 {                                       // round "back" button grows out of the bar's end
                    let d: CGFloat = 22 * e
                    let c = NSRect(x: bar.maxX + 8 + (1 - e) * 4, y: y + 13 - d / 2, width: d, height: d)
                    let base: NSColor = s.busy ? NSColor(white: 1, alpha: 0.12) : s.pct >= cfg.ask ? color(s.pct) : NSColor(white: 1, alpha: 0.22)   // dim while the chat works
                    base.setFill(); NSBezierPath(ovalIn: c).fill()
                    if let img = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Replace chat")?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11 * e, weight: .semibold)) {
                        let tinted = img.copy() as! NSImage; tinted.lockFocus(); NSColor.white.set()
                        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                        let sz = tinted.size
                        tinted.draw(in: NSRect(x: c.midX - sz.width / 2, y: c.midY - sz.height / 2, width: sz.width, height: sz.height), from: .zero, operation: .sourceOver, fraction: e * rowIn(i + 1))
                    }
                    if e > 0.6 { hits.append((c.insetBy(dx: -5, dy: -5), { [weak self] in self?.startHandoff(s) })) }
                }
            } }
            let credit = NSAttributedString(string: "Developed by Liav.T", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 1, alpha: 0.3)])
            credit.draw(at: NSPoint(x: (cw - credit.size().width) / 2, y: bounds.height - drawH + 8))
            helpButton(active: false)
            if updateAvailable {
                let up = NSAttributedString(string: "Update", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: Look.blue])
                let r = NSRect(x: 16, y: bounds.height - drawH + 8, width: up.size().width, height: up.size().height)
                up.draw(at: r.origin)
                hits.append((r.insetBy(dx: -6, dy: -5), { [weak self] in updateAvailable = false; self?.message = "Updating…"; self?.mode = .working; self?.relayout(); installUpdate() }))
            }
        case .help:
            entering(0) { text("What the pill shows", NSPoint(x: 16, y: top - 24), 12, .white, .semibold) }
            for (i, row) in helpRows.enumerated() { entering(i + 1) {
                let y = top - 30 - 24 * CGFloat(i + 1), mid = NSPoint(x: 26, y: y + 12)
                switch row.0 {
                case "ring": ring(mid, 7, 63, Look.blue, 2.6)
                case "pace": text("↗", NSPoint(x: 20, y: y + 4), 12, NSColor(white: 0.6, alpha: 1))
                case "bar":
                    NSColor(white: 1, alpha: 0.14).setFill(); NSBezierPath(roundedRect: NSRect(x: 14, y: y + 9, width: 24, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
                    Look.amber.setFill(); NSBezierPath(roundedRect: NSRect(x: 14, y: y + 9, width: 15, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
                case "cold": text("❄", NSPoint(x: 20, y: y + 4), 12, NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: 1))
                case "replace":
                    Look.amber.setFill(); NSBezierPath(ovalIn: NSRect(x: 17, y: y + 3, width: 18, height: 18)).fill()
                    if let img = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
                        let t = img.copy() as! NSImage; t.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop); t.unlockFocus()
                        t.draw(in: NSRect(x: 26 - t.size.width / 2, y: y + 12 - t.size.height / 2, width: t.size.width, height: t.size.height), from: .zero, operation: .sourceOver, fraction: rowIn(i + 1))   // images ignore the row fade
                    }
                case "dock":
                    NSColor(white: 1, alpha: 0.14).setFill(); NSBezierPath(roundedRect: NSRect(x: 14, y: y + 3, width: 24, height: 18), xRadius: 3, yRadius: 3).fill()
                    Look.red.setFill(); NSBezierPath(roundedRect: NSRect(x: 33, y: y + 5, width: 3, height: 14), xRadius: 1.5, yRadius: 1.5).fill()
                case "money": text("$", NSPoint(x: 22, y: y + 4), 12, NSColor(white: 0.6, alpha: 1), .semibold)
                default: text("⌃", NSPoint(x: 21, y: y + 2), 12, NSColor(white: 0.6, alpha: 1))
                }
                text(row.1, NSPoint(x: 48, y: y + 5), 11.5, NSColor(white: 0.82, alpha: 1), width: cw - 62)
            } }
            let credit = NSAttributedString(string: "Developed by Liav.T", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 1, alpha: 0.3)])
            credit.draw(at: NSPoint(x: (cw - credit.size().width) / 2, y: bounds.height - drawH + 8))
            helpButton(active: true)
        case .asking:
            guard let p = primary else { break }
            let bw = (cw - 36 - 12) / 2
            text("Context \(Int(p.pct.rounded()))% full", NSPoint(x: 18, y: top - 34), 14, .white, .semibold)
            text("Replace this chat? A new one opens with a handoff.", NSPoint(x: 18, y: top - 56), 11.5, NSColor(white: 0.62, alpha: 1), width: cw - 36)
            button("Yes, replace", NSRect(x: 18, y: top - 108, width: bw, height: 34), Look.blue) { [weak self] in self?.startHandoff(p) }
            button("Later", NSRect(x: 18 + bw + 12, y: top - 108, width: bw, height: 34), NSColor(white: 1, alpha: 0.12)) { [weak self] in
                self?.snoozed[p.appId] = Date().addingTimeInterval(self!.cfg.snooze * 60); self?.asked.remove(p.appId); self?.mode = .idle; self?.relayout() }
        case .working:
            let dots = String(repeating: ".", count: Int(Date().timeIntervalSinceReferenceDate * 2.5) % 4)
            let base = message.replacingOccurrences(of: "…", with: "")
            text(base + dots, NSPoint(x: 18, y: top - 30), 12.5, NSColor(white: 0.85, alpha: 1), width: cw - 36)
            shimmer(NSRect(x: 18, y: top - 44, width: cw - 36, height: 4))
        case .done:
            let bw = (cw - 36 - 12) / 2
            text(doneTitle, NSPoint(x: 18, y: top - 34), 14, .white, .semibold)
            text(doneSub, NSPoint(x: 18, y: top - 56), 11.5, NSColor(white: 0.62, alpha: 1), width: cw - 36)
            button("Copy again", NSRect(x: 18, y: top - 108, width: bw, height: 34), NSColor(white: 1, alpha: 0.12)) { [weak self] in self?.copyHandoff() }
            button("Show file", NSRect(x: 18 + bw + 12, y: top - 108, width: bw, height: 34), NSColor(white: 1, alpha: 0.12)) { NSWorkspace.shared.open(URL(fileURLWithPath: handoffDir)) }
        case .idle: break
        }
    }

    // A press only counts as a click if the pointer stays put; moving it drags the pill and never opens anything.
    var pressAt: NSPoint?, dragged = false
    override func mouseDown(with e: NSEvent) { pressAt = NSEvent.mouseLocation; dragged = false }
    override func mouseDragged(with e: NSEvent) {
        guard let p = pressAt, !dragged else { return }
        let m = NSEvent.mouseLocation
        if hypot(m.x - p.x, m.y - p.y) > 3 { dragged = true; window?.performDrag(with: e); snapDock() }   // let go near a screen edge → it tucks in as a line
    }
    override func mouseUp(with e: NSEvent) {
        defer { pressAt = nil }
        guard !dragged else { dragged = false; return }
        var pt = convert(e.locationInWindow, from: nil); pt.x -= lastOX
        if let h = hits.reversed().first(where: { $0.0.contains(pt) }) { h.1(); needsDisplay = true }
    }

    enum SendResult { case sent, prefilled, failed }

    /// Opens a new chat in the Claude app via its claude://code/new link (right folder, handoff pre-filled),
    /// then presses Return. Pressing a key needs Accessibility; without it the chat is left ready to send.
    /// The Claude app's focused element: (role, start of its text). Needs Accessibility.
    static func claudeFocus() -> (pid: pid_t, role: String, value: String)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // Electron: expose the web content tree
        var f: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &f)
        guard err == .success, let el = f else { return (app.processIdentifier, "", "") }
        var r: CFTypeRef?, v: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &r)
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXValueAttribute as CFString, &v)
        return (app.processIdentifier, (r as? String) ?? "", String(((v as? String) ?? "").prefix(80)))
    }

    static func sendToNewChat(text: String, cwd: String) -> SendResult {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+#?")
        guard text.count < 13_000, let q = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let f = cwd.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "claude://code/new?q=\(q)&folder=\(f)") else { log("link: handoff too long or bad url"); return .failed }
        DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
        guard AXIsProcessTrusted() else { log("link opened; Accessibility not trusted, left for manual Return"); return .prefilled }
        // Press Return only when Claude's message box has focus and holds the handoff, never on a dialog or another app.
        let start = Date(), marker = String(text.prefix(24))
        var presses = 0
        while Date().timeIntervalSince(start) < 20 && presses < 3 {
            usleep(400_000)
            let ff = claudeFocus()
            let filled = ff?.role == "AXTextArea" && (ff?.value ?? "").hasPrefix(marker)
            if presses > 0 && !filled { log("return: sent after \(presses) press(es)"); return .sent }   // box emptied or chat moved on = message went out
            guard let f = ff, f.role == "AXTextArea" else { continue }
            guard filled || (f.value.isEmpty && Date().timeIntervalSince(start) > 4 && presses == 0) else { continue }
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap); usleep(40_000) }
            presses += 1; usleep(1_200_000)
        }
        log(presses > 0 ? "return: pressed \(presses)x, box state unclear" : "return: message box never ready, left for manual Return")
        return presses > 0 ? .sent : .prefilled
    }

    func copyHandoff() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(handoffText, forType: .string) }

    /// The Claude Code CLI: the user's own install (login-shell PATH), else the copy the Claude app ships with.
    static func claudeCLI() -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            p.waitUntilExit()
            if out.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: out) { return out }
        }
        let root = home + "/Library/Application Support/Claude/claude-code"
        let vers = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in vers {
            for h in (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + v)) ?? [] {
                let bin = "\(root)/\(v)/\(h)/claude.app/Contents/MacOS/claude"
                if FileManager.default.isExecutableFile(atPath: bin) { return bin }
            }
        }
        return nil
    }

    func startHandoff(_ s: Sess) {
        if let live = sessions.first(where: { $0.appId == s.appId }), live.busy {
            message = "“\(s.title)” is still working. Replace once it's done."; mode = .working; relayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.mode == .working { self?.mode = .idle; self?.relayout() } }
            return
        }
        mode = .working; message = "Writing handoff…"; relayout()
        let prompt = "Write a handoff document so a brand-new session can continue exactly where we left off. Sections: Goal, Decisions made, Current state (exact file paths, commands, running processes, and every background watcher, Monitor, loop or scheduled task this chat runs with the exact command to restart it), Done, Next steps, Open questions, the user's preferences seen in this chat. Dense and specific, no preamble, under 600 words. Output only the markdown."
        DispatchQueue.global().async {
            var body = ""
            if let cli = MeterView.claudeCLI() {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", "cd \"$CM_CWD\" && \"$CM_CLI\" -p \"$CM_PROMPT\" --resume \"$CM_ID\" --fork-session --output-format text"]
                var env: [String: String] = ProcessInfo.processInfo.environment
                env["CM_CWD"] = s.cwd; env["CM_PROMPT"] = prompt; env["CM_ID"] = s.cliId; env["CM_CLI"] = cli
                p.environment = env
                let errFile = NSTemporaryDirectory() + "cm-handoff-err.txt"
                FileManager.default.createFile(atPath: errFile, contents: nil)
                let outFile = NSTemporaryDirectory() + "cm-handoff-out.txt"
                FileManager.default.createFile(atPath: outFile, contents: nil)
                p.standardOutput = FileHandle(forWritingAtPath: outFile); p.standardError = FileHandle(forWritingAtPath: errFile); p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { log("handoff: cannot run \(cli): \(error)") }
                let t0 = Date(), limit: TimeInterval = 240          // a stuck summary never blocks Replace for long
                while p.isRunning && Date().timeIntervalSince(t0) < limit {
                    Thread.sleep(forTimeInterval: 1)
                    let sec = Int(Date().timeIntervalSince(t0))
                    DispatchQueue.main.async { self.message = "Writing handoff… \(sec)s" }
                }
                if p.isRunning { p.terminate(); log("handoff: summary took over \(Int(limit))s, stopped it") }
                p.waitUntilExit()
                body = ((try? String(contentsOfFile: outFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty || p.terminationStatus != 0 {
                    let err = (try? String(contentsOfFile: errFile, encoding: .utf8)) ?? ""
                    log("handoff: \(cli) exit \(p.terminationStatus): \(err.prefix(400).replacingOccurrences(of: "\n", with: " | "))")
                    if p.terminationStatus != 0 { body = "" }
                }
            } else { log("handoff: no Claude Code CLI found (PATH or the Claude app)") }
            // Never strand the user: if the summary couldn't be written, the new chat reads the old one itself.
            if body.isEmpty {
                body = "The automatic summary couldn't be written. Before anything else, read the previous chat yourself: load mcp__ccd_session_mgmt__list_events with ToolSearch, call it on session_id \(s.appId) (page back with before_uuid as needed), then write a short summary of where things stand and continue from there."
                log("handoff: using read-the-old-chat fallback")
            }
            DispatchQueue.main.async { self.finishHandoff(s, body) }
        }
    }

    func finishHandoff(_ s: Sess, _ body: String) {
        guard !body.isEmpty else { self.message = "Handoff failed — try again"; self.mode = .working; self.relayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.mode = .asking; self.relayout() }; return }
        let newTitle = nextTitle(s.title)
        let g = sidebarGroups()
        let oldGroupId = g.assign[s.appId]
        let archiveId = g.names.first(where: { $0.value == self.cfg.group })?.key
        let placeStep = oldGroupId.map { "(2) move_sessions session_ids [\"self\"] to group_id \"\($0)\" (“\(g.names[$0] ?? "")”), the old chat's group, so this chat takes its place;" } ?? "(2) leave this session ungrouped, like the old chat;"
        let archiveStep = archiveId.map { "group_id \"\($0)\" (“\(self.cfg.group)”)" } ?? "the group “\(self.cfg.group)” (create it first with create_group if missing)"
        self.handoffText = """
        Continuing from a previous chat (“\(s.title)”, session id \(s.appId)). Context was getting heavy, so we're starting fresh.
        Do these first, quietly, with no commentary. Load every tool you need in ONE ToolSearch call: select:mcp__ccd_session_mgmt__set_session_title,mcp__ccd_sidebar__move_sessions,mcp__ccd_session_mgmt__get_session,mcp__ccd_session_mgmt__set_session_permission_mode,mcp__ccd_session_mgmt__send_message — then make these calls together in one parallel batch: (1) set_session_title session_id "self" to “\(newTitle)”; \(placeStep) (3) move_sessions session_ids ["\(s.appId)"] to \(archiveStep). Do not archive anything, the group is the archive. Then call get_session with session_id "self" and compare it with the old chat's settings — model “\(s.model)”\(s.effort.isEmpty ? "" : ", effort “\(s.effort)”")\(s.mode.isEmpty ? "" : ", permission mode “\(s.mode)”") — and fix every difference; never assume they match. Fix permission mode yourself with set_session_permission_mode (session_id "self"). Then always send_message to the old chat (session_id \(s.appId)) saying it has been replaced by your session id, and asking it to: stop every background task, Monitor, loop, scheduled wakeup or cron it started (TaskStop / ScheduleWakeup stop / CronDelete), ignore any later events or task notifications because the new chat owns the work now, and — only if your model or effort differs from the old values, since a chat can't change its own — load set_session_model and set_session_effort in one ToolSearch and call them on your session id with the old values; no other work, one-line reply. Restart any watchers the handoff lists in this chat yourself. Then continue from the handoff below — no recap needed.

        --- HANDOFF ---
        \(body)
        """
        try? FileManager.default.createDirectory(atPath: handoffDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let safe: String = s.title.replacingOccurrences(of: "/", with: "-")
        let file: String = handoffDir + "/" + safe + " " + f.string(from: Date()) + ".md"
        try? handoffText.write(toFile: file, atomically: true, encoding: .utf8)
        message = "Opening new chat…"; relayout()
        let groupName = oldGroupId.flatMap { g.names[$0] } ?? "no group"
        let startedMs = Date().timeIntervalSince1970 * 1000 - 5_000
        DispatchQueue.global().async {
            let res = MeterView.sendToNewChat(text: self.handoffText, cwd: s.cwd)
            if res == .failed {
                DispatchQueue.main.async {
                    self.copyHandoff(); self.doneTitle = "Copied to clipboard ✓"; self.doneSub = "Couldn't open it. Paste in a new chat (⌘V)."
                    NSSound(named: "Glass")?.play(); self.mode = .done; self.relayout()
                }
                return
            }
            // Chat is open. Wait (live) until it has renamed itself and the old and new chats are filed.
            DispatchQueue.main.async { self.message = res == .prefilled ? "Press Return in the new chat" : "Filing the new chat"; self.mode = .working; self.relayout() }
            var filed = false
            for _ in 0..<90 {                                    // up to ~3 minutes
                Thread.sleep(forTimeInterval: 2)
                guard let newId = findSession(title: newTitle, createdAfter: startedMs) else { continue }
                retargetPins(from: s.appId, to: newId)
                recordReplace(newAppId: newId, baseline: s.tokens)
                let g2 = sidebarGroups()
                if g2.assign[newId] == oldGroupId && g2.assign[s.appId] == archiveId && archiveId != nil { filed = true; break }
                DispatchQueue.main.async { self.message = "Filing the new chat" }
            }
            DispatchQueue.main.async {
                self.doneTitle = filed ? "All filed ✓" : "New chat is open ✓"
                self.doneSub = filed ? "“\(newTitle)” is in \(groupName). The old chat is in \(self.cfg.group)." : "It hasn't finished filing yet. Give it a moment."
                NSSound(named: "Glass")?.play(); self.mode = .done; self.relayout()
            }
        }
    }
}

extension NSBezierPath { func fill(with c: NSColor) { c.setFill(); fill() } }

final class Panel: NSPanel { override var canBecomeKey: Bool { false } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: Panel!, view: MeterView!, rescueScreens: (() -> Void)?
    func applicationDidFinishLaunching(_ n: Notification) {
        // One pill only: a second copy (login item + manual open, an update relaunch) quits right away.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != me }) {
            log("another ContextMeter is running, quitting this one"); NSApp.terminate(nil); return
        }
        // Start at login by itself, once per Mac (if the user later turns it off in Login Items, that choice stays).
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            if SMAppService.mainApp.status != .enabled { do { try SMAppService.mainApp.register(); log("login item registered") } catch { log("login item error \(error)") } }
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
        let scr = NSScreen.main!.visibleFrame
        panel = Panel(contentRect: NSRect(x: scr.maxX - 190, y: scr.maxY - 60, width: 168, height: 40),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrameAutosaveName("ContextMeterPanel"); panel.isMovableByWindowBackground = false; panel.acceptsMouseMovedEvents = true
        view = MeterView(frame: panel.contentView!.bounds); view.autoresizingMask = [.width, .height]
        if let d = ProcessInfo.processInfo.environment["CM_DOCK"], let n = Int(d) { view.dock = n }   // test: start docked without saving it
        view.onResize = { [weak self] size in
            guard let p = self?.panel else { return }
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(p.frame) }) ?? NSScreen.main!
            let vis = screen.visibleFrame
            let top = min(p.frame.maxY, vis.maxY - 8)                    // never tuck under the menu bar
            let dock = self?.view.dock ?? 0
            if dock != 0 {                                               // docked: flush with the screen edge, opens inward; a line keeps a few points of hover room
                let w = size.width > 20 ? size.width + 18 : 14                  // a little extra room for the card's settle
                p.setFrame(NSRect(x: dock == 1 ? screen.frame.maxX - w : screen.frame.minX, y: max(vis.minY + 8, top - size.height), width: w, height: size.height), display: false, animate: false)
                return
            }
            let x = min(p.frame.minX, vis.maxX - size.width - 8)        // grow to the right, stay on screen
            p.setFrame(NSRect(x: max(vis.minX + 8, x), y: max(vis.minY + 8, top - size.height), width: size.width, height: size.height), display: false, animate: false)
        }
        // If the saved spot is off every screen (display unplugged or rearranged), come back to the main screen's top right.
        func rescue() {
            let p = self.panel!
            let header = NSRect(x: p.frame.minX, y: p.frame.maxY - 40, width: min(p.frame.width, 120), height: 40)
            if !NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: header.midX, y: header.midY)) }) {
                let vis = NSScreen.main!.visibleFrame
                p.setFrameTopLeftPoint(NSPoint(x: vis.maxX - p.frame.width - 24, y: vis.maxY - 12))
            }
        }
        rescueScreens = rescue
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in rescue() }
        panel.contentView!.addSubview(view); panel.orderFrontRegardless(); rescueScreens?()
        // First launch on a Mac: ask once for Accessibility (lets Replace press Return in the new chat). macOS shows its own
        // prompt and adds ContextMeter to the list; we also open that settings page. Never asked again after that.
        let askedKey = "askedAccessibility"
        let askNow = !UserDefaults.standard.bool(forKey: askedKey)
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: askNow && !AXIsProcessTrusted()] as CFDictionary)
        log("accessibility trusted = \(trusted)")
        if askNow { UserDefaults.standard.set(true, forKey: askedKey)
            if !trusted, let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) } }
        if let st = ProcessInfo.processInfo.environment["CM_STATE"] { view.mode = st == "asking" ? .asking : st == "done" ? .done : st == "working" ? .working : .expanded; view.message = "Writing handoff…"; view.frozen = true }
        if ProcessInfo.processInfo.environment["CM_PROFILE"] != nil { view.mode = ProcessInfo.processInfo.environment["CM_PROFILE"] == "help" ? .help : .expanded; view.frozen = true }
        if let h = ProcessInfo.processInfo.environment["CM_HOVER"], let n = Int(h) { view.mode = .expanded; view.pinned = n; view.frozen = true }
        if ProcessInfo.processInfo.environment["CM_HELPDEMO"] != nil { view.frozen = true; view.mode = .expanded; Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in guard let v = self?.view else { return }; v.mode = v.mode == .help ? .expanded : .help; v.relayout() } }
        if ProcessInfo.processInfo.environment["CM_DOCKDEMO"] != nil { view.frozen = true; Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in guard let v = self?.view else { return }; v.peek.toggle(); v.relayout() } }
        if ProcessInfo.processInfo.environment["CM_SNAPTEST"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in   // test: drop the pill 10pt from the right edge, as a drag would
            guard let p = self?.panel, let v = self?.view, let e = (p.screen ?? NSScreen.main)?.frame else { return }
            p.setFrameOrigin(NSPoint(x: e.maxX - p.frame.width - 10, y: p.frame.minY)); v.snapDock(); log("snaptest: dock=\(v.dock) frame=\(p.frame)")
            p.setFrameOrigin(NSPoint(x: e.midX, y: p.frame.minY)); v.snapDock(); log("snaptest away: dock=\(v.dock) frame=\(p.frame)") } }
        if ProcessInfo.processInfo.environment["CM_MINIDEMO"] != nil { view.frozen = true; Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in guard let v = self?.view else { return }; v.mini.toggle(); v.relayout() } }
        if ProcessInfo.processInfo.environment["CM_TESTSEND"] != nil { DispatchQueue.global().async { let r = MeterView.sendToNewChat(text: "Reply with just OK", cwd: home + "/Documents/Claude"); log("testsend \(r)") } }
        let frameTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.view.stepAnim(); if self?.view.mode == .working { self?.view.needsDisplay = true } }
        RunLoop.main.add(frameTimer, forMode: .common)
        view.tick(); Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.view.tick() }
        // Updates install themselves while the pill is idle (never mid-Replace); the blue "Update" stays as a manual way.
        let autoUpdate: () -> Void = { [weak self] in
            self?.view.needsDisplay = true
            if updateAvailable, self?.view.mode == .idle { updateAvailable = false; log("update: installing automatically"); installUpdate() }
        }
        checkForUpdate(autoUpdate)
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in checkForUpdate(autoUpdate) }
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let delegate = AppDelegate(); app.delegate = delegate; app.run()
