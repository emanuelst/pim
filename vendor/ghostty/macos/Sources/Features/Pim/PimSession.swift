import AppKit
import Foundation
import SwiftUI
import Darwin

enum PimBranding {
    static func installMenuTitles() {
        guard Bundle.main.bundleURL.lastPathComponent == "Pim.app" else { return }

        func apply() {
            guard let mainMenu = NSApp.mainMenu else { return }
            if let applicationMenu = mainMenu.items.first(where: {
                $0.submenu?.items.contains(where: { $0.title.localizedCaseInsensitiveContains("about ") }) == true
            }) {
                applicationMenu.title = "Pim"
            }

            func update(_ menu: NSMenu) {
                for item in menu.items {
                    switch item.title {
                    case "About Ghostty": item.title = "About Pim"
                    case "Hide Ghostty": item.title = "Hide Pim"
                    case "Quit Ghostty": item.title = "Quit Pim"
                    case "Check for Updates...",
                         "Make Ghostty the Default Terminal",
                         "Ghostty Help": item.isHidden = true
                    default: break
                    }
                    // AppKit may create or localize the terminate item after the
                    // menu nib has loaded, so identify it by its action too.
                    if item.action == #selector(NSApplication.terminate(_:)) {
                        item.title = "Quit Pim"
                    }
                    if let submenu = item.submenu { update(submenu) }
                }
            }
            update(mainMenu)
        }

        apply()
        for delay in [0.05, 0.25, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { apply() }
        }
    }
}

final class PimWindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

struct PimWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> PimWindowDragView {
        PimWindowDragView()
    }

    func updateNSView(_ nsView: PimWindowDragView, context: Context) {}
}

private struct PimStatusSnapshot: Sendable {
    let states: [URL: String]
    let roles: [URL: String]
    let foregroundSession: URL?
    let liveElsewhere: Set<URL>
    let ownedSessions: Set<URL>
}

struct PimSearchResult: Identifiable, Hashable {
    let id: URL
    let title: String
    let project: String
    let snippet: String
    let modified: Date
    let transcriptMatch: Bool
}

struct PimSession: Identifiable, Hashable {
    let id: URL
    let cwd: String
    let name: String?
    let title: String?
    let provider: String?
    let model: String?
    let thinkingLevel: String?
    let totalCost: Double
    let contextTokens: Int
    let contextWindow: Int
    let modified: Date

    var displayName: String {
        if let name, !Self.isPlaceholderName(name) {
            return name
        }
        return title ?? "New Chat"
    }

    private static func isPlaceholderName(_ name: String) -> Bool {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "new chat", "new conversation", "untitled":
            return true
        default:
            return false
        }
    }

    var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    var nativeModelLabel: String? {
        guard let model else { return nil }
        let provider = provider.map { "(\($0)) " } ?? ""
        let level = thinkingLevel == nil || thinkingLevel == "off" ? "thinking off" : thinkingLevel!
        return "\(provider)\(model) • \(level)"
    }

    var costLabel: String {
        let subscription = provider == "openai-codex" ? " (sub)" : ""
        return "$\(String(format: "%.3f", totalCost))\(subscription)"
    }
}

@MainActor
final class PimSessionStore: ObservableObject {
    @Published private(set) var sessions: [PimSession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var activeSession: URL?
    @Published private(set) var activeStates: [URL: String] = [:]
    @Published private(set) var liveElsewhere: Set<URL> = []
    @Published private(set) var ownedSessions: Set<URL> = []
    @Published private(set) var switchingTo: URL?
    @Published private(set) var launchFailureSession: URL?
    @Published private(set) var launchFailureMessage: String?
    @Published private(set) var searchResults: [PimSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private var readAt: [String: TimeInterval]
    @Published private var pinnedPaths: Set<String>
    @Published private(set) var customNames: [String: String]
    private var timer: Timer?
    private var statusTimer: Timer?
    private static let readStateKey = "Pim.readAt"
    private static let pinnedKey = "Pim.pinned"
    private static let customNamesKey = "Pim.customNames"
    private static let readStateInitializedKey = "Pim.readStateInitialized"
    private var needsInitialReadMigration: Bool
    private var cache: [URL: (Date, PimSession)] = [:]
    private var refreshInFlight = false
    private var statusRefreshInFlight = false
    private var requestedActiveSession: URL?
    private var activeSessionBeforeRequest: URL?

    private static let statusFreshnessMilliseconds: Double = 10_000

    private nonisolated static var agentDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["PIM_AGENT_DIR"] ?? environment["PI_CODING_AGENT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
    }
    private var searchGeneration = 0
    private static var piIntegrationInstalled = false

    init() {
        PimIcon.install()
        Self.installPiIntegration()
        readAt = UserDefaults.standard.dictionary(forKey: Self.readStateKey) as? [String: TimeInterval] ?? [:]
        pinnedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? [])
        customNames = UserDefaults.standard.dictionary(forKey: Self.customNamesKey) as? [String: String] ?? [:]
        needsInitialReadMigration = !UserDefaults.standard.bool(forKey: Self.readStateInitializedKey)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    deinit {
        timer?.invalidate()
        statusTimer?.invalidate()
    }

    func isUnread(_ session: PimSession) -> Bool {
        guard let timestamp = readAt[session.id.path] else { return true }
        return session.modified.timeIntervalSince1970 > timestamp
    }

    func markRead(_ session: PimSession) {
        readAt[session.id.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(readAt, forKey: Self.readStateKey)
    }

    func markUnread(_ session: PimSession) {
        readAt.removeValue(forKey: session.id.path)
        UserDefaults.standard.set(readAt, forKey: Self.readStateKey)
    }

    func displayName(for session: PimSession) -> String {
        customNames[session.id.path] ?? session.displayName
    }

    func isPinned(_ session: PimSession) -> Bool {
        pinnedPaths.contains(session.id.path)
    }

    func togglePinned(_ session: PimSession) {
        if !pinnedPaths.insert(session.id.path).inserted {
            pinnedPaths.remove(session.id.path)
        }
        UserDefaults.standard.set(Array(pinnedPaths), forKey: Self.pinnedKey)
    }

    func rename(_ session: PimSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: session.id.path)
        } else {
            customNames[session.id.path] = trimmed
        }
        UserDefaults.standard.set(customNames, forKey: Self.customNamesKey)
    }

    func clearSearch() {
        searchGeneration += 1
        searchResults = []
        isSearching = false
    }

    func search(_ rawQuery: String) {
        searchGeneration += 1
        let generation = searchGeneration
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }

        let sessions = sessions
        let names = customNames
        let metadataResults = Self.metadataSearch(query: query, sessions: sessions, names: names)
        searchResults = metadataResults
        isSearching = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let transcriptMatches = Self.searchTranscript(query: query)
            Task { @MainActor [weak self] in
                guard let self, self.searchGeneration == generation else { return }
                let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
                var results = metadataResults
                let existing = Set(results.map(\.id))
                for (id, snippet) in transcriptMatches {
                    guard let session = byID[id], !existing.contains(id) else {
                        if let index = results.firstIndex(where: { $0.id == id }) {
                            results[index] = PimSearchResult(
                                id: id,
                                title: names[id.path] ?? byID[id]!.displayName,
                                project: byID[id]!.projectName,
                                snippet: snippet,
                                modified: byID[id]!.modified,
                                transcriptMatch: true)
                        }
                        continue
                    }
                    results.append(PimSearchResult(
                        id: id,
                        title: names[id.path] ?? session.displayName,
                        project: session.projectName,
                        snippet: snippet,
                        modified: session.modified,
                        transcriptMatch: true))
                }
                results.sort { $0.modified > $1.modified }
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private nonisolated static func metadataSearch(
        query: String,
        sessions: [PimSession],
        names: [String: String]
    ) -> [PimSearchResult] {
        sessions.compactMap { session in
            let title = names[session.id.path] ?? session.displayName
            let fields = [title, session.title ?? "", session.projectName, session.cwd, session.model ?? "", session.provider ?? ""]
            guard fields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { return nil }
            return PimSearchResult(
                id: session.id,
                title: title,
                project: session.projectName,
                snippet: "Chat title or metadata",
                modified: session.modified,
                transcriptMatch: false)
        }
    }

    private nonisolated static func searchTranscript(query: String) -> [URL: String] {
        let root = agentDirectory.appendingPathComponent("sessions", isDirectory: true)
        var matches: [URL: String] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return matches }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let contents = String(data: data, encoding: .utf8) else { continue }
            for line in contents.split(whereSeparator: { $0.isNewline }) {
                let raw = String(line)
                guard raw.localizedCaseInsensitiveContains(query),
                      let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
                      let entry = object as? [String: Any],
                      entry["type"] as? String == "message",
                      let text = messageText(from: entry),
                      text.localizedCaseInsensitiveContains(query) else { continue }
                matches[url] = makeSnippet(text, query: query)
                break
            }
        }
        return matches
    }

    private nonisolated static func messageText(from value: Any) -> String? {
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            let text = array.compactMap { messageText(from: $0) }.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        if let message = dictionary["message"] { return messageText(from: message) }
        if let content = dictionary["content"] { return messageText(from: content) }
        if let text = dictionary["text"] { return messageText(from: text) }
        return nil
    }

    private nonisolated static func makeSnippet(_ text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else {
            return String(text.prefix(140))
        }
        let start = text.index(range.lowerBound, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start == text.startIndex ? "" : "…"
        let suffix = end == text.endIndex ? "" : "…"
        return prefix + text[start..<end] + suffix
    }

    func createNewSession(cwd: String) -> PimSession? {
        let now = Date()
        let id = UUID().uuidString.lowercased()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let resolvedCwd = URL(fileURLWithPath: cwd).standardized.path
        let encodedCwd = resolvedCwd.hasPrefix("/") ? String(resolvedCwd.dropFirst()) : resolvedCwd
        let directory = "--\(encodedCwd.replacingOccurrences(of: "/", with: "-"))--"
        let root = Self.agentDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
        let file = root.appendingPathComponent(
            "\(timestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-"))_\(id).jsonl")
        let header: [String: Any] = [
            "type": "session",
            "version": 3,
            "id": id,
            "timestamp": timestamp,
            "cwd": cwd,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: header),
              let line = String(data: data, encoding: .utf8) else { return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        let session = PimSession(
            id: file,
            cwd: cwd,
            name: nil,
            title: nil,
            provider: nil,
            model: nil,
            thinkingLevel: nil,
            totalCost: 0,
            contextTokens: 0,
            contextWindow: 0,
            modified: now)
        sessions.append(session)
        sessions.sort { $0.modified > $1.modified }
        cache[file] = (now, session)
        return session
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        isLoading = true
        let oldCache = cache
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (sessions, cache) = Self.loadSessions(cached: oldCache)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cache = cache
                if self.sessions != sessions {
                    self.sessions = sessions
                }
                if self.needsInitialReadMigration && !sessions.isEmpty {
                    let now = Date().timeIntervalSince1970
                    for session in sessions {
                        self.readAt[session.id.path] = now
                    }
                    UserDefaults.standard.set(self.readAt, forKey: Self.readStateKey)
                    UserDefaults.standard.set(true, forKey: Self.readStateInitializedKey)
                    self.needsInitialReadMigration = false
                }
                self.refreshInFlight = false
                self.isLoading = false
            }
        }
    }

    private func refreshStatus() {
        guard !statusRefreshInFlight else { return }
        statusRefreshInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = Self.loadStatus()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyStatus(status)
                self.statusRefreshInFlight = false
            }
        }
    }

    private func applyStatus(_ status: PimStatusSnapshot) {
        if activeStates != status.states { activeStates = status.states }
        if liveElsewhere != status.liveElsewhere { liveElsewhere = status.liveElsewhere }
        if ownedSessions != status.ownedSessions { ownedSessions = status.ownedSessions }
    }

    /// Starts a visual switch without changing the session whose surface is
    /// currently on screen. The controller completes this only after Pi has
    /// published its status file, so a failed launch never exposes the
    /// bootstrap shell.
    func requestActiveSession(_ session: URL, showLoading: Bool = true) {
        launchFailureSession = nil
        launchFailureMessage = nil
        if showLoading {
            activeSessionBeforeRequest = activeSession
            requestedActiveSession = session
            switchingTo = session
        } else {
            activeSessionBeforeRequest = nil
            requestedActiveSession = nil
            switchingTo = nil
            activeSession = session
        }
    }

    func reportLaunchFailure(_ session: URL, message: String) {
        guard requestedActiveSession == session || switchingTo == session else { return }
        requestedActiveSession = nil
        switchingTo = nil
        activeSession = activeSessionBeforeRequest
        activeSessionBeforeRequest = nil
        launchFailureSession = session
        launchFailureMessage = message
    }

    func clearActiveSession() {
        requestedActiveSession = nil
        activeSessionBeforeRequest = nil
        switchingTo = nil
        activeSession = nil
        launchFailureSession = nil
        launchFailureMessage = nil
    }

    private nonisolated static func loadStatus() -> PimStatusSnapshot {
        let root = agentDirectory
        var states: [URL: String] = [:]
        var roles: [URL: String] = [:]
        var liveElsewhere = Set<URL>()
        var ownedSessions = Set<URL>()
        var newestForeground: (URL, Double)?
        if let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in files where url.lastPathComponent.hasPrefix("pim-status-") {
                guard let data = try? Data(contentsOf: url),
                      let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let path = status["session"] as? String,
                      let state = status["state"] as? String else { continue }
                let version = (status["version"] as? NSNumber)?.intValue ?? 0
                let updatedAt = (status["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                // Version 2 processes have a heartbeat, so stale files can be
                // discarded. Older Pi processes do not heartbeat, but their
                // status is still useful when the recorded process is alive.
                if version == 2,
                   updatedAt < Date().timeIntervalSince1970 * 1000 - statusFreshnessMilliseconds {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                guard let pid = (status["pid"] as? NSNumber)?.int32Value,
                      pid > 0 else { continue }
                if kill(pid, 0) != 0 {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                if let processStart = processStartTimeMilliseconds(pid) {
                    if processStart > updatedAt + 1_000 {
                        // The PID was reused after this status was written.
                        try? FileManager.default.removeItem(at: url)
                        continue
                    }
                } else if processExecutableName(pid) != "node" {
                    // Root-owned processes can hide their start time. Reject
                    // them unless the executable still looks like Pi's Node process.
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                let session = URL(fileURLWithPath: path)
                if state == "working" || states[session] == nil {
                    states[session] = state
                }
                let ownerPid = (status["ownerPid"] as? NSNumber)?.intValue
                if ownerPid == Int(ProcessInfo.processInfo.processIdentifier) {
                    ownedSessions.insert(session)
                } else {
                    liveElsewhere.insert(session)
                }
                let role = status["role"] as? String ?? "foreground"
                roles[session] = role
                if role != "background" && (newestForeground == nil || updatedAt > newestForeground!.1) {
                    newestForeground = (session, updatedAt)
                }
            }
        }
        return PimStatusSnapshot(
            states: states,
            roles: roles,
            foregroundSession: newestForeground?.0,
            liveElsewhere: liveElsewhere,
            ownedSessions: ownedSessions)
    }

    private nonisolated static func processExecutableName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    private nonisolated static func processStartTimeMilliseconds(_ pid: Int32) -> Double? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.stride)) == Int32(MemoryLayout<proc_bsdinfo>.stride) else {
            return nil
        }
        return Double(info.pbi_start_tvsec) * 1000 + Double(info.pbi_start_tvusec) / 1000
    }

    nonisolated static func loadSessions() -> [PimSession] {
        loadSessions(cached: [:]).0
    }

    private nonisolated static func loadSessions(cached: [URL: (Date, PimSession)]) -> ([PimSession], [URL: (Date, PimSession)]) {
        var sessions: [PimSession] = []
        var nextCache: [URL: (Date, PimSession)] = [:]
        let root = agentDirectory.appendingPathComponent("sessions", isDirectory: true)
        let contextWindows = modelContextWindows()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], [:]) }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            if let cached = cached[url], cached.0 == modified {
                sessions.append(cached.1)
                nextCache[url] = cached
            } else if let session = read(url, modified: modified, contextWindows: contextWindows) {
                sessions.append(session)
                nextCache[url] = (modified, session)
            }
        }
        return (sessions.sorted { $0.modified > $1.modified }, nextCache)
    }

    private(set) static var initialSessionID: URL?

    static func initialConfiguration() -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        let cwd = FileManager.default.currentDirectoryPath
        // Do not scan and parse the entire session tree while Ghostty is
        // constructing the first terminal. The sidebar refreshes it off-main
        // and will resume the matching session once the metadata is ready.
        initialSessionID = nil
        config.workingDirectory = cwd
        // Start with an inert shell behind Pim's native empty state. Pim
        // should open in a choose-a-chat mode, not create/select a Pi session.
        config.command = shellCommand()
        return config
    }

    static func launchCommand(for session: PimSession) -> String {
        "\(piCommand()) --session \(quote(session.id.path))"
    }

    static func launchCommand() -> String {
        piCommand()
    }

    static func launchInput(for session: PimSession) -> String {
        "exec \(launchCommand(for: session))\r"
    }

    static func shellCommand() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return "\(quote(shell)) -l"
    }

    static func pimBootstrapShellCommand() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return "\(quote(shell)) -f -i"
    }

    /// GUI-launched macOS apps do not inherit the user's shell PATH. The pnpm
    /// pi shim invokes `node` by name, so provide the usual Node/package paths
    /// explicitly to every Pi child.
    static func childEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = [
            "\(home)/Library/pnpm/bin",
            "\(home)/Library/pnpm",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var paths: [String] = []
        for path in fallback + existing where !paths.contains(path) {
            paths.append(path)
        }
        let agentPath = agentDirectory.path
        return [
            "PATH": paths.joined(separator: ":"),
            "PIM_AGENT_DIR": agentPath,
            "PI_CODING_AGENT_DIR": agentPath,
            "PIM_OWNER_PID": String(ProcessInfo.processInfo.processIdentifier),
        ]
    }

    static func workspaceDirectory() -> String {
        if let override = ProcessInfo.processInfo.environment["PIM_WORKSPACE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override).standardized.path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func resumeCommand(for session: PimSession) -> String {
        let encodedPath = Data(session.id.path.utf8).base64EncodedString()
        return "/pim-resume \(encodedPath)\r"
    }

    private static func piCommand() -> String {
        let bundledPath = Bundle.main.url(forResource: "pim-bridge", withExtension: "ts")?.path
        let installedPath = agentDirectory
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("pim-integration.ts").path
        // Pass the bridge explicitly. Use the discovered copy when available so
        // Pi's normal user extensions remain enabled without loading this bridge twice.
        let extensionPath = piIntegrationInstalled ? installedPath : bundledPath
        let extensionArgument = extensionPath.map { " -e \(quote($0))" } ?? ""
        return "\(quote(piExecutable))\(extensionArgument)"
    }

    private static func installPiIntegration() {
        guard Bundle.main.bundleURL.lastPathComponent == "Pim.app",
              let source = Bundle.main.url(forResource: "pim-bridge", withExtension: "ts"),
              let data = try? Data(contentsOf: source) else { return }
        let target = agentDirectory
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("pim-integration.ts")
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let existing = try? Data(contentsOf: target)
            if existing != Optional(data) {
                try data.write(to: target, options: .atomic)
            }
            piIntegrationInstalled = true
        } catch {
            piIntegrationInstalled = false
        }
    }

    private static var piExecutable: String {
        if let configured = ProcessInfo.processInfo.environment["PIM_PI_PATH"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/pnpm/bin/pi",
            "\(home)/.bun/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "pi"
    }

    private nonisolated static func read(_ url: URL, modified: Date, contextWindows: [String: Int]) -> PimSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var cwd: String?
        var name: String?
        var title: String?
        var provider: String?
        var model: String?
        var thinkingLevel: String?
        var usedProvider: String?
        var usedModel: String?
        var totalCost = 0.0
        var contextTokens = 0

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "session", cwd == nil {
                cwd = object["cwd"] as? String
            } else if type == "session_info" {
                name = object["name"] as? String
            } else if type == "model_change" {
                provider = object["provider"] as? String
                model = object["modelId"] as? String
            } else if type == "thinking_level_change" {
                thinkingLevel = object["thinkingLevel"] as? String
            } else if type == "message",
                      let message = object["message"] as? [String: Any] {
                if message["role"] as? String == "assistant" {
                    usedProvider = message["provider"] as? String ?? usedProvider
                    usedModel = message["model"] as? String ?? usedModel
                    if let usage = message["usage"] as? [String: Any] {
                        let number: (Any?) -> Double = { ($0 as? NSNumber)?.doubleValue ?? 0 }
                        if let cost = usage["cost"] as? [String: Any] {
                            totalCost += number(cost["total"])
                        }
                        if object["stopReason"] as? String != "aborted" {
                            contextTokens = ["input", "output", "cacheRead", "cacheWrite"]
                                .reduce(0) { $0 + Int(number(usage[$1])) }
                        }
                    }
                }
                guard title == nil, message["role"] as? String == "user" else { continue }
                let text = if let text = message["content"] as? String {
                    text
                } else if let content = message["content"] as? [[String: Any]] {
                    content.compactMap { $0["text"] as? String }.joined(separator: " ")
                } else {
                    ""
                }
                if !text.isEmpty, title == nil {
                    title = autoTitle(from: text)
                }
            }
        }

        guard let cwd else { return nil }
        return PimSession(
            id: url,
            cwd: cwd,
            name: name,
            title: title,
            provider: usedProvider ?? provider,
            model: usedModel ?? model,
            thinkingLevel: thinkingLevel,
            totalCost: totalCost,
            contextTokens: contextTokens,
            contextWindow: contextWindows["\(usedProvider ?? provider ?? "")/\(usedModel ?? model ?? "")"] ?? 0,
            modified: modified)
    }

    private nonisolated static func autoTitle(from text: String) -> String? {
        var proseLines: [String] = []
        var inCodeBlock = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if !inCodeBlock, !line.isEmpty {
                proseLines.append(line)
            }
        }

        var candidate = (proseLines.isEmpty ? text : proseLines.joined(separator: " "))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        while candidate.hasPrefix("#") {
            candidate.removeFirst()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lowercased = candidate.lowercased()
        for prefix in [
            "can you ", "could you ", "please ", "help me ",
            "i need help with ", "i need you to ", "i want you to "
        ] where lowercased.hasPrefix(prefix) {
            candidate.removeFirst(prefix.count)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        if let end = candidate.firstIndex(where: { ".!?".contains($0) }) {
            candidate = String(candidate[..<end])
        }
        while let last = candidate.last, ".!?".contains(last) {
            candidate.removeLast()
        }
        guard !candidate.isEmpty else { return nil }

        let maxLength = 56
        var shortened = ""
        for word in candidate.split(separator: " ") {
            let next = shortened.isEmpty ? String(word) : shortened + " " + word
            if next.count > maxLength { break }
            shortened = next
        }
        if shortened.isEmpty {
            shortened = String(candidate.prefix(maxLength))
        }
        return shortened == candidate ? shortened : shortened + "…"
    }

    private nonisolated static func modelContextWindows() -> [String: Int] {
        let url = agentDirectory.appendingPathComponent("models-store.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: Int] = [:]
        for (provider, value) in root {
            guard let models = value as? [[String: Any]] else { continue }
            for model in models {
                guard let id = model["id"] as? String,
                      let contextWindow = (model["contextWindow"] as? NSNumber)?.intValue else { continue }
                result["\(provider)/\(id)"] = contextWindow
            }
        }
        return result
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum PimIcon {
    static func install() {
        guard Bundle.main.bundleURL.lastPathComponent == "Pim.app",
              let url = Bundle.main.url(forResource: "Pim", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
        NSApp.dockTile.display()
    }
}

private struct PimGlassBackground: NSViewRepresentable {
    let superGlass: Bool

    func makeNSView(context: Context) -> NSView {
        PimIcon.install()
        if superGlass, #available(macOS 26.0, *) {
            // This is the native AppKit Liquid Glass implementation. Unlike
            // a SwiftUI glass modifier on an empty Color, NSGlassEffectView
            // actually participates in the window's content-lensing pass.
            let view = NSGlassEffectView()
            view.style = .clear
            view.cornerRadius = 0
            return view
        }

        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        PimIcon.install()
        if #available(macOS 26.0, *) {
            if let glass = view as? NSGlassEffectView {
                glass.style = .clear
                glass.cornerRadius = 0
            } else if let visual = view as? NSVisualEffectView {
                visual.material = .sidebar
                visual.blendingMode = .withinWindow
                visual.state = .active
            }
        } else if let visual = view as? NSVisualEffectView {
            visual.material = .sidebar
            visual.blendingMode = .withinWindow
            visual.state = .active
        }
        Self.configureWindow(view.window)
        // SwiftUI can call updateNSView before the representable is attached
        // to the window. Reapply once attachment and Ghostty's initial window
        // sync have completed so a fresh launch matches a later toggle.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            Self.configureWindow(view.window)
        }
    }

    private static func configureWindow(_ window: NSWindow?) {
        guard let window else { return }
        // Keep the window transparent in both modes so toggling does not
        // create a third intermediate appearance.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
    }
}

@MainActor
final class PimSidebarVisibility: ObservableObject {
    @Published var isVisible = true
}

@MainActor
final class PimSearchState: ObservableObject {
    @Published var isPresented = false
}

@MainActor
final class PimSearchAccessoryViewController: NSTitlebarAccessoryViewController {
    private let state: PimSearchState
    private let button = NSButton()

    init(state: PimSearchState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        preferredContentSize = NSSize(width: 32, height: 32)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.focusRingType = .none
        button.contentTintColor = .secondaryLabelColor
        button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Search Chats and Transcripts"
        button.setAccessibilityLabel("Search Chats and Transcripts")
        button.target = self
        button.action = #selector(openSearch)
        button.keyEquivalent = "f"
        button.keyEquivalentModifierMask = [.command]
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = container
    }

    @objc private func openSearch() {
        state.isPresented = true
    }
}

@MainActor
final class PimSidebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private let visibility: PimSidebarVisibility
    private let button = NSButton()

    init(visibility: PimSidebarVisibility) {
        self.visibility = visibility
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 32))
        preferredContentSize = NSSize(width: 36, height: 32)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.focusRingType = .none
        button.showsBorderOnlyWhileMouseInside = false
        button.contentTintColor = .secondaryLabelColor
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(toggleSidebar)
        button.keyEquivalent = "s"
        button.keyEquivalentModifierMask = [.command, .option]
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        view = container
        updateButton()
    }

    @objc private func toggleSidebar() {
        visibility.isVisible.toggle()
        updateButton()
    }

    private func updateButton() {
        // The control is an action, not a selected tab: keep the glyph stable
        // and let the sidebar itself communicate the resulting state.
        let symbol = "sidebar.left"
        let label = visibility.isVisible ? "Hide Sidebar" : "Show Sidebar"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
}

final class PimTerminalAppearance: ObservableObject {
    @Published var backgroundColor = Color(nsColor: .windowBackgroundColor)
    @Published var backgroundOpacity = 1.0
    @Published var glass: BackportGlass?

    var usesLightForeground: Bool {
        NSColor(backgroundColor).isLightColor
    }

    func update(
        backgroundColor: Color,
        backgroundOpacity: Double,
        backgroundBlur: Ghostty.Config.BackgroundBlur
    ) {
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        switch backgroundBlur {
        case .macosGlassRegular:
            glass = .regular
        case .macosGlassClear:
            glass = .clear
        default:
            glass = nil
        }
    }
}

struct PimTitleBar: View {
    @ObservedObject var store: PimSessionStore
    @ObservedObject var appearance: PimTerminalAppearance

    var body: some View {
        ZStack {
            PimWindowDragRegion()
                .frame(height: 28)
            HStack(spacing: 5) {
                Text(currentSession.map { store.displayName(for: $0) } ?? "Pim")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(appearance.usesLightForeground ? Color.black : Color.white)
            .allowsHitTesting(false)
        }
        // This is a compact content toolbar, not a second glass surface. Match
        // the terminal tint exactly and let the native window titlebar remain
        // responsible for the area above it.
        .frame(height: 28)
        .background(appearance.backgroundColor.opacity(appearance.backgroundOpacity))
    }

    private var currentSession: PimSession? {
        let id = store.switchingTo ?? store.activeSession
        return store.sessions.first { $0.id == id }
    }
}

struct PimEmptyState: View {
    @ObservedObject var appearance: PimTerminalAppearance

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select a chat")
                .font(.headline)
            Text("Choose a conversation from the sidebar to open it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Fully cover the inert bootstrap terminal. Its login banner must
        // never leak through the choose-a-chat state.
        .background(appearance.backgroundColor)
        .contentShape(Rectangle())
    }
}

struct PimLoadingOverlay: View {
    @ObservedObject var store: PimSessionStore
    @ObservedObject var appearance: PimTerminalAppearance
    let onRetry: (PimSession) -> Void

    var body: some View {
        if let failureID = store.launchFailureSession {
            let failureSession = store.sessions.first(where: { $0.id == failureID })
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.orange)
                Text("Couldn’t open \(failureSession.map { store.displayName(for: $0) } ?? "chat")")
                    .font(.headline)
                    .lineLimit(1)
                Text(store.launchFailureMessage ?? "Pi exited before the chat was ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let failureSession {
                    Button("Try Again") { onRetry(failureSession) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .foregroundStyle(appearance.usesLightForeground ? Color.black : Color.white)
            .background(appearance.backgroundColor)
            .transition(.opacity)
        } else if let loadingID = store.switchingTo {
            let loadingName = store.sessions
                .first(where: { $0.id == loadingID })
                .map { store.displayName(for: $0) } ?? "chat"
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
                Text("Opening \(loadingName)")
                    .font(.headline)
                    .lineLimit(1)
                Text("Starting Pi…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(appearance.usesLightForeground ? Color.black : Color.white)
            // Loading is part of the terminal surface, not a floating panel.
            .background(appearance.backgroundColor)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: store.switchingTo)
        }
    }
}

struct PimAboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            }
            Text("Pim")
                .font(.title.bold())
        }
        .padding(36)
        .frame(width: 280, height: 250)
        .background(.regularMaterial)
    }
}

struct PimSearchPanel: View {
    @ObservedObject var store: PimSessionStore
    @ObservedObject var state: PimSearchState
    let onOpen: (PimSession) -> Void
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search chats and transcripts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onSubmit {
                        if let result = selectedResult { open(result) }
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                Text("Search chat names and transcript text")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else if store.searchResults.isEmpty && store.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching all chats…")
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else if store.searchResults.isEmpty {
                Text("No matching chats")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.searchResults.enumerated()), id: \.element.id) { index, result in
                            Button {
                                selectedIndex = index
                                open(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        if let session = store.sessions.first(where: { $0.id == result.id }),
                                           store.isPinned(session) {
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text(result.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(result.modified, style: .relative)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(result.project)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(result.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background(
                                index == selectedIndex ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(10)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onAppear {
            searchFieldFocused = true
            selectedIndex = 0
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard state.isPresented else { return event }
                switch event.keyCode {
                case 125: // Down arrow
                    guard !store.searchResults.isEmpty else { return event }
                    selectedIndex = min(selectedIndex + 1, store.searchResults.count - 1)
                    return nil
                case 126: // Up arrow
                    guard !store.searchResults.isEmpty else { return event }
                    selectedIndex = max(selectedIndex - 1, 0)
                    return nil
                case 36: // Return
                    if let result = selectedResult {
                        open(result)
                        return nil
                    }
                case 53: // Escape
                    state.isPresented = false
                    return nil
                default:
                    break
                }
                return event
            }
        }
        .onChange(of: query) { newValue in
            selectedIndex = 0
            store.search(newValue)
        }
        .onChange(of: store.searchResults) { _ in
            selectedIndex = min(selectedIndex, max(store.searchResults.count - 1, 0))
        }
        .onExitCommand { state.isPresented = false }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            store.clearSearch()
        }
    }

    private var selectedResult: PimSearchResult? {
        guard store.searchResults.indices.contains(selectedIndex) else { return nil }
        return store.searchResults[selectedIndex]
    }

    private func open(_ result: PimSearchResult) {
        guard let session = store.sessions.first(where: { $0.id == result.id }) else { return }
        state.isPresented = false
        onOpen(session)
    }
}

private final class PimEffectiveAppearanceObserverView: NSView {
    var onChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onChange?()
    }
}

private struct PimEffectiveAppearanceObserver: NSViewRepresentable {
    let onChange: () -> Void

    func makeNSView(context: Context) -> PimEffectiveAppearanceObserverView {
        let view = PimEffectiveAppearanceObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: PimEffectiveAppearanceObserverView, context: Context) {
        view.onChange = onChange
    }
}

struct PimWorkspace<ViewModel: TerminalViewModel>: View {
    @ObservedObject var store: PimSessionStore
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var viewModel: ViewModel
    let delegate: (any TerminalViewDelegate)?
    @ObservedObject var appearance: PimTerminalAppearance
    @ObservedObject var sidebarVisibility: PimSidebarVisibility
    @ObservedObject var searchState: PimSearchState
    let onAppearanceChange: () -> Void
    @AppStorage("Pim.superGlass") private var superGlass = false
    let onOpen: (PimSession) -> Void
    let onNew: () -> Void
    let onClose: (PimSession) -> Void
    let canClose: (PimSession) -> Bool

    var body: some View {
        ZStack(alignment: .top) {
            HSplitView {
                if sidebarVisibility.isVisible {
                    PimSidebar(
                        store: store,
                        searchState: searchState,
                        onOpen: onOpen,
                        onNew: onNew,
                        onClose: onClose,
                        canClose: canClose)
                }
                VStack(spacing: 0) {
                    PimTitleBar(store: store, appearance: appearance)
                    ZStack {
                        TerminalView(ghostty: ghostty, viewModel: viewModel, delegate: delegate)
                        if store.activeSession == nil && store.switchingTo == nil {
                            PimEmptyState(appearance: appearance)
                        }
                        PimLoadingOverlay(store: store, appearance: appearance, onRetry: onOpen)
                    }
                }
            }
            if searchState.isPresented {
                PimSearchPanel(store: store, state: searchState, onOpen: onOpen)
                    .padding(.top, 8)
                    .zIndex(1)
            }
            PimEffectiveAppearanceObserver(onChange: onAppearanceChange)
                .frame(width: 0, height: 0)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            // One native surface owns the sidebar and title background in
            // normal mode. This avoids a transparent window when Super Glass
            // is disabled and prevents a material seam at the split.
            PimGlassBackground(superGlass: superGlass)
                .id("workspace-glass-\(superGlass)")
                .opacity(superGlass ? 1.0 : 0.75)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
    }
}

struct PimSidebar: View {
    @ObservedObject var store: PimSessionStore
    @ObservedObject var searchState: PimSearchState
    @State private var selection: PimSession.ID?
    @State private var programmaticSelection: PimSession.ID?
    @State private var renamingSession: PimSession.ID?
    @State private var renameDraft = ""
    @AppStorage("Pim.superGlass") private var superGlass = false
    let onOpen: (PimSession) -> Void
    let onNew: () -> Void
    let onClose: (PimSession) -> Void
    let canClose: (PimSession) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.headline)
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading chats")
                }
                Spacer()
                Button {
                    searchState.isPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Search Chats and Transcripts")
                .keyboardShortcut("f", modifiers: [.command])
                Button {
                    superGlass.toggle()
                } label: {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(superGlass ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(superGlass ? "Turn Off Super Glass" : "Super Glass")
                Button(action: onNew) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Chat")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List(selection: $selection) {
                let pinned = store.sessions.filter { store.isPinned($0) }
                let recents = store.sessions.filter { !store.isPinned($0) }
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned, id: \.id) { sessionRow($0) }
                    }
                }
                Section("Recents") {
                    ForEach(recents, id: \.id) { sessionRow($0) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: store.activeSession) { activeSession in
                guard let activeSession else {
                    selection = nil
                    return
                }
                DispatchQueue.main.async {
                    guard selection != activeSession else { return }
                    programmaticSelection = activeSession
                    selection = activeSession
                }
            }
            .onChange(of: selection) { selection in
                if programmaticSelection == selection {
                    programmaticSelection = nil
                    return
                }
                scheduleOpen(selection)
            }
            .onSubmit {
                scheduleOpen(selection)
            }
        }
        // Keep the sidebar's content below the native titlebar controls. The
        // heading now belongs to the sidebar, not to the titlebar toolbar.
        .padding(.top, 30)
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 460)
        .alert("Rename Chat", isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField("Chat name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingSession = nil }
            Button("Save") {
                if let id = renamingSession,
                   let session = store.sessions.first(where: { $0.id == id }) {
                    store.rename(session, to: renameDraft)
                }
                renamingSession = nil
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: PimSession) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if store.isPinned(session) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(store.displayName(for: session))
                    .font(.system(size: 13, weight: store.isUnread(session) ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(ageLabel(session.modified))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if store.liveElsewhere.contains(session.id) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Live elsewhere")
                    if store.activeStates[session.id] == "working" {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .tint(.orange)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Working elsewhere")
                    }
                } else if let state = store.activeStates[session.id] {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Warm")
                    if state == "working" {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .tint(.orange)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Working")
                    }
                } else {
                    Circle()
                        .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Cold")
                }
                if store.isUnread(session) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Unread")
                }
            }
            HStack(spacing: 4) {
                Text(session.projectName)
                    .lineLimit(1)
                if store.liveElsewhere.contains(session.id) {
                    Text("· Live elsewhere")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if let model = session.nativeModelLabel {
                HStack(spacing: 6) {
                    Text(model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(session.costLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
        }
        .contextMenu {
            Button(store.isPinned(session) ? "Unpin" : "Pin") {
                store.togglePinned(session)
            }
            Button("Rename…") {
                renameDraft = store.displayName(for: session)
                renamingSession = session.id
            }
            Divider()
            Button(store.isUnread(session) ? "Mark as Read" : "Mark as Unread") {
                if store.isUnread(session) {
                    store.markRead(session)
                } else {
                    store.markUnread(session)
                }
            }
            if store.ownedSessions.contains(session.id), canClose(session) {
                Divider()
                Button("Close Terminal…") {
                    onClose(session)
                }
            }
        }
        .padding(.vertical, 1)
        .tag(session.id)
        .listRowBackground(Color.clear)
    }

    private func scheduleOpen(_ id: PimSession.ID?) {
        guard let id,
              let session = store.sessions.first(where: { $0.id == id }) else { return }
        DispatchQueue.main.async {
            guard selection == id else { return }
            onOpen(session)
        }
    }

    private func ageLabel(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 604800 { return "\(Int(seconds / 86400))d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
