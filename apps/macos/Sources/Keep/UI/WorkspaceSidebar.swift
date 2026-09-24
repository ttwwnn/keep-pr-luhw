import SwiftUI

/// The workspace list.
///
/// Pure function of its rows: snapshot in, intents out. Navigation
/// deliberately does NOT hang off `List(selection:)` — that state belongs to
/// SwiftUI, which writes it for reasons that have nothing to do with intent (a
/// freshly revealed outline view takes focus and picks a row on its own), and
/// when selection drove navigation every one of those writes was a workspace
/// switch nobody asked for. Entering a workspace is a thing you do, so it
/// hangs off the button and nothing else.
///
/// Two rules decide how it looks, and both come from the app around it.
///
/// A workspace name is terminal content — it is a directory, it appears in
/// prompts and titles — so it is set in the face the terminal is set in, not
/// in the system face the app speaks its own labels in. That is the difference
/// between chrome bolted onto a terminal and chrome that belongs to one.
///
/// And colour carries information or it does not appear. The dot carries
/// state; the current row carries a wash in a hue derived from its own name,
/// so that selection is unmistakable without being the same blue every app
/// uses for it; a tab running Claude Code in one of its permission modes is
/// titled in the colour Claude Code prints that mode in. Nothing else in here
/// is coloured.
struct WorkspaceSidebar: View {
    @ObservedObject var model: SidebarRows
    let dispatch: (Intent) -> Void
    @State private var newName = ""
    @State private var hovered: String?
    /// A header's +, which brightens under the pointer. Apart from `hovered`,
    /// which the header itself sets while the pointer is anywhere on it.
    @State private var hoveredNewTab: String?
    /// The tab a drag is currently held over, keyed like `hovered`.
    @State private var dropTarget: String?
    /// The payload in flight. Set in `onDrag` and read from here everywhere:
    /// on macOS the item provider's contents cannot be read during the drag
    /// (loads are deferred until it ends), so the state IS the payload.
    @State private var dragged: String?
    /// The order in flight while a drag is over its own group. The snapshot
    /// is not touched until the drop commits; these are what the rows render
    /// from in the meantime, which is what lets the gap travel.
    @State private var liveTabOrder: LiveTabOrder?
    @State private var liveWorkspaceOrder: [String]?
    @FocusState private var fieldFocused: Bool
    /// The name being typed, if one is, and what the field opened on. The
    /// text lives here and never in the row: while Claude Code works, the
    /// title under the field changes several times a second, and a field
    /// bound to it would lose every keystroke to the next one.
    @State private var renaming: Renaming?
    @State private var renameText = ""
    @State private var renameSeed = ""
    /// Which name field holds the keyboard. Kept apart from the new-workspace
    /// field's, because losing it is how a click elsewhere ends a rename.
    @FocusState private var renameFocus: Renaming?
    /// The name under the pointer, as opposed to merely its row. A click on
    /// the chosen row renames only when it lands on the name, so a click
    /// beside it still hands the keyboard back to the terminal, as it always
    /// has.
    @State private var pointerOnName: Renaming?
    /// A rename waiting out the double-click interval, and the watch on the
    /// keyboard kept for as long as it waits.
    @State private var pendingRename: DispatchWorkItem?
    @State private var keyWatch: Any?
    /// What the last click in here landed on: a tab, a header, or nil for
    /// one of the small buttons on them. A double-click renames only what
    /// both of its clicks landed on. One whose first click closed a tab and
    /// whose second landed on the row that slid up into its place is two
    /// clicks on two things, whatever the click count says.
    @State private var lastClicked: Renaming?

    struct LiveTabOrder: Equatable {
        var workspace: String
        var roots: [UInt32]
    }

    /// What a name can be typed for. One at a time: a second rename begun
    /// while one is open ends the first, keeping what it says, as a click
    /// elsewhere would have.
    private enum Renaming: Hashable {
        case tab(TabID)
        case workspace(String)
    }

    private var rows: [SessionSnapshot.SidebarRow] { model.rows }

    /// The rows in the order being shown: the live one mid-drag, the
    /// snapshot's otherwise.
    private var shownRows: [SessionSnapshot.SidebarRow] {
        guard let order = liveWorkspaceOrder else { return rows }
        return order.compactMap { name in rows.first { $0.name == name } }
    }

    private func shownTabs(of row: SessionSnapshot.SidebarRow)
        -> [SessionSnapshot.SidebarTab]
    {
        guard let live = liveTabOrder, live.workspace == row.name else { return row.tabRows }
        return live.roots.compactMap { root in row.tabRows.first { $0.id.root == root } }
    }

    /// What the fold animation is keyed on: only the facts that change the
    /// list's geometry. Keyed on the whole snapshot, every title the poller
    /// touches would animate layout for no reason.
    private var shape: [String] {
        rows.map { row in
            "\(row.name)|\(row.expanded)|\(row.tabRows.map { String($0.id.root) }.joined(separator: ","))"
        }
    }

    private func cancelDrag() {
        dragged = nil
        liveTabOrder = nil
        liveWorkspaceOrder = nil
        dropTarget = nil
        // A press that turned into a drag was never a click on a name. The
        // button's action does not fire for a drag anyway; this covers a
        // click that was followed by one before its rename came due.
        disarmRename()
    }

    /// The terminal's own face, for the strings the terminal would also print.
    private var identifier: Font {
        Font(GhosttyApp.shared.terminalFont(size: 12.5))
    }

    private var counter: Font {
        Font(GhosttyApp.shared.terminalFont(size: 10.5))
    }

    var body: some View {
        // A scroll view over a plain stack, not a List. A List on macOS is an
        // NSTableView underneath, and inside its rows `.draggable` and
        // `.dropDestination` never fire — a tab could be pressed and pulled
        // and nothing anywhere would hear about it. The List earned its keep
        // while `.onMove` did the reordering; every drag is explicit now, and
        // the stack also retires the listRow* incantations the List needed.
        ScrollView {
            // An eager VStack, deliberately. The lazy one has a filed radar
            // for exactly this shape of update — a published array replaced
            // wholesale — and exit transitions cannot run on rows that were
            // never realised; at a sidebar's row count, eager is free.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shownRows) { row in
                    rowButton(row)
                }

                // Under the last workspace, not pinned to the floor. Starting
                // one is the next thing after the ones you have, and a row at
                // the bottom of a tall empty column reads as a different
                // control than the list it belongs to.
                newRow
            }
            .padding(.vertical, 6)
            // The fold's engine. An animation keyed on a value covers changes
            // that arrive from outside the view — the snapshot is replaced by
            // `render`, not mutated here — and keying it on the geometry
            // alone keeps the poller's title churn from animating layout.
            .animation(.easeOut(duration: 0.18), value: shape)
        }
        // A drop that ends on the sidebar's bare ground still ends: without
        // this, a tab dropped an inch below its group kept its ghost dimmed
        // and its mirror alive. (A drag cancelled with Esc has no signal at
        // all on macOS; the next drag's onDrag clears what it left.)
        .onDrop(of: [.plainText], delegate: CleanupDropDelegate(clear: cancelDrag))
        .onChange(of: model.rows) { _, new in
            // Mid-drag, the poller may replace the snapshot underneath the
            // mirror. The mirror survives — it is the truth of the gesture —
            // unless its group is gone, and then so is the gesture.
            guard dragged != nil else {
                liveTabOrder = nil
                liveWorkspaceOrder = nil
                return
            }
            if let live = liveTabOrder, !new.contains(where: { $0.name == live.workspace }) {
                cancelDrag()
            }
        }
        .onChange(of: model.rows) { _, new in
            // A name being typed outlives every snapshot that arrives in the
            // meantime, but not the thing it names. Gone — closed, moved
            // under a new id, taken out of this window — the edit is dropped
            // with it; folded out of sight, it is kept, as a click elsewhere
            // would have kept it.
            guard let target = renaming else { return }
            if title(of: target, in: new) == nil {
                endRename(saving: false, handingBack: true)
            } else if !isShown(target, in: new) {
                endRename(saving: true, handingBack: true)
            }
        }
        .onChange(of: renameFocus) { old, new in
            guard let editing = renaming else { return }
            if new == editing, old != editing {
                selectWholeName()
            } else if old == editing, new != editing {
                // Finder's rule: clicking away keeps what was typed. The
                // keyboard is already wherever the click put it, and stays
                // there. Session hands it to the terminal whenever a name is
                // kept, and a field the click moved to, the picker's or a new
                // workspace's, would be left open with nothing reaching it
                // and what was typed next going to the shell.
                let taker = fieldHoldingKeyboard()
                endRename(saving: true, handingBack: false)
                if let taker { giveKeyboardBack(to: taker) }
            }
        }
    }

    /// One list row per workspace: the workspace button, and under it the
    /// tabs it holds. One row and not several, because `.onMove` counts list
    /// rows and the reorder must keep counting workspaces.
    private func rowButton(_ row: SessionSnapshot.SidebarRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if renaming == .workspace(row.name) {
                workspaceEditor(row)
            } else {
                workspaceButton(row)
            }
            if row.expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shownTabs(of: row)) { tab in
                        if renaming == .tab(tab.id) {
                            tabEditor(tab, in: row)
                        } else {
                            tabButton(tab, in: row)
                        }
                    }
                }
                // Under the header, on their way in and out — which with the
                // clip below reads as sliding from beneath it rather than
                // materialising over the neighbours.
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(-1)
            }
        }
        .clipped()
        .padding(.horizontal, 5)
    }

    /// The workspace, as a plain header: the name, and a + and the fold at the
    /// far end. Everything the old card said — the dot, what is running, the
    /// count, the path — now belongs to the rows beneath it or to the
    /// tooltip; a header that repeats its children is twice the reading for
    /// the same news.
    private func workspaceButton(_ row: SessionSnapshot.SidebarRow) -> some View {
        Button {
            clickHeader(row)
        } label: {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(identifier)
                    .foregroundStyle(
                        row.isActive
                            ? Palette.ink
                            : hovered == row.name ? Palette.inkResting : Palette.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onHover { inside in notePointer(inside, onNameOf: .workspace(row.name)) }
                if row.dot == .busy {
                    // The one fact worth carrying up from the tabs: something
                    // is running in here, visible with the group folded shut.
                    Text("✳")
                        .font(counter)
                        .foregroundStyle(Palette.busy)
                }
                Spacer(minLength: 8)
                // The +'s room, kept here so the fold stays at the far end.
                Color.clear.frame(width: 10, height: 1)
                disclosure(row)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Over the header and not inside its label, for the reason the tab's
        // × is: a button inside a button hands its clicks to whichever of the
        // two SwiftUI prefers, and a + that also entered the workspace would
        // be two things at once. Padded as the label is, so the two sit on
        // one line; in from the edge by the label's inset, the fold's width
        // and the gap between them.
        .overlay(alignment: .trailing) {
            newTabButton(row)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .padding(.trailing, 12 + 10 + 8)
        }
        .help(tooltip(for: row))
        // Dragging a header rearranges the workspaces. This replaces the
        // List's own `.onMove`, which claimed every drag that started
        // anywhere in the row — the nested tabs included, which is how tab
        // drags did nothing at all. One mechanism for both kinds of row,
        // told apart by the payload.
        .onDrag {
            // A new drag first clears whatever a cancelled one left behind.
            cancelDrag()
            let payload = "ws\u{1F}\(row.name)"
            dragged = payload
            liveWorkspaceOrder = rows.map(\.name)
            // A real type, not an empty provider: on macOS an empty one
            // never engages a drop at all.
            return NSItemProvider(object: payload as NSString)
        }
        .onDrop(of: [.plainText], delegate: HeaderDropDelegate(
            target: row.name,
            dragged: $dragged,
            liveOrder: $liveWorkspaceOrder,
            commitOrder: { order in commitWorkspaceOrder(order) },
            moveTabHere: { id in dispatch(.moveTab(id, to: row.name, before: nil)) },
            clear: cancelDrag))
        .opacity(dragged == "ws\u{1F}\(row.name)" ? 0.4 : 1)
        .onHover { inside in
            hovered = inside ? row.name : (hovered == row.name ? nil : hovered)
        }
        .contextMenu {
            Button("New Tab") { dispatch(.newTab(in: row.name)) }
            Button("Rename Workspace…") { beginRename(.workspace(row.name)) }
            Divider()
            // Also in the menu, not only under the pointer. A list you can
            // only rearrange by dragging is a list most people never learn
            // can be rearranged.
            Button("Move Up") { move(row, by: -1) }
                .disabled(index(of: row) == 0)
            Button("Move Down") { move(row, by: 1) }
                .disabled(index(of: row) == rows.count - 1)
            Divider()
            // Two names, because the two consequences are nothing alike.
            // One tidies this window's list and leaves the work running; the
            // other ends the work, everywhere.
            Button("Remove from This Window") {
                dispatch(.removeWorkspace(row.name))
            }
            Button("Close Workspace", role: .destructive) {
                dispatch(.killWorkspace(row.name))
            }
        }
    }

    /// The fold. Its own button, not part of the workspace's: a chevron that
    /// also entered the workspace would make looking cost a switch.
    ///
    /// Shown only when there is something to fold — and replaced by a spacer
    /// otherwise, so every name in the column starts at the same x.
    @ViewBuilder
    private func disclosure(_ row: SessionSnapshot.SidebarRow) -> some View {
        if row.tabRows.count > 0 {
            Button {
                lastClicked = nil
                dispatch(.toggleDisclosure(row.name))
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.inkFaint)
                    .rotationEffect(.degrees(row.expanded ? 90 : 0))
                    .frame(width: 10)
                    .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.14), value: row.expanded)
        } else {
            Spacer().frame(width: 10)
        }
    }

    /// A new tab in this workspace, beside the fold. One on every header
    /// rather than one at the end of the strip: a new tab always lands in
    /// some workspace, and a + on the header says which without the workspace
    /// having to be entered first. There on a header with nothing to fold as
    /// well, beside the fold's empty room, so every + in the column sits at
    /// the same x.
    private func newTabButton(_ row: SessionSnapshot.SidebarRow) -> some View {
        Button {
            lastClicked = nil
            dispatch(.newTab(in: row.name))
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hoveredNewTab == row.name ? Palette.inkResting : Palette.inkFaint)
                .frame(width: 10)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .help("New Tab in \(row.title)")
        .onHover { inside in
            hoveredNewTab = inside ? row.name : (hoveredNewTab == row.name ? nil : hoveredNewTab)
        }
    }

    /// The header while its name is being typed. The same geometry as the
    /// button it stands in for, so the name does not move when the field
    /// takes over — but not a button, and not draggable: a field inside a
    /// button's label loses its clicks to the button, and a header that drags
    /// would turn selecting text with the pointer into moving the workspace.
    ///
    /// The field's prompt is the workspace's own name, which is what an empty
    /// field gives back.
    private func workspaceEditor(_ row: SessionSnapshot.SidebarRow) -> some View {
        HStack(spacing: 8) {
            nameField(for: .workspace(row.name), prompt: row.name)
                .font(identifier)
                .background(
                    Capsule(style: .continuous)
                        .fill(Palette.wash(0.09))
                        .padding(.horizontal, -8)
                        .padding(.vertical, -3))
            Spacer(minLength: 8)
            newTabButton(row)
            disclosure(row)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// One tab, under its workspace, wearing the strip's own clothes: the
    /// chosen one is a glass capsule, the others are bare text that brightens
    /// under the pointer, ✳ while busy, ⧉ when another window is showing it.
    /// The same tab in two places should look like the same tab.
    private func tabButton(_ tab: SessionSnapshot.SidebarTab, in row: SessionSnapshot.SidebarRow)
        -> some View
    {
        let chosen = tab.isActive && row.isActive
        let hoveredHere = hovered == tabHoverKey(tab) || dropTarget == tabHoverKey(tab)
        return Button {
            clickTab(tab, chosen: chosen)
        } label: {
            HStack(spacing: 6) {
                // The title arrives with the marks its program wrote already
                // stripped — programs that title themselves with this same ✳,
                // as Claude Code does, were showing it twice — so the row
                // draws the one mark, and it is this one.
                if tab.busy {
                    Text("✳")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.busy)
                }
                Text(tab.title)
                    .font(.system(size: 12, weight: chosen ? .medium : .regular))
                    .foregroundStyle(titleInk(for: tab, chosen: chosen, hovered: hoveredHere))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The title gives before the program's name does: a title
                    // is what something calls itself and may be a sentence,
                    // or may be six tabs saying the same sentence, while the
                    // name is the word that tells you what the tab is.
                    .layoutPriority(-1)
                    .onHover { inside in notePointer(inside, onNameOf: .tab(tab.id)) }
                if !tab.command.isEmpty {
                    Text("— \(tab.command)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if tab.isElsewhere {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.inkFaint)
                }
                Spacer(minLength: 0)
                // The close button's room, kept whether or not it is showing,
                // so a title does not reflow as the pointer passes over it.
                Color.clear.frame(width: 12, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(capsule(chosen: chosen, hovered: hoveredHere))
        }
        .buttonStyle(.plain)
        // Laid over the row rather than inside its label: a button inside a
        // button hands its clicks to whichever of the two SwiftUI prefers.
        .overlay(alignment: .trailing) {
            closeButton(tab, visible: hoveredHere && dragged == nil)
                .padding(.trailing, 9)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        // The same drag the strip has, vertically — and live: while the drag
        // is over its own group the other rows open a path in real time, the
        // dragged one travelling as a dimmed ghost, and the drop commits the
        // order the gap already shows. Dropped in another group, the tab
        // moves there, shells and panes intact.
        .onDrag {
            cancelDrag()
            let payload = "tab\u{1F}\(row.name)\u{1F}\(tab.id.root)"
            dragged = payload
            liveTabOrder = LiveTabOrder(
                workspace: row.name, roots: row.tabRows.map(\.id.root))
            return NSItemProvider(object: payload as NSString)
        }
        .onDrop(of: [.plainText], delegate: TabDropDelegate(
            workspace: row.name,
            targetRoot: tab.id.root,
            targetKey: tabHoverKey(tab),
            dragged: $dragged,
            liveOrder: $liveTabOrder,
            dropTarget: $dropTarget,
            commitOrder: { roots in
                Trace.log("sidebar", "reorder committed in \(row.name): \(roots)")
                dispatch(.reorderTabs(roots, in: row.name))
            },
            moveTabHere: { id in
                Trace.log("sidebar", "moved \(id) into \(row.name)")
                dispatch(.moveTab(id, to: row.name, before: tab.id.root))
            },
            clear: cancelDrag))
        .opacity(dragged == "tab\u{1F}\(row.name)\u{1F}\(tab.id.root)" ? 0.4 : 1)
        .onHover { inside in
            let key = tabHoverKey(tab)
            hovered = inside ? key : (hovered == key ? nil : hovered)
        }
        .contextMenu {
            Button("Rename Tab…") { beginRename(.tab(tab.id)) }
            Divider()
            Button("Close Tab", role: .destructive) { dispatch(.closeTab(tab.id)) }
        }
    }

    /// A tab's row while its name is being typed: the button's geometry
    /// without the button, for the reasons the header's editor gives. The
    /// program's name and the ⧉ step aside for the field; the ✳ stays, since
    /// it sits before the name and moving it would move the text.
    private func tabEditor(_ tab: SessionSnapshot.SidebarTab, in row: SessionSnapshot.SidebarRow)
        -> some View
    {
        let chosen = tab.isActive && row.isActive
        return HStack(spacing: 6) {
            if tab.busy {
                Text("✳")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.busy)
            }
            nameField(for: .tab(tab.id), prompt: "The program's title")
                .font(.system(size: 12, weight: chosen ? .medium : .regular))
            // The close button's room, as on the row.
            Color.clear.frame(width: 12, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background {
            if chosen {
                GlassRow(cornerRadius: 13, tint: Palette.litRow)
            } else {
                // The new-workspace field's wash while it is typed in.
                Capsule(style: .continuous).fill(Palette.wash(0.09))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }

    /// Where a name is typed, for a tab or a workspace alike.
    ///
    /// Return keeps it and Esc takes it back; either way the keyboard goes
    /// back to the terminal, since that is where it was before the name was
    /// clicked.
    private func nameField(for target: Renaming, prompt: String) -> some View {
        // Each field ends only its own edit: by the time a field on its way
        // out reports anything, the edit open may be another one.
        let end = { (saving: Bool) in
            guard renaming == target else { return }
            endRename(saving: saving, handingBack: true)
        }
        return TextField(prompt, text: $renameText)
            .textFieldStyle(.plain)
            .foregroundStyle(Palette.ink)
            .focused($renameFocus, equals: target)
            .onSubmit {
                // A turn later. A field can also report a submit as it gives
                // up the keyboard, in the middle of the window handing it to
                // whatever was clicked, and handing the keyboard back from
                // inside that hand-over would fight it. A turn later the click
                // has landed, and a return is none the worse for the wait.
                DispatchQueue.main.async { end(true) }
            }
            // Esc is listened for twice. A field's keys go to AppKit's field
            // editor first and reach SwiftUI by one road or the other; ending
            // twice is harmless, since the second finds nothing open.
            .onExitCommand { end(false) }
            .onKeyPress(.escape) {
                end(false)
                return .handled
            }
            .onAppear {
                // A turn later: the field has to be in the window before it
                // can be handed the keyboard, and asked for in the same
                // update that inserts it, the request finds nothing to focus.
                DispatchQueue.main.async {
                    guard renaming == target else { return }
                    renameFocus = target
                }
            }
    }

    /// The row's ×: there under the pointer, gone otherwise, the way the
    /// strip's own tabs offer it.
    private func closeButton(_ tab: SessionSnapshot.SidebarTab, visible: Bool) -> some View {
        Button {
            lastClicked = nil
            dispatch(.closeTab(tab.id))
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Palette.inkResting)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Palette.wash(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close Tab")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.12), value: visible)
    }

    /// A tab's title in the colour of the mode Claude Code is in there, when
    /// it is in one it colours — the colour its own footer prints the mode
    /// in, so the list and the screen say it the same way, and a tab left in
    /// bypass is plain from across the list. Otherwise the ink the row's
    /// state gives it. Only the ink: weight and capsule still say which tab
    /// is the chosen one.
    private func titleInk(for tab: SessionSnapshot.SidebarTab, chosen: Bool, hovered: Bool)
        -> Color
    {
        if let mode = tab.claudeMode { return Color(nsColor: mode.dynamicColor) }
        return chosen ? Palette.ink : hovered ? Palette.inkResting : Palette.inkFaint
    }

    /// A click on a tab. A double-click renames it, and so does a single
    /// click on the name of the tab already chosen, the way Finder renames
    /// the file already selected; anything else enters it, as it always did.
    private func clickTab(_ tab: SessionSnapshot.SidebarTab, chosen: Bool) {
        let target = Renaming.tab(tab.id)
        let again = lastClicked == target
        lastClicked = target
        disarmRename()
        if isSecondClick && again {
            // Not dispatched. Entering a tab hands the keyboard to the
            // terminal, which would take it straight back off the field this
            // is about to open — and the first click of the pair has already
            // done the entering.
            beginRename(target)
            return
        }
        if chosen && pointerOnName == target { armRename(target) }
        dispatch(.activateTab(tab.id))
    }

    /// The same for a header, whose name is the workspace's.
    private func clickHeader(_ row: SessionSnapshot.SidebarRow) {
        let target = Renaming.workspace(row.name)
        let again = lastClicked == target
        lastClicked = target
        disarmRename()
        if isSecondClick && again {
            beginRename(target)
            return
        }
        if row.isActive && pointerOnName == target { armRename(target) }
        dispatch(.activateWorkspace(row.name))
    }

    /// Whether the click being answered is the second of a double-click, read
    /// off the event: its count is the window server's, measured when the
    /// clicks happened rather than when a main thread busy with a switch got
    /// round to them. Only a mouse event is asked — a button can be pressed
    /// from the keyboard too, and any other event asked for a click count
    /// raises.
    private var isSecondClick: Bool {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown
        else { return false }
        return event.clickCount >= 2
    }

    private func notePointer(_ inside: Bool, onNameOf target: Renaming) {
        if inside {
            pointerOnName = target
        } else if pointerOnName == target {
            pointerOnName = nil
            // Moving off the name is moving on: a rename still waiting for
            // its interval to pass would open under a pointer that has left.
            disarmRename()
        }
    }

    /// Finder's slow click: the chosen item's name, clicked once, opens for
    /// typing once the double-click interval has passed with no second click.
    /// Waiting is what keeps the first half of a double-click from being
    /// taken for a single one.
    private func armRename(_ target: Renaming) {
        let work = DispatchWorkItem {
            disarmRename()
            // Still the chosen one: a switch in the meantime has moved on.
            guard isChosen(target) else { return }
            beginRename(target)
        }
        pendingRename = work
        // A key pressed while it waits calls it off, as it does in Finder.
        // The click has already handed the keyboard to the terminal, the way
        // a click on the current row always has, and whoever types straight
        // after it is typing a command. A field opening halfway through would
        // take the rest of the command, and the return after it.
        keyWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            disarmRename()
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// Call off a rename that is waiting, and stop watching the keyboard
    /// for it.
    private func disarmRename() {
        pendingRename?.cancel()
        pendingRename = nil
        if let keyWatch { NSEvent.removeMonitor(keyWatch) }
        keyWatch = nil
    }

    /// Open the field on what the thing is called now — the title as shown,
    /// its program's busy marks already off it.
    private func beginRename(_ target: Renaming) {
        disarmRename()
        guard renaming != target, let seed = title(of: target, in: rows) else { return }
        endRename(saving: true, handingBack: false)
        Trace.log("sidebar", "renaming \(target)")
        renameSeed = seed
        renameText = seed
        pointerOnName = nil
        renaming = target
    }

    /// Close the field. `saving` is false for Esc and for a thing that has
    /// gone; `handingBack` is false after a blur, which has already put the
    /// keyboard wherever the click went.
    ///
    /// A name that comes back the way it went out is not saved. The field
    /// opens on what the thing is called at the moment, for a tab usually its
    /// program's title, and saving that would pin the title as it stood and
    /// stop following the program — all for a return pressed out of habit.
    private func endRename(saving: Bool, handingBack: Bool) {
        guard let target = renaming else { return }
        let typed = renameText
        let changed = saving
            && title(of: target, in: rows) != nil
            && typed.trimmingCharacters(in: .whitespacesAndNewlines)
                != renameSeed.trimmingCharacters(in: .whitespacesAndNewlines)
        // The field's focus is not cleared here. Taking the field out clears
        // it, and quietly. Cleared by hand, it is applied on SwiftUI's next
        // update by resigning the keyboard outright, and by then the keyboard
        // is the terminal's, handed over below in this same turn: the
        // window itself would hold it, and every key would beep.
        renaming = nil
        pointerOnName = nil
        disarmRename()
        guard changed else {
            if handingBack { returnKeyboard() }
            return
        }
        // Session hands the keyboard back itself once a name is kept.
        switch target {
        case .tab(let id):
            dispatch(.renameTab(id, to: typed))
        case .workspace(let name):
            dispatch(.renameWorkspace(name, to: typed))
        }
    }

    /// The keyboard back to the terminal with nothing renamed. Session hands
    /// it over only as part of an intent, and the intent that changes nothing
    /// is entering the tab this window already shows — what a click on the
    /// current row has always done.
    private func returnKeyboard() {
        guard let shown = rows.lazy.flatMap(\.tabRows).first(where: \.isActive) else { return }
        dispatch(.activateTab(shown.id))
    }

    /// The text field typing currently goes to, if it goes to one, and where
    /// its caret stands. Read off the field editor, since that is what holds
    /// the keyboard for whichever field is being typed in.
    private func fieldHoldingKeyboard() -> (field: NSView, selection: [NSValue])? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.isFieldEditor,
              let field = editor.delegate as? NSView
        else { return nil }
        return (field, editor.selectedRanges)
    }

    /// The keyboard back to a field it was taken from, with the caret where
    /// it stood. Only if it was taken: asked again, a field that still has it
    /// starts its editing over and selects everything in it, and so does one
    /// that gets it back, which is why the caret is put back by hand.
    private func giveKeyboardBack(to taker: (field: NSView, selection: [NSValue])) {
        guard fieldHoldingKeyboard()?.field !== taker.field,
              let window = taker.field.window,
              window.makeFirstResponder(taker.field),
              let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor
        else { return }
        editor.selectedRanges = taker.selection
    }

    /// The whole name selected, so the first keystroke replaces it and an
    /// arrow keeps it. Asked for rather than left to however the field came
    /// by the keyboard; and asked only of a field editor, since the same
    /// message to a terminal would select its screen.
    private func selectWholeName() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.isFieldEditor
            else { return }
            editor.selectAll(nil)
        }
    }

    /// What the thing is shown as, or nil when it is no longer in the list.
    private func title(of target: Renaming, in rows: [SessionSnapshot.SidebarRow]) -> String? {
        switch target {
        case .tab(let id):
            return rows.first { $0.name == id.workspace }?.tabRows.first { $0.id == id }?.title
        case .workspace(let name):
            return rows.first { $0.name == name }?.title
        }
    }

    /// Whether its row is on screen: a tab's is not while its group is
    /// folded.
    private func isShown(_ target: Renaming, in rows: [SessionSnapshot.SidebarRow]) -> Bool {
        switch target {
        case .tab(let id):
            return rows.first { $0.name == id.workspace }?.expanded ?? false
        case .workspace(let name):
            return rows.contains { $0.name == name }
        }
    }

    /// Whether it is the one this window is in: the tab it shows, or the
    /// workspace that tab belongs to.
    private func isChosen(_ target: Renaming) -> Bool {
        switch target {
        case .tab(let id):
            guard let row = rows.first(where: { $0.name == id.workspace }) else { return false }
            return row.isActive && row.tabRows.contains { $0.id == id && $0.isActive }
        case .workspace(let name):
            return rows.first { $0.name == name }?.isActive ?? false
        }
    }

    /// Commit a header drag: the mirror is the final order, and the intent
    /// speaks in offsets, so the one moved name is translated into the move
    /// that produces that order.
    private func commitWorkspaceOrder(_ order: [String]) {
        guard order != rows.map(\.name),
              let payload = dragged,
              let part = payload.split(separator: "\u{1F}").last
        else { return }
        let name = String(part)
        guard let from = rows.firstIndex(where: { $0.name == name }),
              let to = order.firstIndex(of: name)
        else { return }
        // `move(fromOffsets:toOffset:)` counts the destination in the list
        // as it was before the row left it: going down, one past the slot.
        dispatch(.reorderWorkspaces(from: [from], to: from < to ? to + 1 : to))
    }

    /// The strip's capsule, vertically: glass for the tab being shown, a
    /// breath of white under the pointer, nothing otherwise.
    @ViewBuilder
    private func capsule(chosen: Bool, hovered: Bool) -> some View {
        if chosen {
            GlassRow(cornerRadius: 13, tint: Palette.litRow)
        } else if hovered {
            Capsule(style: .continuous).fill(Palette.wash(0.055))
        }
    }

    /// Hover state shares one string field with the workspace rows; a tab's
    /// key must not collide with a workspace named like it.
    private func tabHoverKey(_ tab: SessionSnapshot.SidebarTab) -> String {
        "tab:\(tab.id.workspace)/\(tab.id.root)"
    }

    /// Everything running here, one per line, or what the workspace is
    /// otherwise. The row shows one; this is where the rest live.
    ///
    /// A workspace shown under a name somebody gave it leads with the name it
    /// still answers to, since `keep` and every shell's KEEP_WORKSPACE know
    /// it by that one and the header no longer says it.
    private func tooltip(for row: SessionSnapshot.SidebarRow) -> String {
        let known = row.title == row.name ? [] : [row.name]
        guard !row.running.isEmpty else { return (known + [row.subtitle]).joined(separator: "\n") }
        let heading = row.running.count == 1
            ? "1 running"
            : "\(row.running.count) running"
        return (known + [heading] + row.running.map { "· \($0)" }).joined(separator: "\n")
    }

    private func index(of row: SessionSnapshot.SidebarRow) -> Int {
        rows.firstIndex(where: { $0.name == row.name }) ?? 0
    }

    /// One place up or down.
    ///
    /// `move(fromOffsets:toOffset:)` counts the destination in the list as it
    /// was before the row left it, so going down one lands two along.
    private func move(_ row: SessionSnapshot.SidebarRow, by step: Int) {
        let from = index(of: row)
        let to = step < 0 ? from - 1 : from + 2
        guard from + step >= 0, from + step < rows.count else { return }
        dispatch(.reorderWorkspaces(from: [from], to: to))
    }

    /// The current row is glass, lit in its own colour. Everything else is
    /// the ground it sits on, or a breath of white under the pointer.
    ///
    /// Glass rather than a painted rectangle because that is what the rest of
    /// this window's controls are made of, and a sidebar whose selection is
    /// the only flat thing in the app reads as a part that was made
    /// separately. Only the current row gets one: a pane of glass per row,
    /// appearing and disappearing on hover, is a lot of glass for a highlight
    /// that means "the pointer is here".
    @ViewBuilder
    private func rowBackground(for row: SessionSnapshot.SidebarRow) -> some View {
        if row.isActive {
            GlassRow(cornerRadius: 12, tint: Palette.litRow)
        } else if hovered == row.name {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.wash(0.055))
        }
    }

    /// Starting one: the same shape as the workspaces above it, because it
    /// does the same kind of thing.
    ///
    /// One affordance, not a field beside a button: typing a name and
    /// pressing return is the whole gesture, and the plus is there for the
    /// people who look for a plus. It stays unoutlined until you are typing
    /// in it — a box around an empty field competes with the list, and it was
    /// the only thing in here outlined all the time. What you type becomes a
    /// workspace name, so it is set in the face names are set in.
    private var newRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(fieldFocused ? Palette.inkResting : Palette.inkFaint)
                .frame(width: 7)
            TextField(rows.isEmpty ? "Name your first workspace" : "New workspace", text: $newName)
                .textFieldStyle(.plain)
                .font(identifier)
                .foregroundStyle(Palette.inkResting)
                .focused($fieldFocused)
                .onSubmit(create)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fieldFocused ? Palette.wash(0.09) : .clear)
        )
        .animation(.easeOut(duration: 0.16), value: fieldFocused)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = true }
    }

    private func create() {
        dispatch(.newWorkspace(named: newName))
        newName = ""
    }
}

/// How a workspace is doing, in colour and in shape.
///
/// Both, deliberately: hue alone is a thing not everyone can read, so a filled
/// dot means something is watching this workspace and a hollow one means
/// nothing is.
/// The live half of a tab drag.
///
/// `dropEntered` fires as the drag crosses each row, and that is where the
/// path opens: the mirror order moves inside an animation, the rows render
/// from the mirror, and the gap travels with the pointer — the strip's
/// `settle()`, said in SwiftUI. The drop then commits an order the eye has
/// already seen.
///
/// Everything reads the dragged payload from bound state, never from the
/// item provider: macOS defers provider loads until the drag is over, so
/// mid-drag the provider is a promise and the state is the fact.
private struct TabDropDelegate: DropDelegate {
    let workspace: String
    let targetRoot: UInt32
    let targetKey: String
    @Binding var dragged: String?
    @Binding var liveOrder: WorkspaceSidebar.LiveTabOrder?
    @Binding var dropTarget: String?
    let commitOrder: ([UInt32]) -> Void
    let moveTabHere: (TabID) -> Void
    let clear: () -> Void

    private func draggedTab() -> (workspace: String, root: UInt32)? {
        guard let payload = dragged else { return nil }
        let parts = payload.split(separator: "\u{1F}")
        guard parts.count == 3, parts[0] == "tab", let root = UInt32(parts[2])
        else { return nil }
        return (String(parts[1]), root)
    }

    func dropEntered(info: DropInfo) {
        guard let tab = draggedTab() else { return }
        if tab.workspace == workspace, var live = liveOrder, live.workspace == workspace {
            guard let from = live.roots.firstIndex(of: tab.root),
                  let to = live.roots.firstIndex(of: targetRoot), from != to
            else { return }
            live.roots.move(
                fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            withAnimation(.easeOut(duration: 0.14)) { liveOrder = live }
        } else if tab.workspace != workspace {
            // Another group's tab: no shared order to open, so the target
            // lights instead — the same highlight the pointer earns.
            dropTarget = targetKey
        }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == targetKey { dropTarget = nil }
    }

    /// `.move`, or macOS shows a copy cursor for the whole gesture.
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { clear() }
        guard let tab = draggedTab() else { return false }
        if tab.workspace == workspace {
            if let live = liveOrder, live.workspace == workspace {
                commitOrder(live.roots)
            }
        } else {
            moveTabHere(TabID(workspace: tab.workspace, root: tab.root))
        }
        return true
    }
}

/// The same, for the headers: a header drag slides the other groups aside as
/// it passes, and a tab from another group dropped on a header joins it.
private struct HeaderDropDelegate: DropDelegate {
    let target: String
    @Binding var dragged: String?
    @Binding var liveOrder: [String]?
    let commitOrder: ([String]) -> Void
    let moveTabHere: (TabID) -> Void
    let clear: () -> Void

    func dropEntered(info: DropInfo) {
        guard let payload = dragged else { return }
        let parts = payload.split(separator: "\u{1F}")
        guard parts.count == 2, parts[0] == "ws", parts[1] != target,
              var order = liveOrder,
              let from = order.firstIndex(of: String(parts[1])),
              let to = order.firstIndex(of: target), from != to
        else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.easeOut(duration: 0.14)) { liveOrder = order }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { clear() }
        guard let payload = dragged else { return false }
        let parts = payload.split(separator: "\u{1F}")
        if parts.count == 2, parts[0] == "ws" {
            if let order = liveOrder { commitOrder(order) }
            return true
        }
        if parts.count == 3, parts[0] == "tab", let root = UInt32(parts[2]),
           parts[1] != target
        {
            moveTabHere(TabID(workspace: String(parts[1]), root: root))
            return true
        }
        return false
    }
}

/// The net under everything: a drop that ends on the sidebar's bare ground —
/// or a gesture macOS never reports the end of — must not leave a dimmed
/// ghost and a live mirror behind.
private struct CleanupDropDelegate: DropDelegate {
    let clear: () -> Void
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        clear()
        return true
    }
}

private struct StateDot: View {
    let state: SessionSnapshot.SidebarRow.Dot

    var body: some View {
        Group {
            switch state {
            case .attached:
                Circle().fill(Palette.attached)
            case .busy:
                Circle().fill(Palette.busy)
            case .idle:
                Circle().strokeBorder(Palette.idle, lineWidth: 1.5)
            case .empty:
                Circle().strokeBorder(Palette.inkFaint, lineWidth: 1.5)
            }
        }
        .frame(width: 7, height: 7)
    }
}

/// The colours this sidebar is allowed to use, and where they come from.
///
/// Ink and washes are dynamic: they were white-on-dark constants, and in the
/// light theme white ink on a light sidebar is a list you cannot read. The
/// primary colour resolves per appearance; the washes flip with it, since a
/// breath of white means nothing on white.
private enum Palette {
    /// White in the dark appearance, near-black in the light one — resolved
    /// when drawn, so a theme flip repaints without anyone being told.
    ///
    /// Two alphas, not one: black on a pale ground loses contrast faster
    /// than white on a dark one, so the same transparency that reads as
    /// "resting" in the dark reads as "disabled" in the light. The light
    /// side runs a step more opaque across the board.
    private static func ink(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(dark)
                : NSColor.black.withAlphaComponent(light)
        })
    }

    static let ink = ink(dark: 0.96, light: 0.92)
    static let inkResting = ink(dark: 0.60, light: 0.75)
    static let inkFaint = ink(dark: 0.38, light: 0.55)

    /// The hover and focus washes: light lifts a dark ground, shade settles
    /// on a light one.
    static func wash(_ alpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(alpha)
                : NSColor.black.withAlphaComponent(alpha)
        })
    }

    /// The state hues keep their hue and trade lightness with the ground:
    /// bright pigments read on a dark sidebar and wash out on a light one, so
    /// the light appearance gets the same colours a step darker.
    private static func state(_ lightness: Double, _ chroma: Double, _ hue: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? OKLCH.appKitColor(lightness, chroma, hue)
                : OKLCH.appKitColor(lightness - 0.22, chroma, hue)
        })
    }

    static let attached = state(0.76, 0.14, 150)
    static let busy = state(0.82, 0.15, 85)
    static let idle = state(0.70, 0.05, 250)

    /// The wash behind the current workspace, in a hue that is that
    /// workspace's own.
    ///
    /// Selection is the one place the product register lets an accent go, and
    /// fixing it to a single blue is what makes every tool's sidebar the same
    /// sidebar. Deriving it from the name instead gives a workspace a colour
    /// it keeps across sessions, at no cost in information: the hue says
    /// which, the wash says current.
    ///
    /// Twelve hues rather than three hundred and sixty, because near-misses
    /// are the ugly case. Two names landing eleven degrees apart read as one
    /// colour mixed badly; two names landing on the same anchor read as the
    /// same colour, which is honest. Sharing is common with few workspaces and
    /// costs nothing: only the current row is washed, so two washes are never
    /// on screen together to be compared.
    static let litRow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.30)
            : NSColor.black.withAlphaComponent(0.14)
    }
}

/// A pane of the window's own glass, behind a SwiftUI row.
///
/// SwiftUI has no glass in this SDK — the module interface has no
/// `glassEffect` in it — so the row borrows the same `NSGlassEffectView` the
/// tab strip and the chrome buttons are built from. Bridged rather than
/// imitated: an imitation would drift away from the real thing the first time
/// the system changed what glass looks like.
private struct GlassRow: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tint: NSColor

    func makeNSView(context: Context) -> NSView {
        AdaptiveLozengeView(
            cornerRadius: cornerRadius,
            lightFill: NSColor.black.withAlphaComponent(0.12))
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? AdaptiveLozengeView)?.set(
            cornerRadius: cornerRadius,
            tint: tint,
            lightFill: NSColor.black.withAlphaComponent(0.12))
    }
}

/// Colour named the way this project reasons about it.
///
/// Lightness and chroma are held while the hue moves, which is the whole point
/// of asking for it in this space: hues picked off an HSL wheel come out with
/// yellow blazing and blue sunk, and a set of workspace colours chosen that way
/// would have one row shouting and another invisible.
private enum OKLCH {
    /// The same colour, for the AppKit half of the window.
    static func appKitColor(
        _ lightness: Double, _ chroma: Double, _ hue: Double, alpha: Double = 1
    ) -> NSColor {
        let (red, green, blue) = components(lightness, chroma, hue)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static func color(
        _ lightness: Double, _ chroma: Double, _ hue: Double, opacity: Double = 1
    ) -> Color {
        let (red, green, blue) = components(lightness, chroma, hue)
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    private static func components(
        _ lightness: Double, _ chroma: Double, _ hue: Double
    ) -> (Double, Double, Double) {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)

        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

        return (
            encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }

    /// Linear light to sRGB, clamped: a hue and chroma that fall outside what
    /// a display can show are brought to the nearest thing it can.
    private static func encode(_ channel: Double) -> Double {
        let value = max(0, min(1, channel))
        return value <= 0.0031308
            ? value * 12.92
            : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
