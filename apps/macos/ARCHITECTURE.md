# The macOS shell, in layers

The app is organized like a game engine: isolated layers with single
responsibilities, entities with handles, and immutable snapshots crossing the
boundaries. Nothing below the UI knows a window exists; nothing above a layer
mutates the one beneath it directly.

The rule that shapes everything else, as amended: **windows are made and
closed only when somebody asks for one** — ⌘⇧N, ⌥⌘W, a tab pulled out of the
row, or the restore at launch. Nothing else creates, closes, orders, hides or
reveals a window: not a switch, not a poll, not a render, not a reconcile. Switching workspace and
switching tab are the same operation they always were — flip which mounted
views are visible, *within a window*. Nothing else moves.

It read "there is one NSWindow, forever" for most of this app's life, and the
scars behind it are real: flicker on switch, focus falling to another app, the
tab bar landing in the wrong row, fights with tiling window managers. But none
of that came from a second window existing. It came from windows being made
and unmade as **the price of an ordinary switch**, because native tabs mean
AppKit's window-per-tab. A window you asked for is not that, and everything
the old rule bought survives the amendment. Two things do not come back: a
pool of windows that grows and shrinks with the tabs, and N copies of the
selection state that disagree.

**The tests drive a build of their own**, KeepDev (`tools/build-dev.sh`):
same source, another name, another bundle id, another state directory. The
suites stop the app, kill it, drag its windows about and quit it, and the
window server tells apps apart by name — so without the rename every one of
those reached whatever Keep somebody happened to be working in.

## Layers

```
6  UI / render      MainWindowController, KeepWindow, TabStripView,
                    TabContentContainer, SidebarHost, WorkspaceSidebar
5  Workspace        Session, WorkspaceEntity          which tab is active, order, focus
4  Pane / Tab       TabEntity                         per-tab state: label, panes, focus
3  Display          SurfacePool, TerminalSurfaceView, GhosttyApp
2  Emulation        keepd + libghostty                (crates/, untouched by the app)
1  PTY              keepd                             (crates/, untouched by the app)
```

- **Intents flow down** (6 → 5): the UI never mutates state; it dispatches an
  `Intent` and waits to be handed a new snapshot.
- **Snapshots flow up** (4 → 5 → 6): plain `Equatable` values. Views never
  appear in snapshots — they carry ids, and the UI resolves ids through
  `SurfacePool`.
- **One writer**: `Session` is the only code that changes which workspace or
  tab is active. `Store.selectedWorkspace`, `WindowManager.currentWorkspace`
  and the re-entrancy flags that guarded them do not exist anymore.

## Folder structure

```
apps/macos/Sources/Keep/
├── main.swift                    entry point, AppDelegate, menus (⌘T, ⌘W, ⌘1–9…)
├── Support/
│   └── Trace.swift               KEEP_TRACE-gated session tracing
├── Daemon/
│   ├── Daemon.swift              wire protocol + Daemon.Tab/Workspace models
│   └── DaemonPoller.swift        2 s timer → Session.reconcile
├── Model/                        layers 4–5 — no AppKit import
│   ├── Snapshots.swift           TabID, SidebarState, PaneState, PaneTree,
│   │                              Intent, *Snapshot
│   ├── TabEntity.swift           layer 4: one per daemon root tab
│   ├── WorkspaceEntity.swift     layer 5: tab order, active tab, status
│   ├── Session.swift             layer-5 root: single writer, replaces Store
│   └── SidebarStateStore.swift   persistence: sidebar per window, tab order,
│                                  and which windows were open (JSON)
├── Display/
│   ├── SurfacePool.swift         surfaces created once, keyed window/workspace/tab
│   └── Ghostty/
│       ├── GhosttyApp.swift      libghostty runtime
│       └── SurfaceView.swift     Metal surface; visibility-aware display link
└── UI/
    ├── MainWindowController.swift  one per window; renders its snapshot; switch
    ├── KeepWindow.swift            chrome: unified toolbar, tint, sidebar toggle
    ├── TabStripView.swift          app-drawn tab bar, native look
    ├── TabContentContainer.swift   mounted tab hosts; exactly one visible
    ├── SidebarHost.swift           flat sidebar host + backdrop + state applier
    └── WorkspaceSidebar.swift      SwiftUI workspace list (snapshot in, intent out)
```

## The interfaces that matter

```swift
/// Identity of a UI tab. Daemon tab ids are per-workspace counters, so the
/// workspace name is part of the identity ("dawd/1" and "luhw/1" are different
/// tabs wearing the same number).
struct TabID: Hashable, Codable { let workspace: String; let root: UInt32 }

/// The sidebar's collapsed state and width. One value per window — see
/// "The sidebar is furniture" below.
struct SidebarState: Codable, Equatable { var isCollapsed: Bool; var width: CGFloat }

/// The one downward channel. Every mutation in the app enters through here.
enum Intent {
    case activateWorkspace(String), activateTab(TabID), activateTabIndex(Int)
    case newTab(in: String?), newWorkspace(named: String)
    case closeTab(TabID?), closePane(UInt32?), killWorkspace(String)
    case split(UInt8), focusPane(UInt32)
    case setSidebar(SidebarState)
    case nextTab, previousTab
}

/// Layer 4. Owns what is this tab's own business — title, busy, panes, which
/// pane holds the keyboard — and nothing about how any of it is drawn.
@MainActor final class TabEntity {
    let id: TabID
    private(set) var title: String, busy: Bool, panes: [PaneState]
    private(set) var focusedPane: UInt32
    func apply(root: Daemon.Tab, panes: [Daemon.Tab]) -> Bool   // reconciliation; true = changed
    func noteFocus(pane: UInt32)                                 // single writer: Session
}

/// Layer 5 root. The UI holds a reference to this and to nothing else below.
@MainActor final class Session {
    weak var renderer: SessionRendering?
    func start()
    func dispatch(_ intent: Intent)
    func reconcile(_ listing: [Daemon.Workspace])   // from DaemonPoller
}

/// What the UI implements. render() receives a full immutable snapshot and
/// diffs it against the last one applied.
@MainActor protocol SessionRendering: AnyObject {
    func render(_ snapshot: SessionSnapshot)
    func present(error: String)
    /// Entering the workspace you are already in changes no state, so nothing
    /// renders — but the click that asked has just left the keyboard in the
    /// sidebar. The request is real even when the answer is "already there".
    func focusActiveTerminal()
}
```

## The switch pipeline

One synchronous function, one run-loop turn, no dispatch hops. It is the only
switch path in the program — sidebar clicks, strip clicks, ⌘1–9 and empty-
workspace entry all funnel into it.

```
1. incoming.apply(panes:) + setFocusedPane              arrangement and focus
                                                         ring settle first
2. incoming.layoutSubtreeIfNeeded()                      surfaces sized for the
                                                         geometry they will have
3. CATransaction { incoming.isHidden = false             unhiding runs
                   outgoing.isHidden = true }            viewDidUnhide on each
                                                         pane synchronously: it
                                                         flushes the size it
                                                         deferred and draws one
                                                         frame, inside this
                                                         transaction. The swap
                                                         commits as one frame —
                                                         never zero tabs visible
4. makeFirstResponder(incoming.focusedPane surface)      intra-window move; the
                                                         window never resigns key
5. strip selection + guarded window.title                pure paints
```

The sidebar is not in this list: it belongs to the window, applied once by
that window's `render` when it changes, and a switch never touches it.

Hidden surfaces draw zero frames (`viewDidHide` stops the link; occlusion
observing remains the backstop for minimize/bury) and defer PTY resizes —
a window resize touches only the visible tab's sessions; the backlog flushes
as one call on reveal.

## Data flows

**Open a new tab** (⌘T, or the "+" on a workspace in the sidebar): →
`dispatch(.newTab(in:))` →
Session resolves the active workspace, calls the daemon, re-lists, creates the
`TabEntity` → activates it → `render`: the container mounts a host on
first presentation — this is hydration, the one moment a surface and its
`keep` client are created — then the pipeline above runs.

**Collapse the sidebar**: toggle → `dispatch(.setSidebar(collapsed))` →
Session stores it for the window that asked and persists it (debounced JSON,
`~/Library/Application Support/Keep/sidebar-state.json`) → render applies it
animated. A divider drag reports back the same way, debounced, guarded
against echo.

**The sidebar is furniture.** It was per-tab at first, frozen and restored
with each one. In use that reads as a glitch, not as memory: you collapse it,
move to another tab, and it is back. So there is one state per window, and it
stays where you put it no matter which tab you are on. Per window rather than
per app for the same reason it is not per tab: one state for everything
reproduces the identical glitch across windows — you collapse it in the narrow
one and the wide one you never touched rearranges itself. The rule is what it
always was, with a word added: furniture stays where you put it, **in the room
you put it in**.

**Switch tab** (same flow for switch workspace): click → `dispatch(.activateTab)`
→ Session updates the active ids — the outgoing entity needs no freezing,
since nothing sends a deactivated entity messages → `render` → pipeline. A workspace click resolves to that workspace's remembered
active tab and joins the identical path.

**Split a pane** (⌘D right, ⌘⇧D down): `dispatch(.split(dir))` → Session asks
the daemon for a tab split off the *focused* pane → reconcile → render. The
arrangement is a tree: splitting replaces the pane you were in with a pair,
and doing it again on either half replaces that half in turn. `PaneTree`
rebuilds that shape from the daemon's records (each pane knows which pane it
came from and in which direction), and the UI renders it as nested split
views — one `NSSplitView` has one orientation, so a flat list would force the
whole tab to share whichever direction came first.

**Return to the previous tab**: identical dispatch; every step is a cache hit.
The host is still mounted, surfaces alive, Metal layers holding their last
frame; the pipeline puts the keyboard back on the pane that had it, and the
focus ring marks which one that is when the tab is split.

## More than one window

**Each window carries its own list of workspaces.** A new one carries none:
its sidebar is empty and the content is the empty state. Every workspace there
is remains one ⌘P away, and choosing one brings it into that window and keeps
it. The list assembles itself from use rather than being managed. The sidebar's
context menu names the two endings separately, because they are nothing alike:
*remove from this window* leaves the sessions running, *end workspace* kills
them for everybody.

**The same tab can be open in two windows, and it is the same shell.** Not a
copy and not a picture: two surfaces, two `keep` clients, two subscribers on
one daemon tab — the arrangement two people attached to one tmux session have
always had. Type in either and both show it.

**A tab is fitted to the smallest viewer watching it.** The daemon keeps a size
per subscriber and applies the minimum. The asymmetry is the reason: a PTY
*wider* than the grid drawing it scrambles — 200-column lines fold at 80, a
cursor addressed to column 150 saturates — while a PTY narrower than the window
showing it merely leaves margin. So the safe direction is down.

A viewer that cannot be seen does not vote. Every tab a window has ever shown
stays mounted here with a live client, merely hidden, so without that rule a
narrow window that visited a tab once would throttle it forever while showing
something else. Each surface keeps a file beside its attach target saying
whether it is on screen; a hidden client reports 0×0, which the daemon leaves
out of the minimum. Being buried behind another app deliberately does not
count as hidden: that window still has a real size and comes back in a second.

**The cost, stated rather than discovered.** When a program asks the terminal a
question — cursor position (DSR), identity (DA1/DA2), theme (OSC 10/11) — the
daemon passes the question to every client and each one answers on the shared
PTY. With a tab mirrored into two windows, the program gets **two answers to
every query**, and a duplicated `CSI 24;1R` looks like garbage typed at the
prompt. This is structural — `keep-vt` has no reply channel — and it is
accepted, not a bug waiting to be found. It is the price of a mirrored tab.

**A tab pulled out of the row opens in a window of its own.** Drag it clear of
the row — forty points, about a row and a half, so a wrist that wanders while
reordering does not make windows by accident — and it lifts out and follows
the pointer. Let go over another window and that window shows it; let go over
nothing and a new window appears there, the size of the one it came from.

What moves is the view, and only the view. The shell keeps running, the tab
stays in its workspace, and it stays in the row it came from — the row lists
the *workspace's* tabs, not the window's, so it cannot leave without changing
workspaces, and the daemon has no operation for that. What changes is that the
window it left moves on to a neighbour, and the row marks the tab `⧉`: on
screen somewhere else. Without that mark a tab torn into its own window looks
like a tab that never went anywhere.

The row measures the drag against the pointer (`NSEvent.mouseLocation`) rather
than against the events. A drag that wanders over another window of the same
app stops belonging to the window that started it: the events keep coming —
the press captured the mouse — but their coordinates are measured from
somewhere else, and read straight, a tab dragged onto the next window reads
from inside the row as a tab that never left it.

**Known limit.** The background colour a program sets (OSC 11) is still
app-wide: the runtime reports it against a surface, but the chrome adopts it
for everybody, so a program in one window retints the other's toolbar. Nothing
is lost by it and no session is affected — it is on the list, not in the
design.

**Windows come back the way we left them, not the way AppKit would.**
`isRestorable` is off. What was open, where, and what each window carried goes
into `windows.json` when a window closes and when the app is asked to quit —
the two moments the set actually changes — and every window is built in one
turn of the run loop at launch. The count and the geometry are exactly what a
tiling window manager reacts to, so they have to be ours to decide, once,
rather than AppKit's to reopen whenever it likes.

## Rules kept from the session's scars

- Navigation never hangs off selection state (`List(selection:)` wrote
  selection on reveal; every write was a switch nobody asked for).
- The daemon is the source of truth for tabs; the poller reconciles every 2 s
  and only ever prunes or relabels — it cannot mount, present, or switch.
- Closing the **last** window quits the app; the daemon keeps everything
  running, and closing any window kills no sessions.
  Closing a *tab* is only ever the explicit intent. ⌘W closes the focused
  **pane** — for a tab with no splits the two are the same thing — and the
  daemon hands a closed pane's children to its parent, so closing one pane
  never takes the arrangement apart.
- Unchanged values are silent: snapshots are Equatable and every applier
  diffs, so a quiet poll produces zero view churn (and zero accessibility
  noise for window managers to react to).
