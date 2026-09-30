import Foundation

/// Talks to keepd over its unix socket.
///
/// Mirrors `crates/keep-proto`: frames are `[tag: u8][len: u32 be][payload]`.
/// Kept deliberately small — the app only needs to enumerate and kill
/// workspaces. Terminal I/O never comes through here; a surface runs the
/// `keep` client as its child process instead.
enum Daemon {
    struct Tab: Identifiable, Hashable {
        var id: UInt32
        var cols: UInt16
        var rows: UInt16
        var clients: UInt32
        var finished: Bool
        /// What the program inside called itself (OSC 0/2). Often empty.
        var title: String
        /// A command is running, as opposed to a shell waiting at a prompt.
        var busy: Bool
        /// The tab this one is a pane of (0 = standalone), and where it sits.
        var splitOf: UInt32
        var splitDir: UInt8
        /// Where the tab's foreground process is working. Empty when the
        /// daemon could not read it, and always empty from a daemon that
        /// predates the field.
        var cwd: String = ""
        /// When a byte last went either way. Nil from a daemon too old to
        /// say, which the picker shows as no time at all rather than as now.
        var lastActive: Date?
        /// What is holding the terminal — `claude`, `nvim`, `zsh`. Empty from
        /// a daemon too old to say.
        var command: String = ""

        /// Shells retitle constantly and usually with the host and path,
        /// which says nothing useful in a list of tabs from one machine.
        var label: String {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "Tab \(id)" }
            if let tail = trimmed.split(separator: ":").last, trimmed.contains("@") {
                return String(tail)
            }
            return trimmed
        }
    }

    struct Workspace: Identifiable, Hashable {
        var name: String
        var tabs: [Tab]
        var id: String { name }

        var clients: UInt32 { tabs.reduce(0) { $0 + $1.clients } }
        var liveTabs: [Tab] { tabs.filter { !$0.finished } }

        /// Tabs that anchor a window; panes hang off one of these.
        var rootTabs: [Tab] { liveTabs.filter { $0.splitOf == 0 } }

        /// The panes belonging to a root, in creation order, following chains
        /// (a pane split from a pane still lands in the root's window).
        func panes(of root: UInt32) -> [Tab] {
            var owner: [UInt32: UInt32] = [:]
            for t in liveTabs { owner[t.id] = t.splitOf }
            func rootOf(_ id: UInt32) -> UInt32 {
                var cur = id
                var hops = 0
                while let up = owner[cur], up != 0, hops < 64 {
                    cur = up
                    hops += 1
                }
                return cur
            }
            return liveTabs.filter { $0.splitOf != 0 && rootOf($0.id) == root }
        }
        /// Any tab actually running something.
        var busy: Bool { liveTabs.contains { $0.busy } }

        /// What the session is doing matters more than who is watching it, so
        /// running wins over attached.
        var stateLabel: String {
            if liveTabs.isEmpty { return "empty" }
            if busy { return "running" }
            return clients > 0 ? "attached" : "idle"
        }
    }

    enum Failure: Error, LocalizedError {
        case cannotConnect(String)
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .cannotConnect(let p): return "cannot reach the keep daemon at \(p)"
            case .protocolError(let m): return "protocol error: \(m)"
            }
        }
    }

    private static let tagList: UInt8 = 0x01
    private static let tagList2: UInt8 = 0x0d
    private static let tagNewTab: UInt8 = 0x03
    private static let tagKill: UInt8 = 0x06
    private static let tagCloseTab: UInt8 = 0x07
    private static let tagPreview: UInt8 = 0x08
    private static let tagPreviewVt: UInt8 = 0x0b
    private static let tagMoveTab: UInt8 = 0x0c
    private static let tagSearch: UInt8 = 0x09
    private static let tagSessions: UInt8 = 0x81
    private static let tagSessions2: UInt8 = 0x9b
    private static let tagError: UInt8 = 0x84
    private static let tagOk: UInt8 = 0x85
    private static let tagTabCreated: UInt8 = 0x88
    private static let tagPreviewText: UInt8 = 0x89
    private static let tagRearrange: UInt8 = 0x0a
    private static let tagSearchHits: UInt8 = 0x9a

    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["KEEP_SOCKET"] {
            return override
        }
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
            ?? ProcessInfo.processInfo.environment["TMPDIR"]
            ?? "/tmp"
        let who = ProcessInfo.processInfo.environment["USER"] ?? "default"
        return (base as NSString).appendingPathComponent("keep-\(who).sock")
    }

    /// When the running daemon started, as the birth of its socket says.
    ///
    /// Tab ids are the daemon's and start over when it does; anything the app
    /// keeps against an id needs to know which daemon it was kept under.
    static var startedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: socketPath))?[.creationDate] as? Date
    }

    /// Start keepd if nothing is listening yet.
    ///
    /// The daemon is not a child of this app: it has to outlive every client,
    /// including the window that happened to launch it.
    static func ensureRunning() throws {
        try KeepStateFile.validateConnection(socket: socketPath, directory: stateDirectory())
        if let fd = try? connect() {
            close(fd)
            return
        }
        let candidates = [
            ProcessInfo.processInfo.environment["KEEPD_BIN"],
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/keepd").path,
            "/usr/local/bin/keepd",
        ].compactMap { $0 }

        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw Failure.cannotConnect(socketPath) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let fd = try? connect() {
                close(fd)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure.cannotConnect(socketPath)
    }

    /// Every workspace and its tabs.
    ///
    /// Asked twice over, the fuller question first, the same way
    /// `colouredPreview` asks for a preview: a daemon that predates `cwd` and
    /// `lastActive` closes on the tag it does not know, and a list without
    /// them is better than no list. The daemon outlives every client, so the
    /// app will meet one older than itself whenever it is rebuilt — and that
    /// is exactly when nobody wants to be told to restart it and lose their
    /// sessions.
    static func list() throws -> [Workspace] {
        do {
            return try askForList(tag: tagList2)
        } catch {
            return try askForList(tag: tagList)
        }
    }

    private static func askForList(tag question: UInt8) throws -> [Workspace] {
        let sock = try connect()
        defer { close(sock) }
        try send(sock, tag: question, payload: Data())

        let (tag, payload) = try recv(sock)
        switch tag {
        case tagSessions:
            return try decodeWorkspaces(payload, withCwd: false)
        case tagSessions2:
            return try decodeWorkspaces(payload, withCwd: true)
        case tagError:
            var r = Reader(payload)
            throw Failure.protocolError(try r.string())
        default:
            throw Failure.protocolError("unexpected reply tag \(tag)")
        }
    }

    /// Open a new tab in a workspace, creating the workspace if needed.
    /// Returns the new tab's id.
    @discardableResult
    static func newTab(
        in workspace: String,
        cwd: String = "",
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        splitOf: UInt32 = 0,
        splitDir: UInt8 = 0
    ) throws -> UInt32 {
        let sock = try connect()
        defer { close(sock) }
        var w = Writer()
        w.string(workspace)
        w.string(cwd)          // empty: inherit the daemon's
        w.u16(cols)
        w.u16(rows)
        w.u32(splitOf)
        w.data.append(splitDir)
        try send(sock, tag: tagNewTab, payload: w.data)

        let (tag, payload) = try recv(sock)
        var r = Reader(payload)
        switch tag {
        case tagTabCreated: return try r.u32()
        case tagError: throw Failure.protocolError(try r.string())
        default: throw Failure.protocolError("unexpected reply tag \(tag)")
        }
    }

    static func closeTab(_ tab: UInt32, in workspace: String) throws {
        let sock = try connect()
        defer { close(sock) }
        var w = Writer()
        w.string(workspace)
        w.u32(tab)
        try send(sock, tag: tagCloseTab, payload: w.data)

        let (tag, payload) = try recv(sock)
        if tag == tagError {
            var r = Reader(payload)
            throw Failure.protocolError(try r.string())
        }
    }

    /// Where one pane should end up.
    struct Move {
        let tab: UInt32
        let splitOf: UInt32
        let splitDir: UInt8
    }

    /// Put panes somewhere else in the arrangement, all of them or none.
    static func rearrange(_ moves: [Move], in workspace: String) throws {
        guard !moves.isEmpty else { return }
        let sock = try connect()
        defer { close(sock) }
        var w = Writer()
        w.string(workspace)
        w.u32(UInt32(moves.count))
        for move in moves {
            w.u32(move.tab)
            w.u32(move.splitOf)
            w.u8(move.splitDir)
        }
        try send(sock, tag: tagRearrange, payload: w.data)

        let (tag, payload) = try recv(sock)
        if tag == tagError {
            var r = Reader(payload)
            throw Failure.protocolError(try r.string())
        }
    }

    /// A tab's screen as plain text, without attaching to it.
    ///
    /// The daemon holds every tab's grid, so showing what a tab is doing
    /// costs a snapshot rather than a client — including for tabs of a
    /// workspace this app has never opened.
    /// The screen a preview shows, with its colours still on it.
    ///
    /// Falls back to the plain one, which every daemon has answered since
    /// before this existed: an older daemon reading a tag it does not know
    /// closes the connection, and a preview that arrives without colour is
    /// better than a preview that does not arrive.
    static func colouredPreview(workspace: String, tab: UInt32) throws -> String {
        do {
            return try preview(workspace: workspace, tab: tab, tag: tagPreviewVt)
        } catch {
            return try preview(workspace: workspace, tab: tab)
        }
    }

    static func preview(
        workspace: String, tab: UInt32, tag: UInt8 = tagPreview
    ) throws -> String {
        let sock = try connect()
        defer { close(sock) }
        var w = Writer()
        w.string(workspace)
        w.u32(tab)
        try send(sock, tag: tag, payload: w.data)

        let (tag, payload) = try recv(sock)
        var r = Reader(payload)
        switch tag {
        case tagPreviewText: return try r.string()
        case tagError: throw Failure.protocolError(try r.string())
        default: throw Failure.protocolError("unexpected reply tag \(tag)")
        }
    }

    /// Move a tab — panes and all — to another workspace. The shells carry
    /// on untouched; the reply is the tab's id in its new home.
    static func moveTab(_ tab: UInt32, from workspace: String, to: String) throws -> UInt32 {
        let sock = try connect()
        defer { close(sock) }
        var w = Writer()
        w.string(workspace)
        w.u32(tab)
        w.string(to)
        try send(sock, tag: tagMoveTab, payload: w.data)

        let (tag, payload) = try recv(sock)
        var r = Reader(payload)
        switch tag {
        case tagTabCreated: return try r.u32()
        case tagError: throw Failure.protocolError(try r.string())
        default: throw Failure.protocolError("unexpected reply tag \(tag)")
        }
    }

    struct Hit: Hashable {
        var workspace: String
        var tab: UInt32
        var line: UInt32
        /// How many lines the tab's history holds. `line` counts from the
        /// oldest, which is the end a terminal trims; distance from the
        /// newest is the part two terminals agree on.
        var total: UInt32
        var text: String
        /// How far back the line sits from the newest one.
        var fromEnd: UInt32 { total > line ? total - 1 - line : 0 }
        /// Byte range of the match inside `text`.
        var matchStart: UInt32
        var matchLength: UInt32
        var before: [String]
        var after: [String]
    }

    /// Lines of history matching `query`. `scope` of nil searches every tab
    /// the daemon has; naming one searches only that pane.
    static func search(
        _ query: String, limit: UInt32 = 200, scope: (workspace: String, tab: UInt32)? = nil
    ) throws -> [Hit] {
        let sock = try connect()
        defer { close(sock) }
        var w = Writer()
        w.string(query)
        w.u32(limit)
        w.string(scope?.workspace ?? "")
        w.u32(scope?.tab ?? 0)
        try send(sock, tag: tagSearch, payload: w.data)

        let (tag, payload) = try recv(sock)
        var r = Reader(payload)
        switch tag {
        case tagSearchHits:
            let count = try r.u32()
            var hits: [Hit] = []
            hits.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                let workspace = try r.string()
                let tab = try r.u32()
                let line = try r.u32()
                let total = try r.u32()
                let text = try r.string()
                let matchStart = try r.u32()
                let matchLength = try r.u32()
                var before: [String] = []
                for _ in 0..<(try r.u32()) { before.append(try r.string()) }
                var after: [String] = []
                for _ in 0..<(try r.u32()) { after.append(try r.string()) }
                hits.append(Hit(
                    workspace: workspace, tab: tab, line: line, total: total, text: text,
                    matchStart: matchStart, matchLength: matchLength,
                    before: before, after: after))
            }
            return hits
        case tagError: throw Failure.protocolError(try r.string())
        default: throw Failure.protocolError("unexpected reply tag \(tag)")
        }
    }

    static func kill(_ name: String) throws {
        let sock = try connect()
        defer { close(sock) }
        var w = Writer()
        w.string(name)
        try send(sock, tag: tagKill, payload: w.data)

        let (tag, payload) = try recv(sock)
        if tag == tagError {
            var r = Reader(payload)
            throw Failure.protocolError(try r.string())
        }
        guard tag == tagOk else {
            throw Failure.protocolError("unexpected reply tag \(tag)")
        }
    }

    // MARK: - socket

    private static func connect() throws -> Int32 {
        let path = socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.cannotConnect(path) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw Failure.cannotConnect(path)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, size)
            }
        }
        guard ok == 0 else {
            close(fd)
            throw Failure.cannotConnect(path)
        }
        return fd
    }

    private static func send(_ fd: Int32, tag: UInt8, payload: Data) throws {
        var frame = Data([tag])
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Array($0) })
        frame.append(payload)
        try frame.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                guard n > 0 else { throw Failure.protocolError("short write") }
                sent += n
            }
        }
    }

    private static func recv(_ fd: Int32) throws -> (UInt8, Data) {
        let head = try readExactly(fd, 5)
        let tag = head[0]
        let len = head.subdata(in: 1..<5).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        guard len <= 16 * 1024 * 1024 else { throw Failure.protocolError("frame too large") }
        let payload = len == 0 ? Data() : try readExactly(fd, Int(len))
        return (tag, payload)
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data(capacity: count)
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = read(fd, &buf[got], count - got)
            guard n > 0 else { throw Failure.protocolError("truncated frame") }
            got += n
        }
        out.append(contentsOf: buf)
        return out
    }

    /// The two layouts differ only by two fields at the tail of each tab, so
    /// they are read by one function: tab records sit back to back with no
    /// length of their own, and a decoder that reads the wrong number of them
    /// finds the next tab's id inside the middle of this one.
    private static func decodeWorkspaces(
        _ payload: Data, withCwd: Bool
    ) throws -> [Workspace] {
        var r = Reader(payload)
        let count = try r.u32()
        var out: [Workspace] = []
        out.reserveCapacity(Int(min(count, 4096)))
        for _ in 0..<count {
            let name = try r.string()
            let tabCount = try r.u32()
            var tabs: [Tab] = []
            tabs.reserveCapacity(Int(min(tabCount, 4096)))
            for _ in 0..<tabCount {
                var tab = Tab(
                    id: try r.u32(),
                    cols: try r.u16(),
                    rows: try r.u16(),
                    clients: try r.u32(),
                    finished: try r.u8() != 0,
                    title: try r.string(),
                    busy: try r.u8() != 0,
                    splitOf: try r.u32(),
                    splitDir: try r.u8()
                )
                if withCwd {
                    tab.cwd = try r.string()
                    let stamp = try r.u64()
                    // Zero is the daemon saying it does not know, which is not
                    // the same as 1970.
                    tab.lastActive = stamp == 0
                        ? nil : Date(timeIntervalSince1970: Double(stamp) / 1000)
                    tab.command = try r.string()
                }
                tabs.append(tab)
            }
            out.append(Workspace(name: name, tabs: tabs))
        }
        return out
    }
}

// MARK: - wire helpers

private struct Writer {
    var data = Data()
    mutating func u8(_ v: UInt8) {
        data.append(v)
    }
    mutating func u16(_ v: UInt16) {
        data.append(contentsOf: withUnsafeBytes(of: v.bigEndian) { Array($0) })
    }
    mutating func u32(_ v: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: v.bigEndian) { Array($0) })
    }
    mutating func string(_ s: String) {
        let bytes = Array(s.utf8)
        u32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }
}

private struct Reader {
    private let data: Data
    private var pos: Int
    init(_ data: Data) {
        self.data = data
        self.pos = data.startIndex
    }
    private mutating func take(_ n: Int) throws -> Data {
        guard pos + n <= data.endIndex else { throw Daemon.Failure.protocolError("truncated") }
        defer { pos += n }
        return data.subdata(in: pos..<(pos + n))
    }
    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 {
        try take(2).withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) }
    }
    mutating func u32() throws -> UInt32 {
        try take(4).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
    }
    mutating func u64() throws -> UInt64 {
        try take(8).withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
    mutating func string() throws -> String {
        let n = Int(try u32())
        guard let s = String(data: try take(n), encoding: .utf8) else {
            throw Daemon.Failure.protocolError("invalid utf-8")
        }
        return s
    }
}
