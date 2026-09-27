import AppKit
import SwiftUI

/// A visual continuation of the terminal behind chrome. It must never take
/// clicks away from the native titlebar controls or window drag.
final class TerminalTintBackdropView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The window's split, with a divider that still drags but draws nothing.
///
/// The sidebar's recessed backdrop already marks where it ends. On macOS 27
/// the default divider became a light rule down the full height of the
/// window, titlebar included — a second boundary on top of the first.
final class SeamlessSplitView: NSSplitView {
    override var dividerStyle: NSSplitView.DividerStyle {
        get { .thin }
        set {}
    }
    override var dividerColor: NSColor { .clear }
}

/// The rows, observable. Exists so `render` can update the list WITHOUT
/// replacing the hosting controller's rootView — a rootView swap rebuilds
/// the whole view tree, and the rebuilt outline view grabs the keyboard from
/// the terminal every time it happens.
@MainActor
final class SidebarRows: ObservableObject {
    @Published var rows: [SessionSnapshot.SidebarRow] = []
}

/// The flat, full-height sidebar host.
///
/// A default split item would get AppKit's Tahoe sidebar glass, inset and
/// rounded floating container; this one owns a flat backdrop that reaches
/// every window edge while the hosted SwiftUI list starts below the traffic
/// lights via the safe-area guide.
@MainActor
final class SidebarHost: NSViewController {
    let backdropView = TerminalTintBackdropView()
    private var listTop: NSLayoutConstraint!
    private let hosting: NSHostingController<WorkspaceSidebar>
    private let model = SidebarRows()

    init(dispatch: @escaping (Intent) -> Void) {
        hosting = NSHostingController(rootView: WorkspaceSidebar(model: model, dispatch: dispatch))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Equality-guarded: a quiet poll re-renders nothing.
    func render(_ newRows: [SessionSnapshot.SidebarRow]) {
        guard newRows != model.rows else { return }
        model.rows = newRows
    }

    override func loadView() {
        let container = NSView()
        backdropView.wantsLayer = true
        backdropView.translatesAutoresizingMaskIntoConstraints = false

        addChild(hosting)
        let content = hosting.view
        content.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(backdropView)
        container.addSubview(content)
        // Measured off the window rather than taken from the safe-area guide.
        // The guide gives this container nothing — the list began at the very
        // top of the sidebar and its first row sat behind the traffic lights
        // — and the titlebar is the only thing that knows how tall it is.
        listTop = content.topAnchor.constraint(equalTo: container.topAnchor, constant: 52)
        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: container.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            listTop,
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window else { return }
        // The titlebar's height, asked of the window: its frame less the part
        // it says is content. Plus a little, so the first row is under the
        // traffic lights rather than against them.
        let titlebar = window.frame.height - window.contentLayoutRect.height
        // Full screen has no titlebar and no traffic lights in the way, until
        // the pointer pulls them down over everything anyway: the list starts
        // at the top, level with the tab row beside it.
        let wanted = window.styleMask.contains(.fullScreen)
            ? 4
            : (titlebar > 1 ? titlebar : 52) + 4
        if abs(listTop.constant - wanted) > 0.5 {
            listTop.constant = wanted
        }
    }
}
