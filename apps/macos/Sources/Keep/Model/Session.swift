import Foundation

/// What the UI implements: it receives immutable snapshots and shows errors.
/// It never reaches back into the model except by dispatching intents.
@MainActor
protocol SessionRendering: AnyObject {
    func render(_ snapshot: SessionSnapshot)
    func present(error: String)
    /// Put the keyboard back in the active tab's focused pane.
    ///
    /// Asking to enter a workspace you are already in changes no state, so
    /// the snapshot is identical and nothing renders — but the click that
    /// asked has just left the keyboard in the sidebar. The request is real
    /// even when the answer to it is "you are already there".
    func focusActiveTerminal()
    /// Ask before ending something, on this window; `then` runs only on yes.
    /// A no puts the keyboard back where it was.
    func confirm(_ question: Confirmation, then: @escaping () -> Void)
}

/// A question worth a yes before work ends: closing a tab, a pane or a
/// workspace ends the programs in it, and there is no undo for that.
struct Confirmation {
    let title: String
    let detail: String
    let action: String
}

/// Layer 5's root, and the single writer of all selection state.
///
/// Which workspace is active, which tab, which pane has focus, what a tab's
/// sidebar looks like — every one of those facts has exactly one copy, here,
/// and changes only inside `dispatch`. The UI learns them by being handed a
/// snapshot. That is the whole cure for the era when the same facts lived in
/// a Store, a WindowManager and N per-window sidebars, and disagreed.
@MainActor
final class Session {
    /// Every workspace the daemon has. Shared: what exists is one fact.
    private var workspaces: [WorkspaceEntity] = []
    private let sidebarStore = SidebarStateStore()
    private let tabOrderStore = TabOrderStore()
    private let nameStore = NameStore()
    /// Claude Code's permission mode in each tab that runs it, as last read
    /// off its screen. Absent: manual, not Claude Code, or not read yet.
    private var claudeModes: [TabID: ClaudeMode] = [:]
    /// Where Claude Code's turn stands in each tab that runs it, as last read
    /// off its screen. Absent: not Claude Code, or not read yet.
    private var claudeActivities: [TabID: ClaudeActivity] = [:]

    /// What each window is pointed at, and who to hand its snapshot to.
    ///
    /// Keyed rather than singular, and still written only here. `windowOrder`
    /// is creation order, so "the first window" is a real thing — it is where
    /// something with nowhere else to go lands.
    private var views: [WindowID: WindowView] = [:]
    private var renderers: [WindowID: WeakRenderer] = [:]
    private var lastSnapshots: [WindowID: SessionSnapshot] = [:]
    private var windowOrder: [WindowID] = []

    /// What each window carries, in its order, together with the workspaces
    /// it carried that are not running right now because the daemon holding
    /// them went away — a reboot, a crash. Written down with the window (see
    /// `placement`), so a workspace that comes back lands in the window, and
    /// at the place in it, where it was, even if the app went down too while
    /// the tabs were being put back.
    private var remembered: [WindowID: [String]] = [:]
    /// The workspaces somebody took out of sight — removed from the last
    /// window showing them, or left behind by a window that closed — which
    /// stay out of every sidebar, running and a ⌘P away, until somebody goes
    /// to one. Every other running workspace is in some window: see
    /// `placeOrphans`.
    private let putAwayStore = PutAwayStore()
    /// The daemon the stored tab names and tab order were last checked
    /// against. Tab ids are the daemon's, and a daemon started afresh counts
    /// from one again.
    private var daemonStart: Date?
    /// Moved on each time an intent changes the daemon and lists it again. A
    /// poll that set out before that carries a listing from before it, and
    /// applying it would put back what was just closed, or take away from a
    /// window what was just made in it.
    private(set) var generation = 0
    /// Set when the app is quitting: the windows closing on the way out put
    /// nothing away.
    private var quitting = false
    /// Told when what a window carries or shows has changed, so it can be
    /// written down within a moment rather than only when a window closes or
    /// the app quits — a crash or a power cut used to take the arrangement.
    var onArrangementChange: (() -> Void)?
    private var lastArrangement: [Arrangement] = []

    private struct Arrangement: Equatable {
        let window: WindowID
        let workspaces: [String]
        let showing: [String]
        let tab: TabID?
    }

    /// The quick terminal's workspace. It is the panel's, not a window's:
    /// the panel keeps it out of the windows so that its size and the tab it
    /// shows are its own, and nothing here puts it in a sidebar.
    static let quickWorkspace = "quick"

    /// Tabs in the order they were last entered, newest first. The daemon
    /// records no such thing — and it should not, since this is about where
    /// *you* have been, not about the work. Shared: where you have been is
    /// one history, whichever window you were in.
    private var recentTabs: [TabID] = []
    private var destinations: [String] = []

    private struct WeakRenderer {
        weak var value: SessionRendering?
    }

    // MARK: - the windows

    /// A window is now showing. `carrying` is the list it starts with — empty
    /// for one somebody just opened, and everything there is for the first,
    /// which would otherwise come up blank in front of a person whose
    /// workspaces all still exist.
    func addWindow(_ id: WindowID, renderer: SessionRendering, carrying: [String]) {
        renderers[id] = WeakRenderer(value: renderer)
        // Pruned to what is running, as the first window's list is: a name
        // listed but not running is waiting for its workspace — kept in
        // `remembered` — and a window listing it would count as having it the
        // moment it came back, leaving every other window that had it without.
        let live = Set(workspaces.map(\.name))
        if views[id] == nil { views[id] = WindowView(workspaces: carrying.filter(live.contains)) }
        if !carrying.isEmpty { remembered[id] = carrying }
        if !windowOrder.contains(id) { windowOrder.append(id) }
        publish()
    }

    /// What this window is carrying and showing, for whoever writes it down —
    /// with the workspaces it carried that are not running now, in their
    /// places, so that a crash before they come back does not forget them.
    /// Read-only: `Session` remains the only writer of a `WindowView`.
    func placement(of id: WindowID) -> (workspaces: [String], showing: [String], tab: TabID?)? {
        guard let view = views[id] else { return nil }
        return (arrangement(of: id), view.workspaces, view.tab)
    }

    func removeWindow(_ id: WindowID) {
        // A window closed while others stay open leaves what only it carried
        // put away, running and a ⌘P away — not pushed into another window.
        // The last window closing is the app quitting, and puts nothing away.
        if !quitting, windowOrder.count > 1, let view = views[id] {
            let elsewhere = Set(views.filter { $0.key != id }.flatMap(\.value.workspaces))
            for name in view.workspaces where !elsewhere.contains(name) {
                putAwayStore.insert(name)
            }
        }
        views[id] = nil
        remembered[id] = nil
        renderers[id] = nil
        lastSnapshots[id] = nil
        windowOrder.removeAll { $0 == id }
    }

    private func renderer(_ id: WindowID) -> SessionRendering? { renderers[id]?.value }

    private func workspace(for window: WindowID) -> WorkspaceEntity? {
        guard let name = views[window]?.workspace else { return nil }
        return workspaces.first { $0.name == name }
    }

    /// The tab this window is showing.
    private func shownTab(in window: WindowID) -> TabEntity? {
        guard let id = views[window]?.tab else { return nil }
        return workspaces.first { $0.name == id.workspace }?
            .tabs.first { $0.id == id }
    }

    /// Which pane holds the keyboard in this window, falling back to the seed
    /// the tab carries — so a window showing a tab for the first time lands on
    /// the pane it was last used in rather than always on the root.
    private func focusedPane(of tab: TabEntity, in window: WindowID) -> UInt32 {
        guard let pane = views[window]?.focusedPane[tab.id], tab.owns(pane: pane)
        else { return tab.focusedPane }
        return pane
    }

    /// Put a workspace in this window's list, if it is not there already.
    private func adopt(_ name: String, into window: WindowID) {
        guard var view = views[window], !view.workspaces.contains(name) else { return }
        view.workspaces.append(name)
        views[window] = view
    }

    // MARK: - lifecycle

    /// Write anything the debounce still owes. Called on quit: a sidebar the
    /// person collapsed a moment before quitting must survive it.
    func flush() {
        sidebarStore.flush()
    }

    /// The app is quitting: what closes from here on is not being put away.
    func prepareToQuit() {
        quitting = true
    }

    /// Bring the app up. `carrying` is what the first window had last time,
    /// or nil when nothing was written down for it: a first run, or the app
    /// last closed by closing its window. Either way it ends up holding
    /// everything nobody put away — see `windowsReady`, which finishes the
    /// layout once every window of this run exists.
    func start(
        firstWindow: WindowID,
        renderer: SessionRendering,
        carrying: [String]? = nil,
        showing: TabID? = nil
    ) {
        renderers[firstWindow] = WeakRenderer(value: renderer)
        if !windowOrder.contains(firstWindow) { windowOrder.append(firstWindow) }
        if views[firstWindow] == nil { views[firstWindow] = WindowView() }
        if let carrying, !carrying.isEmpty { remembered[firstWindow] = carrying }
        do {
            try Daemon.ensureRunning()
        } catch {
            renderer.present(error: error.localizedDescription)
            return
        }
        checkDaemon()
        refreshFromDaemon()

        // Something must be on screen; a fresh daemon gets a default
        // workspace named after the user.
        if workspaces.allSatisfy({ $0.tabs.isEmpty }) {
            _ = try? Daemon.newTab(in: NSUserName())
            refreshFromDaemon()
        }
        // The first window carries what it carried, pruned to what the daemon
        // still has; the rest — everything, when nothing was written down — is
        // placed by `windowsReady`, once the other windows have taken theirs.
        let live = workspaces.map(\.name)
        views[firstWindow]?.workspaces = carrying.map { remembered in
            remembered.filter(live.contains)
        } ?? []
        // The tab it was left on, if that tab is still there. Chosen here
        // rather than switched to afterwards: a second activation would build
        // a surface, and a client, for a tab nobody asked to see.
        let carried = views[firstWindow]?.workspaces ?? []
        let remembered = showing.flatMap { id in
            carried.contains(id.workspace)
                ? workspaces.first { $0.name == id.workspace }?.tabs.first { $0.id == id }?.id
                : nil
        }
        if let remembered { activate(remembered, in: firstWindow) }
        publish()
    }

    /// Every window of this run exists and carries what it carried: give
    /// whatever is running that no window carries and nobody put away a row
    /// — made while the app was not running, the tabs a reboot took and put
    /// back while it was down, or everything, for a window that remembered
    /// nothing — and a tab to every window still showing none.
    ///
    /// After the windows, not in `start`: done with only the first window up,
    /// it took what the others were about to carry, and every relaunch put
    /// their workspaces in the first window's sidebar too.
    func windowsReady() {
        placeOrphans()
        for id in windowOrder where views[id] != nil && views[id]?.tab == nil {
            if let workspace = fallbackWorkspace(for: id) {
                activate(workspace.lastTabID ?? workspace.tabs.first?.id, in: id)
            }
        }
        publish()
    }

    /// Where a window with nothing to show goes: the first workspace it
    /// carries that has a tab; failing that, the first one running that is
    /// neither put away nor the quick terminal's.
    private func fallbackWorkspace(for window: WindowID) -> WorkspaceEntity? {
        let carried = views[window]?.workspaces ?? []
        return carried.lazy.compactMap { name in
            self.workspaces.first { $0.name == name && !$0.tabs.isEmpty }
        }.first ?? workspaces.first {
            !$0.tabs.isEmpty && $0.name != Self.quickWorkspace && !putAwayStore.contains($0.name)
        }
    }

    /// One daemon poll, delivered by the poller. Reconciliation only: it can
    /// prune and relabel, repair a dead active tab, and give a workspace that
    /// arrived with no window a row in one — it cannot mount, present, or
    /// switch to something new.
    ///
    /// `placing` is false when an intent re-lists after doing something: the
    /// workspace it made is about to be put in the window that asked, and
    /// taking it for another window first would show it in two.
    func reconcile(_ listing: [Daemon.Workspace], placing: Bool = true, asOf: Int? = nil) {
        // A poll that set out before an intent changed the daemon.
        if let asOf, asOf != generation { return }
        var changed = false
        // Somebody else may have named tabs — the script that puts tabs back
        // after a reboot gives them the names they had before. Read before
        // the daemon is checked: names written for a daemon that has just
        // started must not be forgotten as the last one's.
        if nameStore.reloadIfChanged(daemonStart: Daemon.startedAt ?? daemonStart) {
            refreshOpenLists()
            changed = true
        }
        let newDaemon = checkDaemon()
        changed = changed || newDaemon

        // Workspaces gone from the daemon take their entities with them.
        let liveNames = Set(listing.map(\.name))
        let vanished = workspaces.map(\.name).filter { !liveNames.contains($0) }
        for name in vanished {
            SurfacePool.shared.discardAll(workspace: name)
            workspaces.removeAll { $0.name == name }
            changed = true
        }
        if !vanished.isEmpty, !newDaemon {
            // Gone while the daemon stayed the same: somebody ended them.
            // Nothing to keep a place for. Gone with the daemon, they are
            // what a restore puts back, and keep their places meanwhile.
            forget(vanished)
        }

        for daemon in listing {
            let entity: WorkspaceEntity
            if let existing = workspaces.first(where: { $0.name == daemon.name }) {
                entity = existing
            } else {
                entity = WorkspaceEntity(name: daemon.name)
                entity.arrangement = { [weak self] ids in
                    self?.tabOrderStore.arrange(ids, in: daemon.name) ?? ids
                }
                workspaces.append(entity)
                changed = true
            }
            let result = entity.reconcile(with: daemon)
            changed = changed || result.changed

            // Any surface whose tab the daemon no longer has, root or pane
            // alike. Keying this off dead *roots* left a pane that died on
            // its own holding a renderer and a client process forever.
            let live = Set(daemon.liveTabs.map(\.id))
            for tab in SurfacePool.shared.tabs(in: daemon.name) where !live.contains(tab) {
                SurfacePool.shared.discard(workspace: daemon.name, tab: tab)
            }
        }
        // Nothing sorts `workspaces` any more: the order somebody arranged is
        // per window now, and it is the window's own list.
        let alive = Set(workspaces.map(\.name))
        for id in windowOrder {
            guard var view = views[id] else { continue }
            let before = view

            // A workspace the daemon no longer has leaves every list holding
            // it, and takes the window pointed at it with it.
            view.workspaces.removeAll { !alive.contains($0) }
            if let name = view.workspace, !alive.contains(name) {
                view.workspace = view.workspaces.first
                view.tab = nil
            }
            if let tab = view.tab,
               !workspaces.contains(where: { $0.name == tab.workspace
                   && $0.tabs.contains { $0.id == tab } }) {
                view.tab = workspaces.first { $0.name == view.workspace }?.tabs.first?.id
            }
            // Panes are remembered per tab; without this the map keeps one
            // entry for every tab the window ever showed, for as long as the
            // app runs.
            view.focusedPane = view.focusedPane.filter { entry in
                workspaces.contains { $0.name == entry.key.workspace
                    && $0.tabs.contains { $0.id == entry.key } }
            }
            if view != before {
                views[id] = view
                changed = true
            }
        }
        putAwayStore.noteRunning(alive)
        if placing, placeOrphans() { changed = true }

        if changed {
            let busy = workspaces.compactMap { space -> String? in
                let titles = space.tabs.flatMap(\.busyTitles)
                guard !titles.isEmpty else { return nil }
                return "\(space.name)=\(titles.joined(separator: "|"))"
            }
            Trace.log(
                "sidebar",
                "order \(workspaces.map(\.name).joined(separator: " "))"
                    + (busy.isEmpty ? "" : " busy \(busy.joined(separator: ", "))"))
            publish()
        }
    }

    /// Give every running workspace that no window carries a row in one —
    /// unless somebody put it out of sight, or it is the quick terminal's.
    ///
    /// This is what keeps a workspace from running where no sidebar shows it.
    /// The first window carries what the daemon had when the app started and
    /// a new one carries nothing, while the daemon grows workspaces the app
    /// did not make: a login script putting back the tabs a reboot took, the
    /// command-line client, anything made while the app was not running.
    /// Each lands in the window that carried it before, at its place there,
    /// or at the end of the first window, which is where something with
    /// nowhere else to go lands.
    ///
    /// Not while an intent re-lists (`placing`): the workspace an intent made
    /// is about to be put in the window that asked, and taking it for another
    /// first would show it in two.
    @discardableResult
    private func placeOrphans() -> Bool {
        var carried = Set(views.values.flatMap(\.workspaces))
        var placed = false
        let open = windowOrder.filter { views[$0] != nil }
        for workspace in workspaces where !workspace.tabs.isEmpty {
            let name = workspace.name
            guard !carried.contains(name), name != Self.quickWorkspace,
                  !putAwayStore.contains(name)
            else { continue }
            // Every window that had it — a tab torn off into a second window
            // leaves its workspace in both — or else the first.
            var homes = open.filter { remembered[$0]?.contains(name) == true }
            if homes.isEmpty, let first = open.first { homes = [first] }
            for window in homes {
                let list = views[window]?.workspaces ?? []
                views[window]?.workspaces = Self.inserting(name, into: list, by: remembered[window])
                Trace.log("window", "\(window) takes \(name), which was in no window")
            }
            if !homes.isEmpty {
                carried.insert(name)
                placed = true
            }
        }
        return placed
    }

    /// What a window carries, with what it carried and does not show right
    /// now put back where it was: workspaces the daemon lost and is getting
    /// back, and ones running that no window has taken yet. What went to
    /// another window, was put away or was ended leaves the list.
    private func arrangement(of id: WindowID) -> [String] {
        var list = views[id]?.workspaces ?? []
        // Taken by another window means shown in it: a name another window
        // lists that is not running is waiting there too, not taken — a window
        // restored at launch lists what it had before the daemon has it.
        let live = Set(workspaces.map(\.name))
        let elsewhere = Set(views.filter { $0.key != id }.flatMap(\.value.workspaces)).intersection(live)
        for name in remembered[id] ?? []
        where !list.contains(name) && !elsewhere.contains(name)
            && !putAwayStore.contains(name) && name != Self.quickWorkspace {
            list = Self.inserting(name, into: list, by: remembered[id])
        }
        return list
    }

    /// Workspaces somebody ended: no window keeps a place for them, and none
    /// is put away — one made later under the same name is a new one.
    private func forget(_ names: [String]) {
        for id in Array(remembered.keys) {
            remembered[id]?.removeAll { names.contains($0) }
        }
        for name in names { putAwayStore.remove(name) }
    }

    /// `name` put into `list` where `order` had it — just after the last
    /// workspace `order` put before it that the list holds, or first if the
    /// list holds none of those — and at the end when `order` never had it.
    static func inserting(_ name: String, into list: [String], by order: [String]?) -> [String] {
        var list = list
        guard let order, let rank = order.firstIndex(of: name) else {
            list.append(name)
            return list
        }
        let before = Set(order[..<rank])
        let at = list.lastIndex(where: { before.contains($0) }).map { $0 + 1 } ?? 0
        list.insert(name, at: at)
        return list
    }

    /// Check the stored tab names and tab order against the daemon that is
    /// running, and forget them if they were kept for another. True if the
    /// daemon is not the one they were last checked against.
    @discardableResult
    private func checkDaemon() -> Bool {
        guard let start = Daemon.startedAt else { return false }
        if let known = daemonStart, abs(known.timeIntervalSince(start)) < 0.001 { return false }
        daemonStart = start
        nameStore.validate(daemonStart: start)
        tabOrderStore.validate(daemonStart: start)
        putAwayStore.validate(daemonStart: start)
        return true
    }

    // MARK: - intents

    /// Every mutation enters here, and now says which window asked.
    ///
    /// The window rides as an envelope rather than as a case on `Intent`:
    /// what was asked and who asked it are different questions, and putting
    /// the second inside the first would have taught every view below the UI
    /// that windows exist — which is the one thing the layering forbids.
    func dispatch(_ intent: Intent, from window: WindowID) {
        Trace.log("intent", "\(window) \(intent)")
        switch intent {
        case .activateWorkspace(let name):
            guard let workspace = workspaces.first(where: { $0.name == name }) else { return }
            if workspace.tabs.isEmpty {
                // Entering an empty workspace means opening a tab in it.
                dispatch(.newTab(in: name), from: window)
            } else {
                activate(workspace.lastTabID ?? workspace.tabs.first?.id, in: window)
                publish()
                renderer(window)?.focusActiveTerminal()
            }

        case .activateTab(let id):
            activate(id, in: window)
            publish()
            renderer(window)?.focusActiveTerminal()

        case .showAnotherTab(let id):
            // Only if this window was the one showing it. Every other window
            // is entitled to go on showing that tab, and a window that was
            // already somewhere else must not be moved for somebody else's
            // gesture.
            guard views[window]?.tab == id, let tabs = workspace(for: window)?.tabs
            else { return }
            guard let at = tabs.firstIndex(where: { $0.id == id }) else { return }
            // The one after, or the one before at the end of the row — the
            // neighbour, the same one a closed tab would fall back to.
            let neighbour = at + 1 < tabs.count ? tabs[at + 1] : (at > 0 ? tabs[at - 1] : nil)
            activate(neighbour?.id, in: window)
            publish()
            renderer(window)?.focusActiveTerminal()

        case .activateTabIndex(let index):
            guard let tabs = workspace(for: window)?.tabs, !tabs.isEmpty else { return }
            let resolved = index == -1 ? tabs.count - 1 : index
            guard tabs.indices.contains(resolved) else { return }
            activate(tabs[resolved].id, in: window)
            publish()

        case .nextTab, .previousTab:
            guard let workspace = workspace(for: window), workspace.tabs.count > 1,
                  let current = workspace.tabs.firstIndex(where: { $0.id == views[window]?.tab })
            else { return }
            let step = { if case .nextTab = intent { return 1 } else { return -1 } }()
            let next = (current + step + workspace.tabs.count) % workspace.tabs.count
            activate(workspace.tabs[next].id, in: window)
            publish()

        case .nextWorkspace, .previousWorkspace:
            // In the order the sidebar shows them — this window's carried
            // list, which is the order somebody arranged — so stepping
            // through them by keyboard lands where the eye expects.
            guard let view = views[window], view.workspaces.count > 1,
                  let current = view.workspaces.firstIndex(where: { $0 == view.workspace })
            else { return }
            let step = { if case .nextWorkspace = intent { return 1 } else { return -1 } }()
            let next = (current + step + view.workspaces.count) % view.workspaces.count
            // Through the intent rather than around it: entering an empty
            // workspace has to open a tab in it, and that rule lives there.
            dispatch(.activateWorkspace(view.workspaces[next]), from: window)

        case .newTab(let name):
            // A window carrying no workspaces has nowhere to put a tab, and
            // silently doing nothing makes an empty window a dead end. Ask
            // where first — the picker is the door every workspace is behind.
            guard let name = name ?? views[window]?.workspace else {
                dispatch(.togglePicker, from: window)
                return
            }
            do {
                let id = try Daemon.newTab(in: name, cwd: directory(of: name))
                refreshFromDaemon()
                activate(TabID(workspace: name, root: id), in: window)
                publish()
            } catch {
                renderer(window)?.present(error: error.localizedDescription)
            }

        case .newWorkspace(let raw):
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            dispatch(.newTab(in: name), from: window)

        case .closeTab(let id):
            guard let id = id ?? views[window]?.tab else { return }
            renderer(window)?.confirm(Confirmation(
                title: "Close the tab “\(tabName(id))”?",
                detail: "Whatever is running in it will be ended.",
                action: "Close Tab"
            )) { [weak self] in self?.close(tab: id, from: window) }

        case .closePane(let pane):
            guard let tab = shownTab(in: window) else { return }
            let alone = tab.panes.isEmpty
            renderer(window)?.confirm(Confirmation(
                title: alone ? "Close the tab “\(tabName(tab.id))”?" : "Close this pane?",
                detail: "Whatever is running in it will be ended.",
                action: alone ? "Close Tab" : "Close Pane"
            )) { [weak self] in self?.close(pane: pane, from: window) }

        case .removeWorkspace(let name):
            guard var view = views[window], view.workspaces.contains(name) else { return }
            view.workspaces.removeAll { $0 == name }
            // Out of the last window showing it: put away, so that it stays out
            // of sight — across a relaunch and a reboot too — until somebody
            // goes to it.
            if !views.contains(where: { $0.key != window && $0.value.workspaces.contains(name) }) {
                putAwayStore.insert(name)
            }
            // Standing in the one being put away: step to a neighbour rather
            // than leaving the window pointed at something it no longer lists.
            if view.workspace == name {
                view.workspace = view.workspaces.first
                view.tab = nil
            }
            views[window] = view
            if let next = views[window]?.workspace,
               let entity = workspaces.first(where: { $0.name == next }) {
                activate(entity.lastTabID ?? entity.tabs.first?.id, in: window)
            }
            publish()

        case .killWorkspace(let name):
            renderer(window)?.confirm(Confirmation(
                title: "Close the workspace “\(nameStore.workspace(name) ?? name)”?",
                detail: "Every tab in it will be ended, in every window.",
                action: "Close Workspace"
            )) { [weak self] in self?.kill(workspace: name, from: window) }

        case .split(let direction):
            guard let workspace = workspace(for: window), let tab = shownTab(in: window) else { return }
            do {
                // Split off a pane of THIS tab or off nothing. Focus is
                // reported by views, and views are moved, rebuilt and handed
                // the responder by AppKit for reasons of its own — so the id
                // that arrives is a claim, and a claim about another tab must
                // not decide where new work is put. The root is the honest
                // fallback: it is the one pane a tab always has.
                let target = tab.owns(pane: tab.focusedPane) ? tab.focusedPane : tab.id.root
                let pane = try Daemon.newTab(
                    in: workspace.name,
                    // A pane splits off the work in front of you, so it opens
                    // where that work is rather than at home.
                    cwd: SurfacePool.shared
                        .anyExisting(workspace: workspace.name, tab: target)?
                        .currentDirectory ?? "",
                    splitOf: target,
                    splitDir: direction)
                // Re-list first: a tab only accepts focus on a pane it owns,
                // and it does not own this one until the daemon has been
                // asked again. Noting it earlier is a note that gets refused,
                // which leaves focus on the root — and then every further
                // split hangs off the root instead of off the pane you are in.
                refreshFromDaemon()
                if let tab = shownTab(in: window) {
                    tab.noteFocus(pane: pane)
                    views[window]?.focusedPane[tab.id] = pane
                }
                publish()
            } catch {
                renderer(window)?.present(error: error.localizedDescription)
            }

        case .focusPane(let tab, let pane):
            // Only the tab on screen can report focus. A hidden tab's surface
            // taking the responder is AppKit tidying up, not the person
            // moving — and acting on it would aim the next split at a pane in
            // another tab, which is where the new pane would then appear.
            guard views[window]?.tab == tab, let entity = shownTab(in: window),
                  entity.owns(pane: pane)
            else { return }
            views[window]?.focusedPane[tab] = pane
            entity.noteFocus(pane: pane)
            publish()

        case .notePaneTitle(let id, let pane, let title):
            // A tab wears its root pane's title — that is the rule the
            // daemon's listing follows too, and the two must not disagree
            // between polls. A split's other panes rename nothing.
            guard pane == id.root,
                  let workspace = workspaces.first(where: { $0.name == id.workspace }),
                  let tab = workspace.tabs.first(where: { $0.id == id }),
                  tab.noteTitle(title)
            else { return }
            refreshOpenLists()
            publish()

        case .renameTab(let id, let name):
            nameStore.setTab(id, to: Self.chosenName(name))
            refreshOpenLists()
            publish()
            // Wherever the name was typed, the keyboard goes back to the work.
            renderer(window)?.focusActiveTerminal()

        case .renameWorkspace(let workspace, let name):
            nameStore.setWorkspace(workspace, to: Self.chosenName(name))
            refreshOpenLists()
            publish()
            renderer(window)?.focusActiveTerminal()

        case .setSidebar(let state):
            sidebarStore.save(state, for: window)
            publish()

        case .moveTab(let id, let to, let before):
            let newRoot: UInt32
            do {
                newRoot = try Daemon.moveTab(id.root, from: id.workspace, to: to)
            } catch {
                renderer(window)?.present(error: error.localizedDescription)
                return
            }
            // The old filing goes with the tab: surfaces keyed by the old
            // name would otherwise hold clients on ids the daemon reissued.
            SurfacePool.shared.discard(workspace: id.workspace, tab: id.root)
            // And so does the name somebody gave it.
            nameStore.moveTab(from: id, to: TabID(workspace: to, root: newRoot))
            claudeModes[TabID(workspace: to, root: newRoot)] = claudeModes.removeValue(forKey: id)
            claudeActivities[TabID(workspace: to, root: newRoot)] = claudeActivities.removeValue(forKey: id)
            refreshFromDaemon()
            // Land where it was dropped, not where the daemon appended it.
            if let target = workspaces.first(where: { $0.name == to }) {
                var order = target.tabs.map(\.id.root).filter { $0 != newRoot }
                let at = before.flatMap { order.firstIndex(of: $0) } ?? order.count
                order.insert(newRoot, at: at)
                tabOrderStore.save(order, in: to)
                target.reorder(order)
            }
            // The window that carried it follows it; a window that was merely
            // showing it has lost it, and reconcile will hand that window a
            // neighbour the way it does when a tab dies.
            if views[window]?.tab == id {
                activate(TabID(workspace: to, root: newRoot), in: window)
            }
            publish()

        case .toggleDisclosure(let name):
            var state = sidebarStore.state(for: window)
            if state.folded.remove(name) == nil { state.folded.insert(name) }
            sidebarStore.save(state, for: window)
            publish()

        case .toggleVerticalTabs:
            var state = sidebarStore.state(for: window)
            state.verticalTabs.toggle()
            sidebarStore.save(state, for: window)
            publish()

        case .togglePicker:
            guard views[window]?.picker?.mode != .goTo else {
                dispatch(.closePicker, from: window)
                return
            }
            // Built before the assignment, not inside it. `views[window]?...`
            // begins modifying `views`, and the list now reads `views` to
            // find out where this window is — two accesses to one property at
            // once, which Swift stops dead at runtime and says nothing about
            // at build time.
            let items = Trace.time("picker", "items") { pickerItems(for: window) }
            views[window]?.picker = PickerModel(
                mode: .goTo, matches: [:], scopeLabel: nil, query: "",
                items: items, previewOf: nil, previewText: "")
            Trace.time("picker", "publish") { publish() }
            // zoxide is a process launch; the list opens on what is already
            // known and grows a moment later rather than waiting for it.
            loadDestinations(for: window)

        case .togglePalette(let catalog):
            guard views[window]?.picker?.mode != .palette(catalog) else {
                dispatch(.closePicker, from: window)
                return
            }
            let commands = Trace.time("palette", "items \(catalog)") {
                Self.paletteItems(catalog)
            }
            views[window]?.picker = PickerModel(
                mode: .palette(catalog), matches: [:], scopeLabel: nil, query: "",
                items: commands, previewOf: nil, previewText: "")
            Trace.time("palette", "publish") { publish() }

        case .toggleSearch(let global):
            let wanted = PickerModel.Mode.search(global: global)
            guard views[window]?.picker?.mode != wanted else {
                dispatch(.closePicker, from: window)
                return
            }
            let label: String
            if global {
                label = "everywhere"
            } else if let tab = shownTab(in: window) {
                let title = displayTitle(of: tab)
                label = "\(tab.id.workspace) › \(title.isEmpty ? "tab \(tab.id.root)" : title)"
            } else {
                label = "this pane"
            }
            views[window]?.picker = PickerModel(
                mode: wanted, matches: [:], scopeLabel: label, query: "",
                items: [], previewOf: nil, previewText: "")
            publish()

        case .setPickerQuery(let query):
            guard var open = views[window]?.picker else { return }
            open.query = query
            views[window]?.picker = open
            guard case .search(let global) = open.mode else { return }
            views[window]!.searchGeneration += 1
            let generation = views[window]!.searchGeneration
            guard !query.isEmpty else {
                views[window]?.picker?.items = []
                publish()
                return
            }
            // Blocking socket work, off the main thread, and only the newest
            // answer is kept: typing produces a question per keystroke and
            // they do not come back in order.
            // The pane you are in, unless the search is global.
            let scope: (workspace: String, tab: UInt32)? = global
                ? nil
                : shownTab(in: window).map { ($0.id.workspace, focusedPane(of: $0, in: window)) }
            DispatchQueue.global(qos: .userInitiated).async {
                let hits = (try? Daemon.search(query, scope: scope)) ?? []
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.views[window]?.searchGeneration == generation,
                          case .search = self.views[window]?.picker?.mode
                    else { return }
                    var items: [PickerModel.Item] = []
                    var matches: [String: PickerModel.Match] = [:]
                    for hit in hits {
                        // The daemon searches panes, and reports the pane's own
                        // id. Only a root id names a tab, so a hit inside a
                        // split has to be resolved back to the tab holding it
                        // — without this the row is inert, because activating
                        // an id that is nobody's tab does nothing.
                        let tab = self.tab(holding: hit.tab, in: hit.workspace)
                            ?? TabID(workspace: hit.workspace, root: hit.tab)
                        let item = PickerModel.Item(
                            kind: .hit(tab, pane: hit.tab, line: hit.line, fromEnd: hit.fromEnd),
                            workspace: hit.workspace,
                            context: "",
                            title: hit.text.isEmpty ? " " : hit.text,
                            detail: "\(hit.line + 1)",
                            command: "",
                            path: "",
                            busy: false,
                            lastActive: nil
                        )
                        items.append(item)
                        let start = Int(hit.matchStart)
                        matches[item.id] = PickerModel.Match(
                            range: start..<(start + Int(hit.matchLength)),
                            before: hit.before,
                            after: hit.after,
                            group: "\(hit.workspace) › tab \(hit.tab)"
                        )
                    }
                    self.views[window]?.picker?.items = items
                    self.views[window]?.picker?.matches = matches
                    self.publish()
                }
            }

        case .movePane(let pane, let target, let side):
            guard let workspace = workspace(for: window), pane != target,
                  let source = workspace.tabs.first(where: { $0.owns(pane: pane) }),
                  let destination = workspace.tabs.first(where: { $0.owns(pane: target) })
            else { return }
            // A pane's place is its parent and the direction it sits in. To
            // land on the right or below, the newcomer simply hangs off the
            // pane it was dropped on — panes are always the second half of
            // the split they make. To land on the left or above, the two
            // change roles instead: the newcomer takes the other's place and
            // the other becomes its pane. Both are the same thing said from
            // opposite ends, which is why the daemon takes them together.
            let mine = place(of: pane, in: source)
            let theirs = place(of: target, in: destination)
            var moves = vacating(pane, in: source)
            switch side {
            case .right:
                moves.append(Daemon.Move(tab: pane, splitOf: target, splitDir: 1))
            case .bottom:
                moves.append(Daemon.Move(tab: pane, splitOf: target, splitDir: 2))
            case .left:
                moves.append(
                    Daemon.Move(tab: pane, splitOf: theirs.parent, splitDir: theirs.dir))
                moves.append(Daemon.Move(tab: target, splitOf: pane, splitDir: 1))
            case .top:
                moves.append(
                    Daemon.Move(tab: pane, splitOf: theirs.parent, splitDir: theirs.dir))
                moves.append(Daemon.Move(tab: target, splitOf: pane, splitDir: 2))
            case .onto:
                moves.append(
                    Daemon.Move(tab: pane, splitOf: theirs.parent, splitDir: theirs.dir))
                moves.append(Daemon.Move(tab: target, splitOf: mine.parent, splitDir: mine.dir))
            }
            rearrange(moves, in: workspace.name, focusing: pane, for: window)

        case .detachPane(let pane):
            guard let workspace = workspace(for: window),
                  let source = workspace.tabs.first(where: { $0.owns(pane: pane) }),
                  !source.panes.isEmpty
            else { return }
            var moves = vacating(pane, in: source)
            moves.append(Daemon.Move(tab: pane, splitOf: 0, splitDir: 0))
            rearrange(moves, in: workspace.name, focusing: pane, for: window)

        case .reorderTabs(let ids, let name):
            let target = name.flatMap { n in workspaces.first { $0.name == n } }
                ?? workspace(for: window)
            guard let workspace = target, !ids.isEmpty else { return }
            tabOrderStore.save(ids, in: workspace.name)
            workspace.reorder(ids)
            publish()

        case .reorderWorkspaces(let from, let to):
            // The list this window carries is its order — there is nothing
            // else to record, and nothing for another window to disagree with.
            guard var names = views[window]?.workspaces else { return }
            names.move(fromOffsets: from, toOffset: to)
            views[window]?.workspaces = names
            publish()

        case .closePicker:
            views[window]?.picker = nil
            publish()
            renderer(window)?.focusActiveTerminal()

        case .previewPickerItem(let id):
            guard var open = views[window]?.picker else { return }
            // Already the one being shown. A list rebuilt under an unchanged
            // selection — which is what a tab renaming itself does — is not a
            // new question, and answering it again blanks the preview and
            // asks the daemon for a screen it has already handed over.
            guard open.previewOf != id else { return }
            open.previewOf = id
            open.previewText = ""
            views[window]?.picker = open
            publish()
            guard let id, let item = open.items.first(where: { $0.id == id }) else { return }
            // Not on this keystroke. Holding ↓ through a list walks a row per
            // frame, and each row asked the daemon for a screen and then laid
            // one out — work for a row nobody stopped on. A short wait spends
            // it only on the row that was actually arrived at.
            previewGeneration += 1
            let generation = previewGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.previewGeneration == generation,
                      self.views[window]?.picker?.previewOf == id
                else { return }
                switch item.kind {
                case .running(let tab):
                    self.loadPreview(of: tab, pane: tab.root, for: id, in: window)
                // The pane that matched, not the tab's root: previewing the
                // root of a split shows something the search never looked at.
                case .hit(let tab, let pane, _, _):
                    self.loadPreview(of: tab, pane: pane, for: id, in: window)
                case .destination, .command, .theme, .fontFamily: break
                }
            }

        case .choosePickerItem(let id):
            guard let item = views[window]?.picker?.items.first(where: { $0.id == id }) else { return }
            views[window]?.picker = nil
            switch item.kind {
            case .running(let tab):
                dispatch(.activateTab(tab), from: window)
            case .destination(let path):
                openWorkspace(at: path, in: window)
            case .hit(let tab, let pane, _, let fromEnd):
                // Land on the tab, then on the pane inside it, then on the
                // line. The pane is mounted by the publish above, so the
                // scroll is asked for after it, not before.
                activate(tab, in: window)
                workspaces.first { $0.name == tab.workspace }?
                    .tabs.first { $0.id == tab }?
                    .noteFocus(pane: pane)
                publish()
                renderer(window)?.focusActiveTerminal()
                Trace.log("scroll", "hit \(tab.workspace)/\(pane) back \(fromEnd)")
                SurfacePool.shared.existing(window: window, workspace: tab.workspace, tab: pane)?
                    .scrollBack(lines: Int(fromEnd))
            case .command, .theme, .fontFamily:
                // Run by the layer that can: a window is opened by AppKit and
                // a theme is worn by libghostty, and neither is anything this
                // one holds.
                break
            }

        case .dismissPickerItem(let id):
            guard let item = views[window]?.picker?.items.first(where: { $0.id == id }),
                  case .running(let tab) = item.kind
            else { return }
            renderer(window)?.confirm(Confirmation(
                title: "Close the tab “\(tabName(tab))”?",
                detail: "Whatever is running in it will be ended.",
                action: "Close Tab"
            )) { [weak self] in self?.dismiss(tab: tab, from: window) }
        }
    }

    // MARK: - ending things, once confirmed

    /// A tab's name as its row shows it, for a question about it.
    private func tabName(_ id: TabID) -> String {
        let tab = workspaces.first { $0.name == id.workspace }?.tabs.first { $0.id == id }
        let title = nameStore.tab(id) ?? tab?.title ?? ""
        return Self.plainTitle(title, fallback: "tab \(id.root)")
    }

    private func close(tab id: TabID, from window: WindowID) {
        do {
            // Close the panes first: they are daemon tabs of their own.
            let panes = workspaces.first { $0.name == id.workspace }?
                .tabs.first { $0.id == id }?.panes ?? []
            for pane in panes {
                try? Daemon.closeTab(pane.tab, in: id.workspace)
            }
            try Daemon.closeTab(id.root, in: id.workspace)
            SurfacePool.shared.discard(workspace: id.workspace, tab: id.root)
            for pane in panes {
                SurfacePool.shared.discard(workspace: id.workspace, tab: pane.tab)
            }
            refreshFromDaemon()
            publish()
        } catch {
            renderer(window)?.present(error: error.localizedDescription)
        }
    }

    private func close(pane: UInt32?, from window: WindowID) {
        // Closing the *focused* pane, which for a tab with no splits is
        // the tab itself. A root closed while panes remain is not a hole:
        // the daemon promotes an orphaned pane to stand on its own, so
        // what survives is the rest of the arrangement.
        guard let workspace = workspace(for: window), let tab = shownTab(in: window) else { return }
        let requested = pane ?? tab.focusedPane
        let target = tab.owns(pane: requested) ? requested : tab.id.root
        // Closing is idempotent on purpose. Pressing ⌘W faster than the
        // daemon is re-listed asks twice for the same pane, and the second
        // ask is not a failure worth an alert — it is the person being
        // quicker than the round trip.
        // A root closed with panes left behind: the first of them stands
        // in — the daemon's rule — and carries the tab's name on.
        if target == tab.id.root,
           let heir = tab.panes.first(where: { $0.splitOf == tab.id.root }) {
            nameStore.moveTab(from: tab.id, to: TabID(workspace: tab.id.workspace, root: heir.tab))
        }
        try? Daemon.closeTab(target, in: workspace.name)
        SurfacePool.shared.discard(workspace: workspace.name, tab: target)
        refreshFromDaemon()
        publish()
        renderer(window)?.focusActiveTerminal()
    }

    private func kill(workspace name: String, from window: WindowID) {
        do {
            try Daemon.kill(name)
        } catch {
            renderer(window)?.present(error: error.localizedDescription)
        }
        forget([name])
        SurfacePool.shared.discardAll(workspace: name)
        refreshFromDaemon()
        if workspace(for: window) == nil || workspace(for: window)?.tabs.isEmpty == true {
            views[window]?.workspace = fallbackWorkspace(for: window)?.name
            if let workspace = workspace(for: window) {
                activate(workspace.lastTabID ?? workspace.tabs.first?.id, in: window)
            }
        }
        publish()
    }

    private func dismiss(tab: TabID, from window: WindowID) {
        try? Daemon.closeTab(tab.root, in: tab.workspace)
        SurfacePool.shared.discard(workspace: tab.workspace, tab: tab.root)
        refreshFromDaemon()
        let items = pickerItems(for: window)
        views[window]?.picker?.items = items
        publish()
    }

    // MARK: - internals

    /// THE switch. Workspace clicks, strip clicks, ⌘1–9 and empty-workspace
    /// entry all funnel here; there is exactly one switch path in the program.
    /// Where a new tab in `workspace` should start: the directory of the pane
    /// you are in there, if there is one to ask.
    ///
    /// Empty when nothing can be asked — a workspace with no tab open yet, or
    /// a shell that has not reached a prompt. The daemon reads that as "your
    /// home", which is the right thing to fall back to.
    private func directory(of workspace: String) -> String {
        guard let entity = workspaces.first(where: { $0.name == workspace }),
              let tab = entity.lastTab
        else { return "" }
        let pane = tab.owns(pane: tab.focusedPane) ? tab.focusedPane : tab.id.root
        return SurfacePool.shared
            .anyExisting(workspace: workspace, tab: pane)?
            .currentDirectory ?? ""
    }

    /// The moves that let a pane leave without taking anything with it.
    ///
    /// Panes record what they were split from, so the ones hanging off the
    /// one being dragged would travel with it — the whole subtree, when what
    /// was picked up was a single pane. They stay: the first takes the
    /// departing pane's place and the others hang off it, which is what
    /// closing that pane would have done.
    private func vacating(_ pane: UInt32, in tab: TabEntity) -> [Daemon.Move] {
        let children = tab.panes.filter { $0.splitOf == pane }
        guard let heir = children.first else { return [] }
        let mine = place(of: pane, in: tab)
        var moves = [Daemon.Move(tab: heir.tab, splitOf: mine.parent, splitDir: mine.dir)]
        for other in children.dropFirst() {
            moves.append(
                Daemon.Move(tab: other.tab, splitOf: heir.tab, splitDir: other.splitDir))
        }
        return moves
    }

    /// Where a pane sits: what it hangs off and how.
    private func place(of pane: UInt32, in tab: TabEntity) -> (parent: UInt32, dir: UInt8) {
        guard let state = tab.panes.first(where: { $0.tab == pane }) else { return (0, 0) }
        return (state.splitOf, state.splitDir)
    }

    /// Ask the daemon to move panes, then believe the daemon rather than
    /// guessing what it did: the arrangement is its fact, and a rejected move
    /// must leave the app showing what is actually there.
    private func rearrange(
        _ moves: [Daemon.Move], in workspace: String, focusing pane: UInt32,
        for window: WindowID
    ) {
        do {
            try Daemon.rearrange(moves, in: workspace)
        } catch {
            renderer(window)?.present(error: error.localizedDescription)
        }
        refreshFromDaemon()
        if let entity = workspaces.first(where: { $0.name == workspace }),
           let holder = entity.tabs.first(where: { $0.owns(pane: pane) }) {
            activate(holder.id, in: window)
            holder.noteFocus(pane: pane)
        }
        publish()
        renderer(window)?.focusActiveTerminal()
    }

    /// The tab a pane belongs to, which is the only thing that can be
    /// activated: panes are addressed by the daemon, tabs by the shell.
    private func tab(holding pane: UInt32, in workspace: String) -> TabID? {
        workspaces.first { $0.name == workspace }?
            .tabs.first { $0.owns(pane: pane) }?
            .id
    }

    /// THE switch, now with an address.
    ///
    /// Workspace and tab are written together, here and nowhere else, so the
    /// two cannot come to disagree — the same invariant this enforced for the
    /// app-wide pair it replaces. Entering a workspace also puts it in the
    /// window's list: the list is the record of where this window has been.
    private func activate(_ id: TabID?, in window: WindowID) {
        guard let id, let workspace = workspaces.first(where: { $0.name == id.workspace }),
              workspace.tabs.contains(where: { $0.id == id }), views[window] != nil
        else { return }
        adopt(id.workspace, into: window)
        views[window]?.workspace = id.workspace
        views[window]?.tab = id
        workspace.remember(id)
        recentTabs.removeAll { $0 == id }
        recentTabs.insert(id, at: 0)
    }

    /// Everything running, most recently visited first, then the places to
    /// start something new.
    /// Everything running, most recently visited first, then the places to
    /// start something new — with two things settled for the window that is
    /// asking.
    ///
    /// The tab it is already showing is left out: the list is places to go,
    /// and the place you are is not one of them. And the first row is the
    /// last tab you were in **somewhere else**, so that ⌘P and return is the
    /// way back to whatever you were doing before this — the gesture ⌘-tab
    /// makes between apps, and the one this list is for. Without it the row
    /// under the cursor was the next tab of the workspace already in front of
    /// you, and the most common move of all took aiming.
    private func pickerItems(for window: WindowID) -> [PickerModel.Item] {
        var picked: [(tab: TabEntity, workspace: WorkspaceEntity)] = []
        var seen = Set<TabID>()
        let here = views[window]?.tab
        if let here { seen.insert(here) }
        func append(_ tab: TabEntity, in workspace: WorkspaceEntity) {
            guard seen.insert(tab.id).inserted else { return }
            picked.append((tab, workspace))
        }
        // Where you have been, then whatever you have not visited yet.
        for id in recentTabs {
            if let workspace = workspaces.first(where: { $0.name == id.workspace }),
               let tab = workspace.tabs.first(where: { $0.id == id }) {
                append(tab, in: workspace)
            }
        }
        // The tail, most recently active first. `recentTabs` only knows the
        // tabs this window has visited, so without this the rest arrive in
        // the order the daemon happens to list them — which at a cold launch,
        // when `recentTabs` is empty, is the whole list.
        let unvisited = workspaces
            .flatMap { workspace in workspace.tabs.map { (tab: $0, workspace: workspace) } }
            .filter { !seen.contains($0.tab.id) }
            .sorted { ($0.tab.lastActive ?? .distantPast) > ($1.tab.lastActive ?? .distantPast) }
        for entry in unvisited { append(entry.tab, in: entry.workspace) }

        // What tells one row from another, decided across the whole list
        // rather than per row: a position is only worth showing when there is
        // a sibling to be told apart from.
        var rowsPerWorkspace: [String: Int] = [:]
        for entry in picked { rowsPerWorkspace[entry.workspace.name, default: 0] += 1 }

        var running = picked.map { entry -> PickerModel.Item in
            let name = entry.workspace.name
            let alone = rowsPerWorkspace[name] == 1
            return PickerModel.Item(
                kind: .running(entry.tab.id),
                workspace: name,
                context: context(for: entry.tab, in: entry.workspace, alone: alone),
                title: Self.plainTitle(displayTitle(of: entry.tab), fallback: "tab \(entry.tab.id.root)"),
                detail: entry.tab.panes.isEmpty ? "" : "\(entry.tab.panes.count + 1) panes",
                command: Self.program(of: entry.tab),
                path: entry.tab.cwd,
                busy: entry.tab.busy,
                lastActive: entry.tab.lastActive
            )
        }
        // Two tabs of one workspace in the same directory come out with the
        // same context, which is a column that has stopped doing its job.
        // Number those, and only those.
        //
        // Counted per workspace, not across the list: two workspaces are
        // already told apart by the name the context starts with, and a
        // shared key would have a workspace literally called `proj 2`
        // colliding with the second tab of `proj` and both coming out
        // numbered again.
        func key(_ item: PickerModel.Item) -> String { "\(item.workspace)\u{0}\(item.context)" }
        var contexts: [String: Int] = [:]
        for item in running { contexts[key(item), default: 0] += 1 }
        running = running.map { item in
            guard (contexts[key(item)] ?? 0) > 1,
                  case .running(let id) = item.kind,
                  let workspace = workspaces.first(where: { $0.name == item.workspace }),
                  let position = workspace.tabs.firstIndex(where: { $0.id == id })
            else { return item }
            // The tab's own position rather than a running count, so the
            // number means the same thing it means everywhere else — ⌘1 to
            // ⌘9 — and does not change when the list is reordered under it.
            return PickerModel.Item(
                kind: item.kind,
                workspace: item.workspace,
                context: "\(item.context) \(position + 1)",
                title: item.title,
                detail: item.detail,
                command: item.command,
                path: item.path,
                busy: item.busy,
                lastActive: item.lastActive
            )
        }
        // The most recent one from another workspace, brought to the front.
        // Only moved, not filtered: the tabs of the workspace you are in are
        // still in the list, right behind it.
        if let elsewhere = running.firstIndex(where: { item in
            guard case .running(let id) = item.kind else { return false }
            return id.workspace != here?.workspace
        }) {
            // Two statements: `insert(remove(at:))` takes the array twice at
            // once, which Swift's exclusivity check stops at runtime, and a
            // build says nothing about it.
            let first = running.remove(at: elsewhere)
            running.insert(first, at: 0)
        }

        let existing = Set(workspaces.map(\.name))
        let new = destinations.compactMap { path -> PickerModel.Item? in
            let short = abbreviate(path)
            let name = (short as NSString).lastPathComponent
            // A directory whose workspace already exists is reachable above.
            guard !existing.contains(name) else { return nil }
            return PickerModel.Item(
                kind: .destination(path: path),
                workspace: "",
                context: "",
                title: name,
                // The whole path, still, even though the row now draws it as
                // one line: this is also what the query is matched against,
                // and a folder findable by `www/acaua` yesterday should not
                // have become findable only by `acaua`.
                detail: short,
                command: "",
                path: path,
                busy: false,
                lastActive: nil
            )
        }
        return running + new
    }

    /// Rebuild the rows of any "go to" list that happens to be open.
    ///
    /// A picker's items are a snapshot taken when it opened — which is right
    /// for a search, whose rows are an answer to a question already asked,
    /// and wrong for this one, whose rows are a list of what is running. A
    /// tab that renames itself while you are looking at the list should
    /// rename itself in the list.
    ///
    /// Only the flat list, and only while it is up: a catalog of themes does
    /// not change because a terminal did something.
    private func refreshOpenLists() {
        // The windows first, then the work. `pickerItems` reads `views` to
        // find out where a window is, and reading it inside a
        // `views[window]?...` assignment is two accesses to one property at
        // once — which Swift stops dead at runtime and says nothing about at
        // build time.
        let open = views.compactMap { window, view in
            view.picker?.mode == .goTo ? window : nil
        }
        for window in open {
            let items = pickerItems(for: window)
            views[window]?.picker?.items = items
        }
    }

    /// What the palette lists, for each of its three questions.
    ///
    /// Built here rather than in the view for the reason every other list is:
    /// deciding what is in a list is the model's business, and the view's is
    /// drawing it. Static because none of it depends on this session — the
    /// commands are a constant, and the themes and faces are what is
    /// installed on the machine.
    private static func paletteItems(_ catalog: PickerModel.Catalog) -> [PickerModel.Item] {
        func item(
            kind: PickerModel.Item.Kind, context: String, title: String, detail: String = ""
        ) -> PickerModel.Item {
            PickerModel.Item(
                kind: kind, workspace: "", context: context, title: title,
                detail: detail, command: "", path: "", busy: false, lastActive: nil)
        }
        switch catalog {
        case .root:
            return Command.allCases.map {
                item(kind: .command($0), context: $0.group, title: $0.title)
            }
        case .themes:
            let worn = GhosttyApp.prefs.theme
            return ThemeCatalog.names.map {
                item(
                    kind: .theme($0), context: "", title: $0,
                    detail: $0 == worn ? "worn" : "")
            }
        case .fonts:
            let worn = GhosttyApp.prefs.fontFamily
            return FontCatalog.monospaced.map {
                item(
                    kind: .fontFamily($0), context: "", title: $0,
                    detail: $0 == worn ? "worn" : "")
            }
        }
    }

    /// What a tab is called: the name somebody gave it, or else whatever its
    /// program last called it. The program's own title is left alone
    /// underneath — where a workspace is and what is running are read from
    /// it — so clearing the name hands the tab straight back to it.
    private func displayTitle(of tab: TabEntity) -> String {
        nameStore.tab(tab.id) ?? tab.title
    }

    /// A typed name as it is kept: trimmed, and nothing at all when nothing
    /// is left, which is how a name is taken back.
    private static func chosenName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - Claude Code's mode

    /// The tabs worth reading Claude Code's mode off — the ones that look like
    /// they are running it. Everything else would only ever answer "none".
    func claudeTabs() -> [TabID] {
        workspaces.flatMap(\.tabs).filter { Self.program(of: $0) == "claude" }.map(\.id)
    }

    /// What the screens said. `.some(nil)` is a footer naming no mode —
    /// manual — and clears the colour; a tab missing from `modes` could not
    /// be read this time, and keeps what it had.
    func noteClaudeModes(_ modes: [TabID: ClaudeMode?], activities: [TabID: ClaudeActivity] = [:]) {
        var next = claudeModes
        for (id, mode) in modes { next[id] = mode }
        var nextActivities = claudeActivities
        for (id, activity) in activities { nextActivities[id] = activity }
        // Tabs that are gone, or have stopped running Claude Code, lose it.
        let running = Set(claudeTabs())
        next = next.filter { running.contains($0.key) }
        nextActivities = nextActivities.filter { running.contains($0.key) }
        guard next != claudeModes || nextActivities != claudeActivities else { return }
        claudeModes = next
        claudeActivities = nextActivities
        publish()
    }

    /// A tab's title with the busy marks its program put there taken off.
    ///
    /// Programs that title themselves also spin: Claude Code writes `✳` and
    /// a rotating `◐◑◒◓` at the head of every title it sets. The row already
    /// says whether the tab is busy, with a mark of its own that means the
    /// same thing — so leaving these in prints it twice and puts punctuation
    /// where the eye is looking for a word. The sidebar drops the same `✳`
    /// for the same reason.
    static func plainTitle(_ title: String, fallback: String) -> String {
        let trimmed = title
            .drop { Self.spinnerMarks.contains($0) || $0.isWhitespace }
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// The marks Claude Code writes at the head of every title it sets: its
    /// own `✳`, and the frames of its spinner.
    private static let spinnerMarks: Set<Character> = ["✳", "◐", "◑", "◒", "◓", "✻", "✽"]

    /// What is running in the tab, with a guess for when the daemon cannot say.
    ///
    /// The daemon reads the name from the foreground process, which is the
    /// true answer — but it only reaches a client whose daemon is new enough
    /// to send it, and the daemon outlives the app by design. Until one is
    /// restarted the field is empty, and the row would go back to saying
    /// nothing about what it is.
    ///
    /// So: the marks above are Claude Code's signature — the sidebar already
    /// singles out `✳` as its doing — and a title wearing one is worth
    /// naming. A guess, and only ever used in place of silence: the moment
    /// the daemon answers, its answer wins.
    private static func program(of tab: TabEntity) -> String {
        let wearsClaudeMarks = tab.title.first.map(spinnerMarks.contains) == true
        if !tab.command.isEmpty {
            // Claude Code's own installer keeps each release as a file named
            // after its version, and the process is called what the file is:
            // `2.1.281`, which names nothing. Behind a title wearing its
            // marks, a bare version number is Claude Code.
            if wearsClaudeMarks, isVersionNumber(tab.command) { return "claude" }
            return tab.command
        }
        return wearsClaudeMarks ? "claude" : ""
    }

    private static func isVersionNumber(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// The left column of a terminal row: which workspace, and where in it.
    ///
    /// The tab's directory relative to the workspace's own is the shortest
    /// true thing that separates siblings — `777leads/api` rather than
    /// `~/www/777leads/api`, and short enough to sit in a column. When the
    /// tab is at the workspace's root, or the daemon could not say where it
    /// is, the position stands in instead, but only where there is a sibling
    /// to be told apart from.
    private func context(
        for tab: TabEntity, in workspace: WorkspaceEntity, alone: Bool
    ) -> String {
        let name = workspace.name
        if let tail = relativePlace(of: tab.cwd, in: workspace) { return "\(name)/\(tail)" }
        guard !alone, let position = workspace.tabs.firstIndex(where: { $0.id == tab.id })
        else { return name }
        return "\(name) \(position + 1)"
    }

    /// The part of `cwd` below the workspace's own directory, or nil when it
    /// is not below it, is the directory itself, or is unknown.
    ///
    /// A tab that wandered outside its workspace keeps its last component
    /// rather than a path nobody can read in a column: `777leads` with a tab
    /// in `~/other/thing` reads `777leads/thing`, which is at least where it
    /// is, and the preview says the rest.
    private func relativePlace(of cwd: String, in workspace: WorkspaceEntity) -> String? {
        guard !cwd.isEmpty else { return nil }
        let path = (cwd as NSString).standardizingPath
        let root = (workspace.place as NSString).standardizingPath
        // A tail is only worth showing if it is a name. At the filesystem
        // root `lastPathComponent` is "/", which would read as a column with
        // a stray slash in it and say nothing about which tab this is.
        func named(_ tail: String) -> String? {
            tail.isEmpty || tail == "/" ? nil : tail
        }
        guard !workspace.place.isEmpty else {
            // No remembered directory to measure against: the tab's own last
            // component is the only thing on offer, and it says nothing when
            // it merely repeats the workspace's name.
            let tail = (path as NSString).lastPathComponent
            return tail == workspace.name ? nil : named(tail)
        }
        guard path != root else { return nil }
        // The slash matters: without it a root of `~/www/proj` would claim
        // `~/www/project-two` as one of its own.
        guard path.hasPrefix(root + "/") else {
            return named((path as NSString).lastPathComponent)
        }
        return named(String(path.dropFirst(root.count + 1)))
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func loadDestinations(for window: WindowID) {
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = Zoxide.directories()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.views[window]?.picker != nil else { return }
                self.destinations = paths
                let items = self.pickerItems(for: window)
                self.views[window]?.picker?.items = items
                self.publish()
            }
        }
    }

    /// Which preview request is the current one, so the ones the arrow keys
    /// left behind can be dropped rather than answered.
    private var previewGeneration = 0

    private func loadPreview(of tab: TabID, pane: UInt32, for item: String, in window: WindowID) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? Daemon.colouredPreview(workspace: tab.workspace, tab: pane)) ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self, self.views[window]?.picker?.previewOf == item else { return }
                self.views[window]?.picker?.previewText = text
                self.publish()
            }
        }
    }

    /// Open a workspace named after a directory, with its first tab there.
    private func openWorkspace(at path: String, in window: WindowID) {
        let name = (path as NSString).lastPathComponent
        if workspaces.first(where: { $0.name == name })?.tabs.isEmpty == false {
            dispatch(.activateWorkspace(name), from: window)
            return
        }
        do {
            let id = try Daemon.newTab(in: name, cwd: path)
            refreshFromDaemon()
            activate(TabID(workspace: name, root: id), in: window)
            publish()
            renderer(window)?.focusActiveTerminal()
        } catch {
            renderer(window)?.present(error: error.localizedDescription)
        }
    }

    /// Re-list and reconcile after any mutation the daemon took part in.
    private func refreshFromDaemon() {
        generation += 1
        guard let listing = try? Daemon.list() else { return }
        reconcile(listing, placing: false)
    }

    /// Every window is offered a snapshot; only the ones whose own has
    /// changed are handed it.
    ///
    /// Rebuilt for all of them on every publish rather than working out which
    /// windows an intent could have touched — the per-window diff below is
    /// what keeps "unchanged values are silent" true, and it is exact, where
    /// that reasoning would only be careful. A selection change in one window
    /// leaves every other window's snapshot identical, so the others stay
    /// quiet on their own.
    private func publish() {
        for id in windowOrder {
            guard let renderer = renderer(id) else { continue }
            let snapshot = makeSnapshot(for: id)
            guard snapshot != lastSnapshots[id] else { continue }
            lastSnapshots[id] = snapshot
            renderer.render(snapshot)
        }
        // What each window carries, kept with the places of what is not
        // running now; and nothing a window carries counts as put away.
        for id in windowOrder where views[id] != nil {
            remembered[id] = arrangement(of: id)
        }
        putAwayStore.remove(views.values.flatMap(\.workspaces))
        let arrangement = windowOrder.map { id in
            Arrangement(
                window: id, workspaces: remembered[id] ?? [],
                showing: views[id]?.workspaces ?? [], tab: views[id]?.tab)
        }
        if arrangement != lastArrangement {
            lastArrangement = arrangement
            onArrangementChange?()
        }
    }

    private func makeSnapshot(for window: WindowID) -> SessionSnapshot {
        let view = views[window] ?? WindowView()
        let sidebar = sidebarStore.state(for: window)
        // The workspaces this window carries, in its order — not everything
        // the daemon has. Anything missing is still a ⌘P away.
        let rows = view.workspaces.compactMap { name -> SessionSnapshot.SidebarRow? in
            guard let workspace = workspaces.first(where: { $0.name == name }) else { return nil }
            return SessionSnapshot.SidebarRow(
                name: workspace.name,
                title: nameStore.workspace(workspace.name) ?? workspace.name,
                subtitle: workspace.subtitle,
                tabs: workspace.tabs.count,
                running: workspace.tabs.flatMap(\.busyTitles),
                place: workspace.place,
                dot: workspace.dot,
                isActive: workspace.name == view.workspace,
                tabRows: workspace.tabs.map { tab in
                    SessionSnapshot.SidebarTab(
                        id: tab.id,
                        title: Self.plainTitle(displayTitle(of: tab), fallback: "tab \(tab.id.root)"),
                        command: Self.program(of: tab),
                        busy: tab.busy,
                        isActive: tab.id == view.tab,
                        isElsewhere: views.contains {
                            $0.key != window && $0.value.tab == tab.id
                        },
                        claudeMode: claudeModes[tab.id],
                        claudeActivity: claudeActivities[tab.id]
                    )
                },
                expanded: !sidebar.folded.contains(workspace.name)
            )
        }
        let strip = (workspace(for: window)?.tabs ?? []).map { tab in
            SessionSnapshot.StripItem(
                id: tab.id,
                title: displayTitle(of: tab),
                busy: tab.busy,
                hasPanes: !tab.panes.isEmpty,
                isActive: tab.id == view.tab,
                isElsewhere: views.contains { $0.key != window && $0.value.tab == tab.id },
                claudeMode: claudeModes[tab.id],
                claudeActivity: claudeActivities[tab.id]
            )
        }
        let active = shownTab(in: window).map { tab in
            SessionSnapshot.ActiveTab(
                id: tab.id,
                title: displayTitle(of: tab),
                panes: tab.panes,
                focusedPane: focusedPane(of: tab, in: window)
            )
        }
        let universe = Set(workspaces.flatMap { $0.tabs.map(\.id) })
        return SessionSnapshot(
            sidebar: sidebar, picker: view.picker,
            rows: rows, strip: strip, active: active, universe: universe)
    }
}
