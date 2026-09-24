import Foundation

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
        let data = (try? Data(contentsOf: file)) ?? Data()
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
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(states).write(to: file, options: .atomic)
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

/// The order the workspaces are listed in.
///
/// App-side, like the sidebar's own state, because this is a preference about
/// looking rather than a fact about what is running: the daemon knows which
/// numbers — so this remembers ids, and ids are only meaningful while the
/// daemon that issued them is alive. A daemon restarted hands out fresh ones
/// and the remembered order quietly stops applying, which is the right way
/// for it to fail.
@MainActor
final class TabOrderStore {
    private(set) var order: [String: [UInt32]]
    private let file: URL

    init(directory: URL? = nil) {
        let dir = directory ?? stateDirectory()
        file = dir.appendingPathComponent("tab-order.json")
        order = (try? JSONDecoder().decode(
            [String: [UInt32]].self, from: Data(contentsOf: file)
        )) ?? [:]
    }

    func save(_ tabs: [UInt32], in workspace: String) {
        guard order[workspace] != tabs else { return }
        order[workspace] = tabs
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(order).write(to: file, options: .atomic)
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
    private struct Contents: Codable {
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

    init(directory: URL? = nil) {
        let dir = directory ?? stateDirectory()
        file = dir.appendingPathComponent("names.json")
        contents = (try? JSONDecoder().decode(Contents.self, from: Data(contentsOf: file)))
            ?? Contents()
    }

    private static func key(_ id: TabID) -> String { "\(id.workspace)\u{1F}\(id.root)" }

    func tab(_ id: TabID) -> String? { contents.tabs[Self.key(id)] }
    func workspace(_ name: String) -> String? { contents.workspaces[name] }

    /// Forget the tab names if they were given under another daemon.
    func validate(daemonStart: Date?) {
        guard let start = daemonStart?.timeIntervalSince1970 else { return }
        guard contents.daemonStart != start else { return }
        if contents.daemonStart != nil { contents.tabs = [:] }
        contents.daemonStart = start
        write()
    }

    /// nil or empty gives the tab its program's title back.
    func setTab(_ id: TabID, to name: String?) {
        let key = Self.key(id)
        guard contents.tabs[key] != name else { return }
        contents.tabs[key] = name
        write()
    }

    func setWorkspace(_ workspace: String, to name: String?) {
        guard contents.workspaces[workspace] != name else { return }
        contents.workspaces[workspace] = name
        write()
    }

    /// A tab's id changed under it — moved to another workspace, or its root
    /// pane closed and another stood in — and its name goes with it.
    func moveTab(from old: TabID, to new: TabID) {
        guard old != new, let name = contents.tabs.removeValue(forKey: Self.key(old)) else { return }
        contents.tabs[Self.key(new)] = name
        write()
    }

    private func write() {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: file, options: .atomic)
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
    /// The workspaces this window carried, in its sidebar's order.
    var workspaces: [String]
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
/// Written when a window closes and when the app is asked to quit, rather
/// than continuously: those are the two moments the set of windows actually
/// changes, and reading the frames live at each of them is simpler than
/// keeping a copy in step with every drag. A crash loses the arrangement,
/// which is the honest trade — nothing here is work, only furniture.
@MainActor
final class WindowStateStore {
    private(set) var records: [Int: WindowRecord]
    private let file: URL

    init(directory: URL? = nil) {
        let dir = directory ?? stateDirectory()
        file = dir.appendingPathComponent("windows.json")
        records = (try? JSONDecoder().decode(
            [Int: WindowRecord].self, from: Data(contentsOf: file)
        )) ?? [:]
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
    func save(_ newRecords: [Int: WindowRecord]) {
        guard records != newRecords else { return }
        records = newRecords
        write()
    }

    private func write() {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: file, options: .atomic)
    }
}
