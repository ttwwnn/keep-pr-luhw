import Foundation
import CryptoKit
import Darwin

/// State replacements retain their previous bytes. A failed backup or an
/// unreadable source cancels the write; recovery copies are never pruned.
enum KeepStateFile {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var productionDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Keep", isDirectory: true)
    }

    static func validateConnection(socket: String, directory: URL) throws {
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 0 else { throw Failure(message: "Could not identify the main Keep state.") }
        var buffer = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, count) > 0 else {
            throw Failure(message: "Could not identify the main Keep socket.")
        }
        let expected = URL(fileURLWithPath: String(cString: buffer))
            .appendingPathComponent("keep-\(NSUserName()).sock").resolvingSymlinksInPath().path
        let actual = URL(fileURLWithPath: socket).resolvingSymlinksInPath().path
        let state = directory.resolvingSymlinksInPath().path
        let real = productionDirectory.resolvingSymlinksInPath().path
        if actual != expected && (state == real || state.hasPrefix(real + "/")) {
            throw Failure(message: "Alternate connection refused: set KEEP_STATE_DIR outside the main Keep state. Your data was preserved.")
        }
    }

    private static func recovery(_ file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent(file.lastPathComponent, isDirectory: true)
    }

    private static func archive(_ data: Data, from file: URL) throws {
        let folder = recovery(file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let copy = folder.appendingPathComponent(digest + ".json")
        if FileManager.default.fileExists(atPath: copy.path) {
            guard try Data(contentsOf: copy) == data else { throw Failure(message: "Invalid recovery copy.") }
        } else {
            try data.write(to: copy, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            let handle = try FileHandle(forWritingTo: copy)
            defer { try? handle.close() }
            try handle.synchronize()
        }
        // A repeated state is the most recent usable recovery too.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)
        try synchronize(folder)
        try synchronize(folder.deletingLastPathComponent())
        try synchronize(file.deletingLastPathComponent())
    }

    static func read(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        let copies = (try? FileManager.default.contentsOfDirectory(
            at: recovery(file), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for copy in copies.sorted(by: { (FileStamp(of: $0).modified ?? .distantPast)
            > (FileStamp(of: $1).modified ?? .distantPast) }) {
            guard let saved = try? Data(contentsOf: copy),
                  (try? JSONSerialization.jsonObject(with: saved)) != nil else { continue }
            do {
                try replace(saved, at: file, recovering: true, expected: data)
                return saved
            } catch { report(error, file: file); return nil }
        }
        return nil
    }

    @discardableResult
    static func write<T: Encodable>(_ value: T, to file: URL,
                                    namesExcept: Set<String>? = nil, workspace: String? = nil) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try replace(encoder.encode(value), at: file, namesExcept: namesExcept, workspace: workspace)
            return true
        } catch { report(error, file: file); return false }
    }

    private static func replace(_ proposed: Data, at file: URL, recovering: Bool = false,
                                namesExcept: Set<String>? = nil, workspace: String? = nil,
                                expected: Data? = nil) throws {
        let folder = file.deletingLastPathComponent()
        try validateConnection(socket: Daemon.socketPath, directory: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = open(folder.appendingPathComponent(".state.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure(message: "Could not lock the state for writing.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Failure(message: "State in use; write cancelled.") }
        var data = proposed
        if FileManager.default.fileExists(atPath: file.path) {
            let old = try Data(contentsOf: file)
            if let expected, expected != old {
                throw Failure(message: "State changed by another process; recovery deferred.")
            }
            if !recovering && (try? JSONSerialization.jsonObject(with: old)) == nil {
                throw Failure(message: "Invalid state preserved; writes require recovery first.")
            }
            if let touched = namesExcept,
               let before = try? JSONSerialization.jsonObject(with: old) as? [String: Any],
               var after = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let was = before["daemonStart"] as? Double, let now = after["daemonStart"] as? Double,
               abs(was - now) < 0.001 {
                var tabs = after["tabs"] as? [String: String] ?? [:]
                let fresh = before["tabs"] as? [String: String] ?? [:]
                for key in Set(tabs.keys).union(fresh.keys) where !touched.contains(key) { tabs[key] = fresh[key] }
                var spaces = after["workspaces"] as? [String: String] ?? [:]
                let freshSpaces = before["workspaces"] as? [String: String] ?? [:]
                for key in Set(spaces.keys).union(freshSpaces.keys) where key != workspace { spaces[key] = freshSpaces[key] }
                after["tabs"] = tabs
                after["workspaces"] = spaces
                data = try JSONSerialization.data(withJSONObject: after, options: [.sortedKeys])
            }
            if old != data { try archive(old, from: file) }
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronize(folder)
    }

    private static func synchronize(_ folder: URL) throws {
        let descriptor = open(folder.path, O_RDONLY)
        guard descriptor >= 0 else { throw Failure(message: "Recovery directory is inaccessible.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure(message: "Recovery copy could not be synchronized to disk.") }
    }

    private static func report(_ error: Error, file: URL) {
        NSLog("Keep: %@ preserved: %@", file.lastPathComponent, error.localizedDescription)
    }
}

/// Where this app keeps what it remembers between launches.
///
/// `KEEP_STATE_DIR` first, so a test can be handed a directory of its own.
/// Without it a test either writes into the state of whoever is running it —
/// `tools/tabs-test.sh` used to scrub its own leftovers out of the real file
/// afterwards — or reads their arrangement and reports on it as though it were
/// its own setup.
func stateDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["KEEP_STATE_DIR"],
       !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    // Named after this build, not after "Keep". A second build under another
    // name — the one the tests drive, so that somebody can go on working in
    // theirs — must not read or rearrange the furniture of the app they are
    // using.
    let app = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Keep"
    return FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent(app, isDirectory: true)
}

/// Each window's sidebar, across app restarts.
///
/// App-side only — the daemon stores no UI state. One small JSON file:
/// sidebar-state.json, keyed by window slot.
///
/// One value per window, not one per tab and not one for the app. Per tab was
/// tried and read as a glitch: you collapse it, move to another tab, and it
/// is back. But a window is not a tab, and one value for the app reproduces
/// that same glitch across windows — collapse it in the narrow one and the
/// wide one you did not touch rearranges itself. The rule is what it always
/// was, with a word added: furniture stays where you put it, in the room you
/// put it in.
///
/// Writes are debounced: a divider drag reports continuously and none of it
/// is worth an fsync per event. `flush` settles the debt at quit.
@MainActor
final class SidebarStateStore {
    private var states: [Int: SidebarState]
    private let file: URL
    private var writeScheduled = false

    init(directory: URL? = nil) {
        let dir = directory ?? stateDirectory()
        file = dir.appendingPathComponent("sidebar-state.json")
        let data = KeepStateFile.read(file) ?? Data()
        if let keyed = try? JSONDecoder().decode([Int: SidebarState].self, from: data) {
            states = keyed
        } else if let bare = try? JSONDecoder().decode(SidebarState.self, from: data) {
            // What every earlier version wrote. Whoever had one sidebar keeps
            // it, and it becomes what a second window starts from.
            states = [WindowID.first.slot: bare]
        } else {
            states = [:]
        }
    }

    /// A window nobody has arranged yet inherits the first window's, and the
    /// factory setting if there is no first window either — so a new window
    /// opens looking like the one it was opened from.
    func state(for window: WindowID) -> SidebarState {
        states[window.slot] ?? states[WindowID.first.slot] ?? .initial
    }

    func save(_ newState: SidebarState, for window: WindowID) {
        guard states[window.slot] != newState else { return }
        states[window.slot] = newState
        scheduleWrite()
    }

    /// Write now, debounce or not.
    func flush() {
        writeScheduled = false
        write()
    }

    private func write() {
        KeepStateFile.write(states, to: file)
    }

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.writeScheduled else { return }
            self.writeScheduled = false
            self.write()
        }
    }
}

/// The order the tabs of each workspace are listed in.
///
/// App-side, like the sidebar's own state, because this is a preference about
/// looking rather than a fact about what is running: the daemon knows which
/// numbers — so this remembers ids, and ids are only meaningful while the
/// daemon that issued them is alive. A daemon started afresh counts from one
/// again, so an order kept for the last one would sort unrelated tabs — after
/// a reboot, the tabs put back in their old order came up shuffled by it. The
/// daemon's start is kept beside the order, as `NameStore` keeps it beside the
/// names, and a different start forgets it.
@MainActor
final class TabOrderStore {
    private(set) var order: [String: [UInt32]]
    /// When the daemon these ids belong to started, in seconds.
    private var daemonStart: Double?
    /// When a file in the earlier format, which names no daemon, was written.
    private var legacyWritten: Date?
    private let file: URL

    private struct Contents: Codable {
        var daemonStart: Double?
        var order: [String: [UInt32]]
    }

    init(directory: URL? = nil) {
        let dir = directory ?? stateDirectory()
        file = dir.appendingPathComponent("tab-order.json")
        let data = KeepStateFile.read(file) ?? Data()
        if let contents = try? JSONDecoder().decode(Contents.self, from: data) {
            order = contents.order
            daemonStart = contents.daemonStart
        } else if let bare = try? JSONDecoder().decode([String: [UInt32]].self, from: data) {
            // What earlier versions wrote, with no daemon beside it: whose ids
            // they are is told by when it was written — see `validate`.
            order = bare
            legacyWritten = FileStamp(of: file).modified
        } else {
            order = [:]
        }
    }

    /// Forget the order if it was kept under another daemon.
    func validate(daemonStart: Date?) {
        guard let start = daemonStart?.timeIntervalSince1970 else { return }
        if let known = self.daemonStart, abs(known - start) < 0.001 { return }
        if self.daemonStart != nil {
            order = [:]
        } else if let written = legacyWritten, written.timeIntervalSince1970 < start - 0.001 {
            // An order in the earlier format, written before this daemon was
            // started: another daemon's ids.
            order = [:]
        }
        legacyWritten = nil
        self.daemonStart = start
        write()
    }

    func save(_ tabs: [UInt32], in workspace: String) {
        guard order[workspace] != tabs else { return }
        order[workspace] = tabs
        write()
    }

    /// Sort ids into the remembered order, with anything unheard-of kept where
    /// the daemon had it — a tab made a moment ago appears where it was made,
    /// at the end, rather than at the front of a row somebody arranged.
    func arrange(_ ids: [UInt32], in workspace: String) -> [UInt32] {
        guard let remembered = order[workspace] else { return ids }
        let placed = remembered.filter(ids.contains)
        let rest = ids.filter { !remembered.contains($0) }
        return placed + rest
    }

    private func write() {
        KeepStateFile.write(Contents(daemonStart: daemonStart, order: order), to: file)
    }
}

/// A file as it was when last looked at, to notice that somebody else wrote it.
///
/// The inode as well as the date and the size: whoever writes it atomically
/// replaces the file, and two writes inside one tick of the clock with the
/// same length would otherwise look like none.
struct FileStamp: Equatable {
    let inode: UInt64?
    let modified: Date?
    let size: UInt64?

    init(of url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        modified = attributes?[.modificationDate] as? Date
        size = (attributes?[.size] as? NSNumber)?.uint64Value
    }
}

/// The workspaces somebody took out of sight.
///
/// Removed from the last window that showed them, or left behind by a window
/// that closed: running, a ⌘P away, and in no sidebar — which is how they were
/// left, and how they stay across a relaunch and across a reboot, when the
/// tabs in them are put back. Every other running workspace is shown
/// somewhere. Kept by name, which outlives a daemon.
///
/// With the start of the last daemon each one was seen running under. One
/// that did not run at all under a daemon is forgotten when the next starts:
/// it is not coming back, and a workspace made later under its name is a new
/// one, which must not be born out of sight.
@MainActor
final class PutAwayStore {
    private struct Contents: Codable {
        /// The daemon this was last checked against, in seconds.
        var daemonStart: Double?
        /// Name → start of the last daemon it was seen running under; 0 for
        /// not known.
        var names: [String: Double] = [:]
    }

    private var contents: Contents
    private let file: URL

    init(directory: URL? = nil) {
        let dir = directory ?? stateDirectory()
        file = dir.appendingPathComponent("put-away.json")
        let data = KeepStateFile.read(file) ?? Data()
        if let decoded = try? JSONDecoder().decode(Contents.self, from: data) {
            contents = decoded
        } else if let bare = try? JSONDecoder().decode([String].self, from: data) {
            // An earlier build's plain list: kept, as though seen under an
            // unknown daemon.
            contents = Contents(daemonStart: nil, names: Dictionary(uniqueKeysWithValues: bare.map { ($0, 0) }))
        } else {
            contents = Contents()
        }
    }

    func contains(_ name: String) -> Bool { contents.names[name] != nil }

    func insert(_ name: String) {
        guard contents.names[name] == nil else { return }
        contents.names[name] = contents.daemonStart ?? 0
        write()
    }

    func remove(_ name: String) {
        guard contents.names.removeValue(forKey: name) != nil else { return }
        write()
    }

    /// Nothing a window carries is put away.
    func remove(_ shown: [String]) {
        let before = contents.names.count
        for name in shown { contents.names.removeValue(forKey: name) }
        if contents.names.count != before { write() }
    }

    /// The put-away workspaces that are running now were seen under this daemon.
    func noteRunning(_ running: Set<String>) {
        guard let start = contents.daemonStart else { return }
        var changed = false
        for (name, seen) in contents.names where running.contains(name) && abs(seen - start) >= 0.001 {
            contents.names[name] = start
            changed = true
        }
        if changed { write() }
    }

    /// A new daemon: forget what did not run at all under the last one.
    func validate(daemonStart: Date?) {
        guard let start = daemonStart?.timeIntervalSince1970 else { return }
        if let known = contents.daemonStart, abs(known - start) < 0.001 { return }
        if let previous = contents.daemonStart {
            contents.names = contents.names.filter { $0.value >= previous - 0.001 }
        }
        contents.daemonStart = start
        write()
    }

    private func write() {
        KeepStateFile.write(contents, to: file)
    }
}

/// The names people gave tabs and workspaces, over the ones they came with.
///
/// App-side, for the same reason the tab order is: the daemon addresses a tab
/// by number and a workspace by the name every shell and the CLI find it by,
/// and neither is a label anybody chose. What is kept here is only how they
/// are shown.
///
/// Tab names are keyed by id, and ids belong to the daemon that issued them —
/// a daemon started afresh counts from one again, and a name left on "tab 1"
/// would land on some unrelated shell. So the daemon's start is kept beside
/// them, and a different start forgets them. Workspace names are keyed by
/// the workspace's own name, which outlives a daemon, and stay.
@MainActor
final class NameStore {
    private struct Contents: Codable, Equatable {
        /// When the daemon these tab ids belong to started, in seconds.
        var daemonStart: Double?
        /// "workspace␟root" → name.
        var tabs: [String: String] = [:]
        var workspaces: [String: String] = [:]

        init() {}

        // Tolerant: a field missing from an older or damaged file is an empty
        // one, not a reason to lose the rest.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            daemonStart = try c.decodeIfPresent(Double.self, forKey: .daemonStart)
            tabs = try c.decodeIfPresent([String: String].self, forKey: .tabs) ?? [:]
            workspaces = try c.decodeIfPresent([String: String].self, forKey: .workspaces) ?? [:]
        }
    }

    private var contents: Contents
    private let file: URL
    /// The file as this store last read or wrote it.
    private var stamp: FileStamp

    init(directory: URL? = nil) {
        let dir = directory ?? stateDirectory()
        file = dir.appendingPathComponent("names.json")
        stamp = FileStamp(of: file)
        contents = KeepStateFile.read(file).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }
            ?? Contents()
    }

    /// Read the file again if somebody else wrote it since. True if a name
    /// changed.
    ///
    /// Somebody else is the script that puts tabs back after a reboot: it can
    /// give them the names they had before only here, and only after this
    /// app has started the daemon those tabs live in.
    ///
    /// A file written for another daemon is refused whole, and what this app
    /// holds is written back over it: its ids are not this daemon's tabs, and
    /// taking it — then forgetting it, as launch forgets names kept for
    /// another daemon — would lose every name given here.
    func reloadIfChanged(daemonStart: Date?) -> Bool {
        let now = FileStamp(of: file)
        guard now != stamp else { return false }
        stamp = now
        guard let data = KeepStateFile.read(file),
              let fresh = try? JSONDecoder().decode(Contents.self, from: data)
        else { return false }
        if let theirs = fresh.daemonStart, let start = daemonStart?.timeIntervalSince1970,
           abs(theirs - start) >= 0.001 {
            write()
            return false
        }
        let before = contents
        contents = fresh
        validate(daemonStart: daemonStart)
        return contents != before
    }

    private static func key(_ id: TabID) -> String { "\(id.workspace)\u{1F}\(id.root)" }

    func tab(_ id: TabID) -> String? { contents.tabs[Self.key(id)] }
    func workspace(_ name: String) -> String? { contents.workspaces[name] }

    /// Forget the tab names if they were given under another daemon.
    func validate(daemonStart: Date?) {
        guard let start = daemonStart?.timeIntervalSince1970 else { return }
        // Within a millisecond rather than to the bit: another program writing
        // this file reads the same start off the socket, through other code.
        if let known = contents.daemonStart, abs(known - start) < 0.001 { return }
        if contents.daemonStart != nil { contents.tabs = [:] }
        contents.daemonStart = start
        write()
    }

    /// nil or empty gives the tab its program's title back.
    func setTab(_ id: TabID, to name: String?) {
        let key = Self.key(id)
        guard contents.tabs[key] != name else { return }
        contents.tabs[key] = name
        write(touching: [key])
    }

    func setWorkspace(_ workspace: String, to name: String?) {
        guard contents.workspaces[workspace] != name else { return }
        contents.workspaces[workspace] = name
        write(touchingWorkspace: workspace)
    }

    /// A tab's id changed under it — moved to another workspace, or its root
    /// pane closed and another stood in — and its name goes with it.
    func moveTab(from old: TabID, to new: TabID) {
        guard old != new, let name = contents.tabs.removeValue(forKey: Self.key(old)) else { return }
        contents.tabs[Self.key(new)] = name
        write(touching: [Self.key(old), Self.key(new)])
    }

    /// `touching`: the names this write changes, which win over the file's.
    private func write(touching: Set<String> = [], touchingWorkspace: String? = nil) {
        absorb(except: touching, workspace: touchingWorkspace)
        guard KeepStateFile.write(contents, to: file, namesExcept: touching, workspace: touchingWorkspace) else { return }
        if let saved = KeepStateFile.read(file), let merged = try? JSONDecoder().decode(Contents.self, from: saved) {
            contents = merged
        }
        stamp = FileStamp(of: file)
    }

    /// Names somebody else added to the file since this store last read or
    /// wrote it — the script that names the tabs it put back, in the two
    /// seconds before the next poll reads it — taken in before writing over
    /// them. Additions only, and only when the file is this daemon's: a name
    /// this store holds, or is changing now, is the one that stands.
    private func absorb(except touching: Set<String>, workspace: String?) {
        guard FileStamp(of: file) != stamp,
              let data = try? Data(contentsOf: file),
              let theirs = try? JSONDecoder().decode(Contents.self, from: data),
              let mine = contents.daemonStart, let their = theirs.daemonStart,
              abs(mine - their) < 0.001
        else { return }
        for (key, name) in theirs.tabs where contents.tabs[key] == nil && !touching.contains(key) {
            contents.tabs[key] = name
        }
        for (key, name) in theirs.workspaces where contents.workspaces[key] == nil && key != workspace {
            contents.workspaces[key] = name
        }
    }
}

/// One window, as it was when the app last looked.
///
/// The frame is four numbers rather than an `NSRect` because this is the
/// model layer and because JSON has no rectangles. Screens change between
/// launches — a laptop comes back without its monitor — so a restored frame
/// is a request, not a promise; `MainWindowController` puts it back on a
/// screen that exists.
struct WindowRecord: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// The workspaces this window carried, in its sidebar's order — with the
    /// places of those the daemon lost and is getting back.
    var workspaces: [String]
    /// The ones its sidebar was actually showing. For whoever checks from
    /// outside that the tabs put back after a reboot are in sight; absent in
    /// a file written by an earlier version.
    var showing: [String]?
    var tab: TabID?
}

/// Which windows were open, and what each was pointed at.
///
/// The app turns restoration off (`isRestorable = false`) and does this
/// itself, because the two things a tiling window manager reacts to are how
/// many windows there are and where they are — and those have to be ours to
/// decide, in one turn of the run loop, rather than AppKit's to reopen at
/// whatever moment suits it.
///
/// Written when a window closes, when the app is asked to quit, and a moment
/// after what a window carries or shows changes — not on every drag. Only at
/// the first two, once, and a crash or a power cut lost the arrangement; after
/// a reboot that meant workspaces put back by a script landed in no window's
/// list and out of sight. The frames are still read live whenever it is
/// written, so there is no second copy to keep in step.
@MainActor
final class WindowStateStore {
    private(set) var records: [Int: WindowRecord]
    private let file: URL

    init(directory: URL? = nil) {
        let dir = directory ?? stateDirectory()
        file = dir.appendingPathComponent("windows.json")
        records = KeepStateFile.read(file).flatMap {
            try? JSONDecoder().decode([Int: WindowRecord].self, from: $0)
        } ?? [:]
    }

    /// The slots to open, lowest first. Slot 0 is always among them: the app
    /// has a window whatever the file says, and an empty file is what a first
    /// run and a clean quit both look like.
    var slots: [WindowID] {
        let known = Set(records.keys).union([WindowID.first.slot])
        return known.sorted().map { WindowID(slot: $0) }
    }

    func record(for window: WindowID) -> WindowRecord? { records[window.slot] }

    /// Replace the lot. Windows that are gone are gone: this is called with
    /// everything that is open, so anything missing from it was closed.
    ///
    /// Written at least once under each daemon, even with nothing changed: a
    /// reboot that brings back the same arrangement changes nothing here, and
    /// whoever checks the windows after one can only trust a file written
    /// since the daemon started.
    func save(_ newRecords: [Int: WindowRecord]) {
        let written = FileStamp(of: file).modified ?? .distantPast
        let stale = written < (Daemon.startedAt ?? .distantPast)
        guard records != newRecords || stale else { return }
        records = newRecords
        write()
    }

    private func write() {
        KeepStateFile.write(records, to: file)
    }
}
