// ContextMeter — tiny always-on-top gauge of how full each Claude Code conversation's context is.
// Past a threshold it asks: "start fresh?" → writes a handoff, copies a ready-to-paste prompt that
// continues exactly where you left off, renames the new chat "<name> v2" and archives the old one.
import Cocoa

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

struct Config { var ask = 40.0, red = 60.0, group = "Archive", snooze = 20.0, window: Double? = nil
    static func load() -> Config {
        var c = Config()
        if let d = FileManager.default.contents(atPath: appDir + "/config.json"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            c.ask = (j["askAtPercent"] as? Double) ?? c.ask; c.red = (j["redAtPercent"] as? Double) ?? c.red
            c.group = (j["archiveGroup"] as? String) ?? c.group; c.snooze = (j["snoozeMinutes"] as? Double) ?? c.snooze
            c.window = j["windowOverride"] as? Double
        }
        return c
    }
}

struct Sess { var appId: String, cliId: String, title: String, cwd: String, model: String, last: Double, tokens: Int = 0, window: Int = 200_000, effort = "", mode = ""
    var pct: Double { min(100, Double(tokens) / Double(window) * 100) } }

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

/// Point Wonderflow's voice pill at the new chat when it was pinned to the one being replaced.
func retargetWonderflow(from old: String, to new: String) {
    let path = home + "/MotionMachine/apps/MotionChat/config.json"
    guard let d = FileManager.default.contents(atPath: path),
          var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let link = j["chatLink"] as? String, link.hasSuffix(old) else { return }
    j["chatLink"] = link.replacingOccurrences(of: old, with: new)
    if let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) { try? out.write(to: URL(fileURLWithPath: path), options: .atomic); log("wonderflow chat link moved \(old) -> \(new)") }
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
    for case let rel as String in en where rel.hasSuffix(".json") && rel.contains("local_") {
        guard let d = fm.contents(atPath: sessionsRoot + "/" + rel),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (j["isArchived"] as? Bool) != true, !hidden.contains((j["sessionId"] as? String) ?? ""), let cli = j["cliSessionId"] as? String,
              let last = j["lastActivityAt"] as? Double, last > cutoff else { continue }
        let model = (j["model"] as? String) ?? ""
        var s = Sess(appId: (j["sessionId"] as? String) ?? "", cliId: cli, title: (j["title"] as? String) ?? "Untitled",
                     cwd: (j["cwd"] as? String) ?? home, model: model, last: last)
        s.effort = (j["effort"] as? String) ?? ""; s.mode = (j["permissionMode"] as? String) ?? ""
        s.window = Int(cfg.window ?? (model.range(of: #"(opus|sonnet|fable)-5"#, options: .regularExpression) != nil || model.contains("[1m]") ? 1_000_000 : 200_000))
        if let p = transcriptPath(cli) { s.tokens = contextTokens(p) }
        out.append(s)
    }
    return out.sorted { $0.last > $1.last }
}

func nextTitle(_ t: String) -> String {
    if let r = t.range(of: #" v(\d+)$"#, options: .regularExpression), let n = Int(t[r].dropFirst(2)) { return t[..<r.lowerBound] + " v\(n + 1)" }
    return t + " v2"
}

struct Acct { var pct: Double; var sub: String }

/// Whole-account usage from Anthropic, using the Claude Code login already in the Keychain (read-only, never logged).
var cachedToken: String?, cachedExpiry: Double = 0

func fetchAccount() -> Acct? {
    // Read through Apple's own `security` tool: its signature never changes, so the Keychain approval survives every rebuild of this app.
    // The token is only held in memory and refreshed when it expires.
    if cachedToken == nil || cachedExpiry < Date().timeIntervalSince1970 * 1000 + 60_000 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { log("usage: cannot run security"); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = j["claudeAiOauth"] as? [String: Any], let t = o["accessToken"] as? String else { log("usage: keychain read failed (\(p.terminationStatus))"); return nil }
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
            result = Acct(pct: u, sub: "$\(usedS) of $\(limS)")
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

enum Mode { case idle, expanded, asking, working, done }

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
    let baseListWidth: CGFloat = 252, revealWidth: CGFloat = 92
    func ease(_ t: CGFloat) -> CGFloat { bezier(0.65, 0, 0.35, 1, t) }   // smooth ease in-out
    var sweepStart = Date()
    func stepAnim() {
        let now = Date(); let dt = CGFloat(now.timeIntervalSince(lastStep)); lastStep = now
        if let t = tween {                                        // ease the drawn card between sizes
            let p = min(1, CGFloat(now.timeIntervalSince(t.start) / t.dur))
            let e = bezier(0.65, 0, 0.35, 1, p)
            drawW = t.fw + (t.tw - t.fw) * e; drawH = t.fh + (t.th - t.fh) * e
            if p >= 1 {
                tween = nil; drawW = t.tw; drawH = t.th; drawMode = mode
                let size = CGSize(width: t.tw, height: t.th)       // shrink the window once, at the end
                if size != lastWindowSize { lastWindowSize = size; onResize?(size) }
            }
            needsDisplay = true
        }
        // Close by itself: the list after the pointer leaves, the finished card after a few seconds.
        let inside = window?.frame.contains(NSEvent.mouseLocation) ?? false
        if mode == .expanded && pinned < 0 && !profiling {
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
        else if let w = window, w.frame.contains(NSEvent.mouseLocation) { under = rowAt(convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
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
        for i in 0..<min(sessions.count, 8) where NSRect(x: 0, y: top - 26 * CGFloat(i + 1), width: cw, height: 26).contains(pt) { return i }
        return -1
    }
    /// Last good account usage (kept on disk) so the pill never falls back to a chat percent when the login is briefly expired.
    var acct: Acct? = {
        guard let d = FileManager.default.contents(atPath: appDir + "/usage-cache.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let p = j["pct"] as? Double, let sub = j["sub"] as? String, Date().timeIntervalSince1970 - ((j["at"] as? Double) ?? 0) < 6 * 3600 else { return nil }
        return Acct(pct: p, sub: sub)
    }(), acctFetched = Date.distantPast, acctBusy = false
    var headPct: Double { acct?.pct ?? primary?.pct ?? 0 }
    var headSub: String { acct?.sub ?? shortTok(primary?.tokens ?? 0) }
    func headColor() -> NSColor { acct != nil ? (headPct >= 85 ? Look.red : headPct >= 65 ? Look.amber : Look.blue) : color(headPct) }
    func measure(_ s: String, _ size: CGFloat, _ w: NSFont.Weight = .regular) -> CGFloat { (s as NSString).size(withAttributes: [.font: Look.font(size, w)]).width }
    /// Width of the header strip: ring + percent + tokens, sized to its content.
    var headerWidth: CGFloat {
        guard primary != nil || acct != nil else { return 140 }
        return 42 + measure("\(Int(headPct.rounded()))%", 14, .semibold) + 10 + measure(headSub, 12) + 18
    }
    var primary: Sess? { sessions.first }
    var needsReplace: Bool { (primary?.pct ?? 0) >= cfg.ask }
    var fullCount: Int { sessions.filter { $0.pct >= cfg.ask && $0.last > Date().timeIntervalSince1970 * 1000 - 24 * 3600 * 1000 }.count }
    var otherFull: Bool { !needsReplace && fullCount > 0 }

    func color(_ pct: Double) -> NSColor { pct >= cfg.red ? Look.red : pct >= cfg.ask ? Look.amber : Look.blue }

    func tick() {
        cfg = Config.load()
        if !acctBusy, Date().timeIntervalSince(acctFetched) > (acct == nil ? 60 : 120) {
            acctBusy = true
            DispatchQueue.global().async {
                let a = fetchAccount()
                DispatchQueue.main.async {
                    if let a { self.acct = a; try? JSONSerialization.data(withJSONObject: ["pct": a.pct, "sub": a.sub, "at": Date().timeIntervalSince1970]).write(to: URL(fileURLWithPath: appDir + "/usage-cache.json")) }
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
                if !self.frozen, self.mode == .idle || self.mode == .expanded, let p = s.first, p.pct >= self.cfg.ask,
                   (self.snoozed[p.appId] ?? .distantPast) < Date(), !self.asked.contains(p.appId) {
                    self.mode = .asking; self.asked.insert(p.appId); NSSound(named: "Tink")?.play()
                }
                if let p = s.first, p.pct < self.cfg.ask * 0.6 { self.asked.remove(p.appId) }
                self.relayout()
            }
        }
    }

    func relayout() {
        var h: CGFloat = 40, w: CGFloat = headerWidth
        switch mode {
        case .idle: if needsReplace || otherFull { w += 92 }
        case .expanded:
            h = 40 + CGFloat(min(sessions.count, 8)) * 26 + 8 + 18   // + the credit line
            w = max(headerWidth + 16, baseListWidth)
        case .asking: h = 40 + 124; w = 312
        case .working: h = 40 + 62; w = 312
        case .done: h = 40 + 124; w = 312
        }
        logicalWidth = w
        let target = CGSize(width: w, height: h)
        if mode == .expanded && prevMode != .expanded { lastInside = Date() }
        prevMode = mode
        if lastTarget == .zero {                                  // first layout: no animation
            lastTarget = target; drawW = w; drawH = h; drawMode = mode
            lastWindowSize = target; onResize?(target)
        } else if target != lastTarget {
            let shrinking = h < drawH
            lastTarget = target
            if !shrinking { drawMode = mode }                     // keep old content while closing
            tween = (drawW, drawH, w, h, Date(), shrinking ? 0.26 : 0.30)
            let big = CGSize(width: max(w, drawW), height: max(h, drawH))
            if big != lastWindowSize { lastWindowSize = big; onResize?(big) }
        } else if tween == nil { drawMode = mode }
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
        let card = NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.height - drawH, width: cw, height: drawH).insetBy(dx: 0.5, dy: 0.5), xRadius: 20, yRadius: 20)
        NSColor(calibratedWhite: 0.105, alpha: 1).setFill(); card.fill()
        NSColor(white: 1, alpha: 0.12).setStroke(); card.lineWidth = 1; card.stroke()
        card.addClip()   // content never spills outside the card while it grows or shrinks
        let top = bounds.height - 40   // header strip is the top 40pt (y-up)
        if let p = primary {
            if mode == .working { spinner(NSPoint(x: 24, y: top + 20), 9, Look.blue) }
            else { ring(NSPoint(x: 24, y: top + 20), 9, headPct, headColor(), 3.2) }
            text("\(Int(headPct.rounded()))%", NSPoint(x: 42, y: top + 11), 14, .white, .semibold)
            text(headSub, NSPoint(x: 42 + measure("\(Int(headPct.rounded()))%", 14, .semibold) + 10, y: top + 12), 12, NSColor(white: 0.62, alpha: 1))
            // Chat name only in the ask card, placed after the usage text so they never overlap.
            let tx = 42 + measure("\(Int(headPct.rounded()))%", 14, .semibold) + 10 + measure(headSub, 12) + 16
            if mode == .asking, cw - tx - 18 > 40 { text(p.title, NSPoint(x: tx, y: top + 12), 12, NSColor(white: 0.45, alpha: 1), width: cw - tx - 18) }
        } else { text("no active chats", NSPoint(x: 16, y: top + 12), 12, NSColor(white: 0.62, alpha: 1)) }
        hits.append((NSRect(x: 0, y: top, width: cw, height: 40), { [weak self] in
            guard let s = self else { return }
            if s.mode == .idle { s.mode = .expanded } else if s.mode == .expanded || s.mode == .asking || s.mode == .done { s.mode = .idle }
            s.relayout() }))

        if drawMode == .asking || drawMode == .done || drawMode == .working {
            NSColor(white: 1, alpha: 0.08).setFill(); NSRect(x: 18, y: top, width: cw - 36, height: 1).fill()
        }
        if needsReplace, let p = primary, mode != .working, mode != .asking {
            button("Replace", NSRect(x: cw - 84, y: top + 8, width: 72, height: 24), color(p.pct)) { [weak self] in self?.startHandoff(p) }
        }

        if otherFull && mode == .idle {
            button("\(fullCount) full", NSRect(x: cw - 84, y: top + 8, width: 72, height: 24), Look.red) { [weak self] in self?.mode = .expanded; self?.relayout() }
        }

        switch drawMode {
        case .expanded:
            for (i, s) in sessions.prefix(8).enumerated() {
                let y = top - 26 * CGFloat(i + 1)
                let e: CGFloat = i < rowT.count ? ease(rowT[i]) : 0
                if e > 0 { NSColor(white: 1, alpha: 0.07 * e).setFill(); NSBezierPath(roundedRect: NSRect(x: 8, y: y + 1, width: cw - 16, height: 24), xRadius: 9, yRadius: 9).fill() }
                text(s.title, NSPoint(x: 16, y: y + 4), 12, .white, .regular, width: 112)
                let bh: CGFloat = 5 + 3 * e
                let tw: CGFloat = 60 + 14 * e                      // the bar grows on hover
                let bar = NSRect(x: 134, y: y + 13 - bh / 2, width: tw, height: bh)
                NSColor(white: 1, alpha: 0.14).setFill(); NSBezierPath(roundedRect: bar, xRadius: bh / 2, yRadius: bh / 2).fill()
                color(s.pct).setFill(); NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * CGFloat(s.pct / 100)), height: bh), xRadius: bh / 2, yRadius: bh / 2).fill()
                if e < 0.98 { text("\(Int(s.pct.rounded()))%", NSPoint(x: 200, y: y + 4), 12, NSColor(white: 0.7, alpha: 1 - e)) }
                if e > 0.02 {                                       // round "back" button grows out of the bar's end
                    let d: CGFloat = 22 * e
                    let c = NSRect(x: bar.maxX + 8 + (1 - e) * 4, y: y + 13 - d / 2, width: d, height: d)
                    let base: NSColor = s.pct >= cfg.ask ? color(s.pct) : NSColor(white: 1, alpha: 0.22)
                    base.setFill(); NSBezierPath(ovalIn: c).fill()
                    if let img = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Replace chat")?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11 * e, weight: .semibold)) {
                        let tinted = img.copy() as! NSImage; tinted.lockFocus(); NSColor.white.set()
                        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                        let sz = tinted.size
                        tinted.draw(in: NSRect(x: c.midX - sz.width / 2, y: c.midY - sz.height / 2, width: sz.width, height: sz.height), from: .zero, operation: .sourceOver, fraction: e)
                    }
                    if e > 0.6 { hits.append((c.insetBy(dx: -5, dy: -5), { [weak self] in self?.startHandoff(s) })) }
                }
            }
            let credit = NSAttributedString(string: "Developed by Liav.T", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 1, alpha: 0.3)])
            credit.draw(at: NSPoint(x: (cw - credit.size().width) / 2, y: bounds.height - drawH + 8))
            if updateAvailable {
                let up = NSAttributedString(string: "Update", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: Look.blue])
                let r = NSRect(x: cw - 16 - up.size().width, y: bounds.height - drawH + 8, width: up.size().width, height: up.size().height)
                up.draw(at: r.origin)
                hits.append((r.insetBy(dx: -6, dy: -5), { [weak self] in updateAvailable = false; self?.message = "Updating…"; self?.mode = .working; self?.relayout(); installUpdate() }))
            }
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

    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        if let h = hits.reversed().first(where: { $0.0.contains(pt) }) { h.1(); needsDisplay = true } else { window?.performDrag(with: e) }
    }
    override func mouseDragged(with e: NSEvent) { window?.performDrag(with: e) }

    enum SendResult { case sent, prefilled, failed }

    /// Opens a new chat in the Claude app via its claude://code/new link (right folder, handoff pre-filled),
    /// then presses Return. Pressing a key needs Accessibility; without it the chat is left ready to send.
    static func sendToNewChat(text: String, cwd: String) -> SendResult {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+#?")
        guard text.count < 13_000, let q = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let f = cwd.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "claude://code/new?q=\(q)&folder=\(f)") else { log("link: handoff too long or bad url"); return .failed }
        DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
        Thread.sleep(forTimeInterval: 3.0)               // let the app open the chat and fill the composer
        guard AXIsProcessTrusted() else { log("link opened; Accessibility not trusted, left for manual Return"); return .prefilled }
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap); usleep(40_000) }
        return .sent
    }

    func copyHandoff() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(handoffText, forType: .string) }

    func startHandoff(_ s: Sess) {
        mode = .working; message = "Writing handoff…"; relayout()
        let prompt = "Write a handoff document so a brand-new session can continue exactly where we left off. Sections: Goal, Decisions made, Current state (exact file paths, commands, running processes), Done, Next steps, Open questions, the user's preferences seen in this chat. Dense and specific, no preamble, under 600 words. Output only the markdown."
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "cd \"$CM_CWD\" && claude -p \"$CM_PROMPT\" --resume \"$CM_ID\" --fork-session --output-format text"]
            var env: [String: String] = ProcessInfo.processInfo.environment
            env["CM_CWD"] = s.cwd; env["CM_PROMPT"] = prompt; env["CM_ID"] = s.cliId
            p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            try? p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let raw: String = String(data: data, encoding: .utf8) ?? ""
            let body: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
        Do these first, quietly, with no commentary. Load every tool you need in ONE ToolSearch call: select:mcp__ccd_session_mgmt__set_session_title,mcp__ccd_sidebar__move_sessions,mcp__ccd_session_mgmt__get_session,mcp__ccd_session_mgmt__set_session_permission_mode,mcp__ccd_session_mgmt__send_message — then make these calls together in one parallel batch: (1) set_session_title session_id "self" to “\(newTitle)”; \(placeStep) (3) move_sessions session_ids ["\(s.appId)"] to \(archiveStep). Do not archive anything, the group is the archive. Then call get_session with session_id "self" and compare it with the old chat's settings — model “\(s.model)”\(s.effort.isEmpty ? "" : ", effort “\(s.effort)”")\(s.mode.isEmpty ? "" : ", permission mode “\(s.mode)”") — and fix every difference; never assume they match. Fix permission mode yourself with set_session_permission_mode (session_id "self"). A chat can't change its own model or effort, so if either differs, send_message to the old chat (session_id \(s.appId)) asking it to load set_session_model and set_session_effort in one ToolSearch and call them on your session id with the old values, no other work, one-line reply. Then continue from the handoff below — no recap needed.

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
                retargetWonderflow(from: s.appId, to: newId)
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
        let scr = NSScreen.main!.visibleFrame
        panel = Panel(contentRect: NSRect(x: scr.maxX - 190, y: scr.maxY - 60, width: 168, height: 40),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrameAutosaveName("ContextMeterPanel"); panel.isMovableByWindowBackground = false; panel.acceptsMouseMovedEvents = true
        view = MeterView(frame: panel.contentView!.bounds); view.autoresizingMask = [.width, .height]
        view.onResize = { [weak self] size in
            guard let p = self?.panel else { return }
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(p.frame) }) ?? NSScreen.main!
            let vis = screen.visibleFrame
            let x = min(p.frame.minX, vis.maxX - size.width - 8)        // grow to the right, stay on screen
            let top = min(p.frame.maxY, vis.maxY - 8)                    // never tuck under the menu bar
            p.setFrame(NSRect(x: max(vis.minX + 8, x), y: max(vis.minY + 8, top - size.height), width: size.width, height: size.height), display: false, animate: false)
        }
        // If the saved spot is off every screen (display unplugged or rearranged), come back to the main screen's top right.
        func rescue() {
            let p = self.panel!
            let header = NSRect(x: p.frame.minX, y: p.frame.maxY - 40, width: min(p.frame.width, 120), height: 40)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: header.midX, y: header.midY)) }) {
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
        if ProcessInfo.processInfo.environment["CM_PROFILE"] != nil { view.mode = .expanded; view.frozen = true }
        if let h = ProcessInfo.processInfo.environment["CM_HOVER"], let n = Int(h) { view.mode = .expanded; view.pinned = n; view.frozen = true }
        if ProcessInfo.processInfo.environment["CM_TESTSEND"] != nil { DispatchQueue.global().async { let r = MeterView.sendToNewChat(text: "Reply with just OK", cwd: home + "/Documents/Claude"); log("testsend \(r)") } }
        let frameTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.view.stepAnim(); if self?.view.mode == .working { self?.view.needsDisplay = true } }
        RunLoop.main.add(frameTimer, forMode: .common)
        view.tick(); Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.view.tick() }
        checkForUpdate { [weak self] in self?.view.needsDisplay = true }
        Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in checkForUpdate { self?.view.needsDisplay = true } }
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let delegate = AppDelegate(); app.delegate = delegate; app.run()
