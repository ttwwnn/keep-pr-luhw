import Foundation

/// Identity of a UI tab. Daemon tab ids are per-workspace counters, so the
/// workspace name is part of the identity: "dawd/1" and "luhw/1" are two
/// different tabs wearing the same number.
struct TabID: Hashable, Codable, CustomStringConvertible {
    let workspace: String
    let root: UInt32
    var description: String { "\(workspace)/\(root)" }
}

/// Which window. A slot rather than a UUID: it is stable across launches, so
/// a window's furniture comes back to it; it is reused when a window closes,
/// so the next window inherits that furniture rather than starting bare; and
/// it is short enough to read in a trace.
struct WindowID: Hashable, Codable, CustomStringConvertible {
    let slot: Int
    var description: String { "w\(slot)" }
    static let first = WindowID(slot: 0)
}

/// What one window is pointed at.
///
/// Not a second copy of anything below it — these are the facts that are
/// genuinely different from one window to the next, and `Session` is still
/// the only code that writes them. The era this replaces had a `Store`, a
/// `WindowManager` and N sidebars each writing their own idea of the same
/// fact; what was wrong there was the number of writers, not the number of
/// values.
struct WindowView: Equatable {
    /// The workspaces this window carries, in the order its sidebar shows
    /// them. A new window has none: every workspace is a ⌘P away, and the
    /// ones you go to are the ones that stay.
    var workspaces: [String] = []
    var workspace: String?
    var tab: TabID?
    /// Which pane holds the keyboard, per tab, *in this window*. Two windows
    /// showing one tab each have their own first responder, and a click in
    /// one must not move the keyboard in the other.
    var focusedPane: [TabID: UInt32] = [:]
    /// An overlay belongs to the window it was opened over.
    var picker: PickerModel?
    /// Per window, so one window's keystroke cannot cancel the answer the
    /// other is still waiting for.
    var searchGeneration = 0
}

/// The sidebar's collapsed state and width.
///
/// One value for the whole app, not one per tab: the sidebar is furniture,
/// and furniture that rearranges itself as you move between tabs reads as a
/// glitch rather than as memory.
struct SidebarState: Hashable, Codable {
    var isCollapsed: Bool
    var width: CGFloat
    /// Workspaces whose tab list is folded shut. The set holds the closed
    /// ones rather than the open ones so that the default — an empty set —
    /// shows everything, and the feature is visible before anyone has
    /// touched a chevron.
    var folded: Set<String> = []
    /// Tabs live in the sidebar, nested under their workspaces, and the
    /// titlebar row steps aside.
    var verticalTabs: Bool = false
    static let initial = SidebarState(isCollapsed: false, width: 250)

    /// By hand, so a state file written before these fields existed still
    /// decodes: synthesized Codable treats a missing key as an error, and an
    /// error here silently resets the sidebar to factory settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isCollapsed = try c.decode(Bool.self, forKey: .isCollapsed)
        width = try c.decode(CGFloat.self, forKey: .width)
        folded = try c.decodeIfPresent(Set<String>.self, forKey: .folded) ?? []
        verticalTabs = try c.decodeIfPresent(Bool.self, forKey: .verticalTabs) ?? false
    }

    init(isCollapsed: Bool, width: CGFloat) {
        self.isCollapsed = isCollapsed
        self.width = width
    }
}

/// One pane beyond a tab's root, in daemon (creation) order.
struct PaneState: Hashable {
    let tab: UInt32
    /// The pane this one was split off from — the root, or another pane.
    let splitOf: UInt32
    /// Protocol values: 1 = right, 2 = down.
    let splitDir: UInt8
}

/// How a tab's panes are arranged.
///
/// Splitting replaces the pane you were in with a pair: that pane and the new
/// one, side by side or stacked. Do it again on either half and that half is
/// replaced in turn — so an arrangement is a tree, and a tab that mixes
/// directions is the ordinary case rather than the exotic one.
///
/// The daemon has recorded this all along (each pane knows which pane it was
/// split from, and in which direction); this rebuilds the shape from those
/// records.
indirect enum PaneTree: Hashable {
    case leaf(UInt32)
    /// `vertical` is the divider's orientation: vertical divider = side by
    /// side, which is what "split right" means.
    case split(vertical: Bool, PaneTree, PaneTree)

    static func build(root: UInt32, panes: [PaneState]) -> PaneTree {
        var tree = PaneTree.leaf(root)
        // Creation order matters: a pane can only be split off something that
        // already exists, so replaying in order rebuilds the exact shape.
        for pane in panes {
            tree = tree.replacing(
                leaf: pane.splitOf,
                with: .split(
                    vertical: pane.splitDir != 2,
                    .leaf(pane.splitOf),
                    .leaf(pane.tab)
                )
            )
        }
        return tree
    }

    private func replacing(leaf target: UInt32, with subtree: PaneTree) -> PaneTree {
        switch self {
        case .leaf(let id):
            return id == target ? subtree : self
        case .split(let vertical, let first, let second):
            return .split(
                vertical: vertical,
                first.replacing(leaf: target, with: subtree),
                second.replacing(leaf: target, with: subtree)
            )
        }
    }

    var leaves: [UInt32] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let first, let second): return first.leaves + second.leaves
        }
    }
}

/// The permission mode Claude Code is in, as shift-tab cycles it — the ones
/// it gives a colour of its own. Manual, its default, has none and is nil.
///
/// Read off the screen, from the line under the prompt that says so
/// (`⏸ plan mode on`, `⏵⏵ bypass permissions on`): Claude Code tells no
/// hook and no terminal sequence when the mode changes, and that line is
/// there the moment it does.
enum ClaudeMode: Hashable {
    case plan
    case acceptEdits
    /// Bypass permissions, and don't-ask, which Claude Code colours the same.
    case bypass
    case auto

    /// The mode a screen's footer declares, or nil when it declares none.
    ///
    /// Only the first line under the last horizontal rule is read — the rule
    /// closing the prompt box, where Claude Code writes the mode. The same
    /// words anywhere else on screen are conversation, not a mode.
    /// `.some(nil)` is manual: a footer is there and names no mode.
    /// `nil` is "cannot tell" — a dialog in front, or not Claude Code — and
    /// leaves whatever was known before standing.
    static func declared(onScreen text: String) -> ClaudeMode?? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A rule is a line that starts as one. The one above the prompt
        // carries the session's name partway along (`──── fix-upload ─`), so
        // what follows the run of rule is not asked about.
        func isRule(_ line: Substring) -> Bool {
            line.trimmingCharacters(in: .whitespaces)
                .hasPrefix(String(repeating: "─", count: 12))
        }
        // The prompt box, and only the prompt box: a rule, the prompt, a
        // rule. A dialog in front draws rules of its own and marks its
        // choices with the same ❯, but opens with its question — the box
        // opens with the prompt itself.
        guard let rule = lines.lastIndex(where: isRule),
              let opening = lines[..<rule].lastIndex(where: isRule),
              let first = lines[(opening + 1)..<rule].first(where: {
                  !$0.trimmingCharacters(in: .whitespaces).isEmpty
              }),
              first.trimmingCharacters(in: .whitespaces).hasPrefix("❯")
                  || first.trimmingCharacters(in: .whitespaces).hasPrefix(">")
        else { return nil }
        guard let footer = lines[(rule + 1)...].first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return .some(nil) }
        let said = footer.trimmingCharacters(in: .whitespaces)
        if said.hasPrefix("⏸ plan mode on") { return .some(.plan) }
        if said.hasPrefix("⏵⏵ accept edits on") { return .some(.acceptEdits) }
        if said.hasPrefix("⏵⏵ bypass permissions on") { return .some(.bypass) }
        if said.hasPrefix("⏵⏵ don't ask on") { return .some(.bypass) }
        if said.hasPrefix("⏵⏵ auto mode on") { return .some(.auto) }
        return .some(nil)
    }
}

/// Where Claude Code's turn stands, read off the same screen as the mode.
///
/// Claude Code says it in its own words and nowhere else a tab can reach:
/// a dialog waiting on an answer ends in `Esc to cancel`; a turn still going
/// shows `esc to interrupt` under the prompt; a turn that ended while
/// dynamic workflows run on leaves `✻ Waiting for 1 dynamic workflow to
/// finish` as its last line; any other last line (`✻ Baked for 23s`) is a
/// turn that is over. The title's spinner cannot tell these apart: it keeps
/// spinning while a workflow is awaited.
enum ClaudeActivity: Hashable {
    /// A turn is running: the mode's colour, as before.
    case working
    /// The turn ended with work still running behind it: dynamic workflows,
    /// background agents, shells or monitors.
    case waitingForWorkflow
    /// A question, a permission or a dialog is waiting on an answer.
    case waitingForYou
    /// The turn is over.
    case done

    /// Codex's final status above its prompt uses the same blue as a Claude
    /// workflow while it says Working. Older mentions in the transcript do
    /// not keep the colour after a later message has arrived.
    static func readCodex(onScreen text: String) -> ClaudeActivity? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let prompt = lines.lastIndex(where: { $0.hasPrefix("»") || $0.hasPrefix("›") })
        else { return nil }
        let conversation = lines[..<prompt].filter {
            !$0.isEmpty && !$0.hasPrefix(String(repeating: "─", count: 12))
        }
        if conversation.contains(where: { $0.contains("Jump to bottom") }) { return nil }
        guard let last = conversation.last else { return .done }
        if last.range(of: #"^(?:[•●◦∙*]\s*)?(?:Working|Workflow)(?:\s*\(.*\)|\s*…|\s*\.{3})?\s*$"#,
                      options: .regularExpression) != nil { return .waitingForWorkflow }
        return lines[(prompt + 1)...].contains(where: { $0.lowercased().contains("esc to interrupt") })
            ? .working : .done
    }

    /// What the screen says, or nil when it says nothing that can be told
    /// apart — not Claude Code, or caught mid-redraw — leaving what was known
    /// before standing.
    static func read(onScreen text: String) -> ClaudeActivity? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        func isRule(_ line: Substring) -> Bool {
            line.trimmingCharacters(in: .whitespaces)
                .hasPrefix(String(repeating: "─", count: 12))
        }
        func trimmed(_ line: Substring) -> String { line.trimmingCharacters(in: .whitespaces) }
        func isPrompt(_ line: Substring) -> Bool {
            let t = trimmed(line)
            return t.hasPrefix("❯") || t.hasPrefix(">")
        }
        // A dialog first: Claude Code ends most it draws (a question, a
        // permission, trusting a folder, a picker) with `Esc to cancel`.
        // Checked before the box, because a permission shows the prompt that
        // asked for it (`❯ Crie o arquivo…`) between two rules of its own.
        let tail = lines.reversed().lazy
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(4)
        if tail.contains(where: { $0.contains("Esc to cancel") }) { return .waitingForYou }
        // The prompt box, found the way the mode is: a rule, the prompt, a
        // rule.
        guard let rule = lines.lastIndex(where: isRule),
              let opening = lines[..<rule].lastIndex(where: isRule),
              let first = lines[(opening + 1)..<rule].first(where: { !trimmed($0).isEmpty }),
              isPrompt(first)
        else {
            // No box: the plan's approval draws its choices without the
            // `Esc to cancel` line — the pointer on a numbered choice
            // (`❯ 1. Yes, auto-accept edits`) is what is left to go by.
            if lines.contains(where: isChoicePointer) { return .waitingForYou }
            return nil
        }
        let footer = lines[(rule + 1)...]
        // A view that is not the session's own turn: an agent's conversation
        // (`❯ Message @general-purpose…`, `stop all agents`) or the detailed
        // transcript. What it shows says nothing of the main turn.
        if trimmed(first).hasPrefix("❯ Message @")
            || footer.contains(where: { $0.contains("stop all agents") || $0.contains("Showing detailed transcript") })
        {
            return nil
        }
        // Under the box: Claude Code offers the interrupt only while a turn
        // runs, and the box stays put however the conversation scrolls.
        if footer.contains(where: { $0.lowercased().contains("esc to interrupt") }) { return .working }
        // Work still running in the background, counted live under the box
        // (`· 2 shells ·`, `· 5 shells, 1 monitor ·`, `· 3 background tasks ·`):
        // the turn is over but Claude Code will be back when it ends or
        // speaks, as with a workflow. The `… · 5 shells, 1 monitor still
        // running` on the turn's last line is not read — it stays after they
        // end.
        if footer.contains(where: isRunningBackgroundWork) { return .waitingForWorkflow }
        // Above it, the conversation — unless it is scrolled back, where the
        // last status line in sight is an old one.
        let conversation = lines[..<opening]
        if conversation.contains(where: { $0.contains("Jump to bottom") || $0.contains(" new message") }) {
            return nil
        }
        // The last status line Claude Code wrote: a glyph of its spinner and
        // a capitalised word, `✻ Baked for 23s`, `✶ Roosting… (16m)`. A bullet
        // in the conversation (`· Qual…` under an answer) is indented under
        // `⎿` or starts lower-case.
        guard let status = conversation.last(where: isStatusLine) else { return .done }
        if status.contains("Waiting for"), status.contains("to finish") {
            // Dynamic workflows or background agents. Still waited on only
            // while one is listed running under the footer (`◯ name ▰▰ 1/2`);
            // a turn that went on and was interrupted writes no new line, and
            // the old one would otherwise stand for good.
            return footer.contains(where: { trimmed($0).hasPrefix("◯") }) ? .waitingForWorkflow : .done
        }
        if status.contains("…") { return .working }
        return .done
    }

    /// The kinds of background work whose count Claude Code keeps under the
    /// box, as it words them, that bring it back when they end or report:
    /// shells, monitors (a command's or an MCP server's), local agents,
    /// dynamic workflows, MCP tasks, and a mix of those ("background tasks").
    ///
    /// Not every count is one: an Artifact comment monitor waits on people,
    /// not on work, and would keep a tab blue for as long as the page is
    /// watched; cloud sessions run on without this session; teams, dreaming
    /// and the auto-mode scan are not work the turn handed off.
    static let backgroundWork: Set<String> = [
        "shell", "shells", "monitor", "monitors", "local agent", "local agents",
        "background dynamic workflow", "background dynamic workflows",
        "background task", "background tasks", "MCP task", "MCP tasks",
    ]

    /// `2 shells`, `5 shells, 1 monitor`: one of the `·`-separated parts of
    /// the footer, every comma-separated item of it a count of running work.
    static func isRunningBackgroundWork(_ line: Substring) -> Bool {
        line.split(separator: "·").contains { part in
            let items = part.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return !items.isEmpty && items.allSatisfy { item in
                let words = item.split(separator: " ", maxSplits: 1)
                return words.count == 2 && words[0].allSatisfy(\.isNumber)
                    && backgroundWork.contains(String(words[1]))
            }
        }
    }

    /// `❯ 1. Yes`: the pointer of one of Claude Code's numbered choices.
    private static func isChoicePointer(_ line: Substring) -> Bool {
        var rest = line.drop { $0 == " " }
        guard rest.first == "❯" else { return false }
        rest = rest.dropFirst().drop { $0 == " " }
        let digits = rest.prefix { $0.isNumber }
        return !digits.isEmpty && rest.dropFirst(digits.count).first == "."
    }

    private static let spinnerGlyphs: Set<Character> = ["✻", "✳", "✢", "✶", "✽", "·", "*"]

    private static func isStatusLine(_ line: Substring) -> Bool {
        var rest = line.drop { $0 == " " }
        guard let glyph = rest.first, spinnerGlyphs.contains(glyph) else { return false }
        rest = rest.dropFirst()
        guard rest.first == " " else { return false }
        rest = rest.drop { $0 == " " }
        return rest.first?.isUppercase == true
    }
}

/// The one downward channel. Every mutation in the app enters as one of
/// these; nothing in the UI reaches past this into state.
enum Intent {
    /// Where a dragged pane was let go, relative to the pane under it.
    enum DropSide {
        case left, right, top, bottom
        /// On the pane itself: the two trade places.
        case onto
    }

    /// Put the tabs of the active workspace in this order, by hand.
    /// The row, in the order somebody just put it in. `in` names the
    /// workspace when the drag happened in the sidebar, where any group can
    /// be rearranged; nil means the window's active one, which is the only
    /// one the titlebar strip can see.
    case reorderTabs([UInt32], in: String?)

    /// Put the workspaces in a different order, by hand.
    case reorderWorkspaces(from: IndexSet, to: Int)

    /// Move a pane next to another one, or trade places with it.
    case movePane(UInt32, to: UInt32, side: DropSide)
    /// Take a pane out of its arrangement and give it a tab of its own.
    case detachPane(UInt32)

    case activateWorkspace(String)
    case activateTab(TabID)
    /// This window is done showing that tab — another one has taken it over.
    /// Show a neighbour instead, if this window was on it.
    ///
    /// Not a close and not a removal: the tab is running, it is still in the
    /// workspace, and it is still in this window's row. Only the view moves.
    case showAnotherTab(than: TabID)
    /// 0-based; -1 means the last tab (⌘9, per macOS convention).
    case activateTabIndex(Int)
    case nextTab
    case previousTab
    case nextWorkspace
    case previousWorkspace
    case newTab(in: String?)          // nil = the active workspace
    case newWorkspace(named: String)
    case closeTab(TabID?)             // nil = the active tab, panes and all
    case closePane(UInt32?)           // nil = the focused pane (⌘W)
    /// Take a workspace out of this window's list. Its sessions carry on and
    /// every other window keeps it — this is about what is to hand here, not
    /// about what exists.
    case removeWorkspace(String)
    case killWorkspace(String)
    case split(UInt8)                 // protocol values: 1 = right, 2 = down
    /// A surface took the keyboard. The tab travels with it: rebuilding an
    /// arrangement makes AppKit reassign the first responder, and a surface
    /// belonging to a hidden tab can pick it up — a report with no tab on it
    /// would be written to whichever tab happened to be active.
    case focusPane(TabID, UInt32)
    /// A pane's program renamed itself, reported by the surface showing it
    /// rather than found on the daemon's next listing. Titles are polled
    /// every two seconds and a program that spins one redraws it several
    /// times a second, so the poll only ever caught a still frame of it.
    case notePaneTitle(TabID, UInt32, String)
    /// A name somebody chose for a tab, over whatever its program calls it.
    /// nil, or nothing but spaces, gives the tab back to its program.
    ///
    /// A name for looking, kept by the app: the daemon addresses tabs by
    /// number and has never had a word for what they are called.
    case renameTab(TabID, to: String?)
    /// The same for a workspace, as it is shown. Only shown: the name the
    /// daemon, the CLI and every shell's KEEP_WORKSPACE know it by stays
    /// what it was, since that name is how all of them find it.
    case renameWorkspace(String, to: String?)
    case setSidebar(SidebarState)     // from the toggle or a divider drag
    /// Fold or unfold one workspace's tab list in this window's sidebar.
    case toggleDisclosure(String)
    /// Move a tab — panes and all — into another workspace, landing before
    /// the named tab there, or at the end when dropped on the group itself.
    case moveTab(TabID, to: String, before: UInt32?)
    /// Tabs move into the sidebar and the titlebar row steps aside — or back.
    case toggleVerticalTabs
    /// Open the picker, or put it away if it is already up: the key that
    /// summons it is the key that dismisses it.
    case togglePicker
    /// Same overlay, other question: what is in the history rather than
    /// where can I go. Scoped to the pane you are in, or across everything.
    case toggleSearch(global: Bool)
    case closePicker
    /// What was typed. Local filtering answers the "go to" list; searching
    /// history is a question only the daemon can answer.
    case setPickerQuery(String)
    /// Show what this row is; nil clears the preview.
    case previewPickerItem(String?)
    case choosePickerItem(String)
    /// ⌃D on a row: end what it points at.
    case dismissPickerItem(String)
    /// The same overlay, asking what you want *done* rather than where you
    /// want to be — or, on a catalog, which theme or face you want.
    ///
    /// Toggling: the list already up is the list this puts away, which is
    /// what makes ⌘⇧P both halves of the gesture.
    ///
    /// Appearance itself is not here. A theme is not session state — no
    /// window owns it, the daemon has never heard of it, and it outlives
    /// every tab — so it is set on `GhosttyApp` directly and only the closing
    /// of the overlay comes back through here.
    case togglePalette(PickerModel.Catalog)
    /// Put a tab's AI on another account — the chevron beside its title.
    /// `key` is what `keep-ia` is asked for (`claude:ordem`,
    /// `claude:<slot>`, `gpt:<name>`); `label` is what the menu called it.
    case chooseAccount(TabID, key: String, label: String)
    /// Sign in to another account of a service, in a new tab of this
    /// window's workspace — the usage footer's "+".
    case signIn(AIEngine)
}

/// Everything the palette can run.
///
/// A closed list rather than a scrape of the menu bar. The menu is built for
/// the mouse — it nests, it repeats itself, and half of it is AppKit's — and
/// a palette that mirrored it would inherit that shape. This is the set of
/// things worth typing three letters to reach.
enum Command: Hashable, CaseIterable {
    // Where things are.
    case toggleSidebar
    case toggleVerticalTabs
    case splitRight
    case splitDown
    case closePane
    case newWindow

    // What is running.
    case newTab
    case newWorkspace
    case closeTab
    case removeWorkspace
    case killWorkspace

    // How it looks.
    case chooseTheme
    case chooseFont
    case fontBigger
    case fontSmaller
    case fontReset
    case clearTheme

    /// The group it is listed under. Also what it is matched on, so `look`
    /// finds the theme commands without their titles having to say it.
    var group: String {
        switch self {
        case .toggleSidebar, .toggleVerticalTabs, .splitRight, .splitDown,
             .closePane, .newWindow:
            return "window"
        case .newTab, .newWorkspace, .closeTab, .removeWorkspace, .killWorkspace:
            return "workspace"
        case .chooseTheme, .chooseFont, .fontBigger, .fontSmaller, .fontReset,
             .clearTheme:
            return "appearance"
        }
    }

    var title: String {
        switch self {
        case .toggleSidebar: return "Toggle the sidebar"
        case .toggleVerticalTabs: return "Toggle vertical tabs"
        case .splitRight: return "Split right"
        case .splitDown: return "Split down"
        case .closePane: return "Close this pane"
        case .newWindow: return "New window"
        case .newTab: return "New tab"
        case .newWorkspace: return "New workspace…"
        case .closeTab: return "Close this tab"
        case .removeWorkspace: return "Remove this workspace from the window"
        case .killWorkspace: return "Kill this workspace"
        case .chooseTheme: return "Change the theme…"
        case .chooseFont: return "Change the font…"
        case .fontBigger: return "Bigger text"
        case .fontSmaller: return "Smaller text"
        case .fontReset: return "Reset the text size"
        case .clearTheme: return "Use the Ghostty config's own theme"
        }
    }

    var symbol: String {
        switch self {
        case .toggleSidebar: return "sidebar.left"
        case .toggleVerticalTabs: return "list.bullet.rectangle"
        case .splitRight: return "rectangle.split.2x1"
        case .splitDown: return "rectangle.split.1x2"
        case .closePane: return "xmark.rectangle"
        case .newWindow: return "macwindow.badge.plus"
        case .newTab: return "plus.rectangle"
        case .newWorkspace: return "folder.badge.plus"
        case .closeTab: return "xmark"
        case .removeWorkspace: return "eye.slash"
        case .killWorkspace: return "bolt.slash"
        case .chooseTheme: return "paintpalette"
        case .chooseFont: return "textformat"
        case .fontBigger: return "textformat.size.larger"
        case .fontSmaller: return "textformat.size.smaller"
        case .fontReset: return "arrow.counterclockwise"
        case .clearTheme: return "arrow.uturn.backward"
        }
    }

    /// The chord that does the same thing without the palette, as keys.
    var keys: [String] {
        switch self {
        case .toggleSidebar: return ["⌘", "B"]
        case .splitRight: return ["⌘", "D"]
        case .splitDown: return ["⇧", "⌘", "D"]
        case .closePane: return ["⌘", "W"]
        case .closeTab: return ["⇧", "⌘", "W"]
        case .newTab: return ["⌘", "T"]
        case .newWindow: return ["⇧", "⌘", "N"]
        // ⌘N belongs to the workspace, not the window: a workspace outlives
        // every window that ever showed it.
        case .newWorkspace: return ["⌘", "N"]
        // The two font commands advertise nothing. Ghostty binds its own
        // ⌘+ and ⌘− to a size it holds itself, which this would then argue
        // with on the next reload — so these are reachable from here and
        // nowhere else, and the row says so by saying nothing.
        default: return []
        }
    }

    /// Whether choosing it opens another list rather than doing something.
    var opens: PickerModel.Catalog? {
        switch self {
        case .chooseTheme: return .themes
        case .chooseFont: return .fonts
        default: return nil
        }
    }

    /// Said out loud in the row, because these do not undo.
    var isDestructive: Bool {
        switch self {
        case .killWorkspace, .closeTab, .closePane, .removeWorkspace: return true
        default: return false
        }
    }
}

/// The flat "go to" list.
///
/// Modelled on the picker this replaces, and on the reason its author gave
/// for it: you do not choose a session and then a window — you choose the
/// thing and land on it. So there is no hierarchy here. Everything running
/// is one row, most recently visited first, and below it the places to start
/// something new.
///
/// The view draws the two groups under headings, which is not a hierarchy
/// coming back: nothing is chosen twice and no row is behind another. It is
/// a heading over a run of rows, because a terminal you are returning to and
/// a folder you would start one in are different answers to the question and
/// were wearing the same row.
struct PickerModel: Hashable {
    /// Which question the overlay is asking. It is one overlay because it is
    /// one gesture — type, move, choose — and splitting it in two would mean
    /// two of everything to keep in step.
    /// A list a command opened, rather than one the palette starts on.
    enum Catalog: Hashable {
        case root
        case themes
        case fonts
    }

    enum Mode: Hashable {
        /// Filtering happens locally: the list is already in hand.
        case goTo
        /// What can be done, rather than where you can go. Also local: the
        /// list is a fact about this app, not about the daemon.
        case palette(Catalog)
        /// Every keystroke is a question for the daemon, which is the only
        /// one holding the history. `global` decides whether the question is
        /// about everything or only the pane in front of you.
        case search(global: Bool)
    }

    struct Item: Hashable, Identifiable {
        enum Kind: Hashable {
            /// A tab that exists, in some workspace.
            case running(TabID)
            /// A directory to open a new workspace in.
            case destination(path: String)
            /// A line of history: the tab it is in, and the pane of that
            /// tab that holds it. A hit is found by pane, and a pane is not a
            /// tab — going to one means opening its tab and focusing it.
            case hit(TabID, pane: UInt32, line: UInt32, fromEnd: UInt32)
            /// Something to do.
            case command(Command)
            /// A theme to wear, by name.
            case theme(String)
            /// A face to set the terminal in, by family name.
            case fontFamily(String)
        }
        let kind: Kind
        /// Whose row this is. Empty for a folder, which belongs to nobody yet.
        let workspace: String
        /// The left column, and the whole of the disambiguation: the
        /// workspace's name alone, `name/tail` when the tab sits somewhere
        /// inside it, or `name 2` when position is the only thing telling
        /// siblings apart. Empty for folders and search hits.
        ///
        /// One string rather than three fields because the row draws it as
        /// one column, and deciding what it says is the list's business, not
        /// the cell's.
        let context: String
        /// The row's own text: the tab's title, a folder's name, a matched
        /// line of history.
        let title: String
        /// A folder's parent path, or what the tab is doing.
        let detail: String
        /// What is holding the terminal — `claude`, `nvim`, `zsh`. Said out
        /// loud because a title is what a program decided to call itself,
        /// which may be nothing, and may be the same sentence in six tabs.
        let command: String
        /// Where the row is, on disk: a tab's working directory, or the
        /// folder a destination would open in. Empty for a line of history,
        /// and for a shell that has not reached a prompt to say.
        ///
        /// Carried rather than dug back out of `kind`, because a running
        /// tab's directory is a fact about the tab and the kind only names
        /// the tab.
        let path: String
        let busy: Bool
        /// When the tab last did anything. Nil for folders, for hits, and for
        /// a daemon too old to say.
        let lastActive: Date?
        var id: String {
            switch kind {
            case .running(let tab): return "run:\(tab)"
            case .destination(let path): return "dir:\(path)"
            case .hit(let tab, let pane, let line, _): return "hit:\(tab):\(pane):\(line)"
            case .command(let command): return "cmd:\(command)"
            case .theme(let name): return "theme:\(name)"
            case .fontFamily(let name): return "font:\(name)"
            }
        }
        /// A place to start something, rather than something already running.
        var isFolder: Bool {
            if case .destination = kind { return true }
            return false
        }
    }

    var mode: Mode
    /// Search only: what matched, so a row can mark it and a header can count.
    struct Match: Hashable {
        let range: Range<Int>       // byte range within the row's title
        let before: [String]
        let after: [String]
        let group: String           // "workspace › tab N"
    }
    var matches: [String: Match]
    /// Search only: nil while the daemon has not answered yet.
    var scopeLabel: String?
    var query: String
    var items: [Item]
    var previewOf: String?
    var previewText: String
}

/// Everything layer 6 needs to draw a frame. Pure values: views never appear
/// here — the UI resolves ids through the surface pool.
struct SessionSnapshot: Hashable {
    struct SidebarRow: Hashable, Identifiable {
        /// The daemon's name for it: the id, and what every intent carries.
        let name: String
        /// What it is shown as — `name`, unless somebody renamed it.
        let title: String
        let subtitle: String            // "3 tabs · running", kept for the tooltip
        let tabs: Int
        /// What is running here, one entry per busy pane. The title a busy
        /// pane wears, which is the command for shells that rename their
        /// window while one runs.
        let running: [String]
        /// Where the workspace is, as its active tab last said so.
        ///
        /// Taken from the tab's title rather than from the surface that is
        /// showing it, because a workspace nobody has opened yet has no
        /// surface and would have nothing to say — and the one row that
        /// most needs a word about itself is the one you have not been to.
        let place: String
        let dot: Dot
        /// How many of its tabs have Claude Code waiting on an answer. What
        /// the header says when the group is folded shut, since then the
        /// tabs cannot say it themselves.
        let needsYou: Int
        /// When the latest of them started waiting: the header's badge
        /// breathes for a while after that, as a tab's does.
        let needsYouSince: Date?
        /// Whether anything in here is at work: a command running in a
        /// shell, or Claude Code in the middle of a turn or waiting on work
        /// it handed off. Claude Code sitting at its prompt is a program that
        /// is running, and not work — every tab it is open in would
        /// otherwise be marked busy for as long as it stays open.
        let working: Bool
        let isActive: Bool
        /// The tabs themselves, for the sidebar that nests them under the
        /// workspace. Always carried — a handful of small values — and the
        /// `expanded` flag says whether the sidebar shows them.
        let tabRows: [SidebarTab]
        let expanded: Bool
        var id: String { name }
        enum Dot: Hashable { case empty, busy, attached, idle }
    }

    struct SidebarTab: Hashable, Identifiable {
        let id: TabID
        /// The tab's own title, with the busy marks its program wrote taken
        /// off — the row draws its own, and twice is once too many.
        let title: String
        /// What is running in there. Empty when nothing can say.
        let command: String
        /// At work rather than merely open: a Claude Code whose turn is over
        /// is not busy, however long it stays running. See `Session.isAtWork`.
        let busy: Bool
        let isActive: Bool
        /// Another window is showing it — the strip's ⧉, said vertically.
        let isElsewhere: Bool
        /// Claude Code's permission mode, when Claude Code is what runs here
        /// and it is in one worth a colour.
        let claudeMode: ClaudeMode?
        /// Where Claude Code's turn stands there, when it can be told.
        let claudeActivity: ClaudeActivity?
        /// When it started waiting on you, if it is: see `Attention`.
        let wantsYouSince: Date?
        /// The account its AI runs on, as `keep-ia` wrote it down
        /// (`AITabAccounts`): `claude:ordem`, `claude:<slot>`, `gpt:<name>`.
        /// Nil when no AI runs there.
        let account: String?
        /// Whether its AI and account can be chosen from here: `keep-ia`,
        /// the helper outside the app, is installed.
        let offersAccounts: Bool
    }

    struct StripItem: Hashable, Identifiable {
        let id: TabID
        let title: String               // resolved label, no markers
        let busy: Bool                  // strip renders ✳
        let hasPanes: Bool              // strip renders ⊞
        let isActive: Bool
        /// Some other window is showing this tab. The row still lists it —
        /// the row is the workspace's tabs, not this window's — so without
        /// saying so, a tab pulled out into a window of its own looks like a
        /// tab that never left.
        let isElsewhere: Bool
        /// As on the sidebar's row.
        let claudeMode: ClaudeMode?
        let claudeActivity: ClaudeActivity?
        let wantsYouSince: Date?
        /// What is running in there, the account its AI is on, and whether
        /// that can be chosen: as on the sidebar's row, for the chevron's
        /// menu.
        let command: String
        let account: String?
        let offersAccounts: Bool
    }

    struct ActiveTab: Hashable {
        let id: TabID
        let title: String               // window title
        let panes: [PaneState]          // beyond the root, daemon order
        let focusedPane: UInt32         // daemon tab id holding the keyboard
    }

    var sidebar: SidebarState
    /// Non-nil while the picker is open.
    var picker: PickerModel?
    var rows: [SidebarRow]
    var strip: [StripItem]
    var active: ActiveTab?
    /// Every live tab across all workspaces. The UI unmounts hosts whose id
    /// left this set; it never decides on its own that a tab is gone.
    var universe: Set<TabID>
}
