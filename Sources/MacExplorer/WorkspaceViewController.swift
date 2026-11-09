import AppKit

@MainActor
protocol WorkspaceHost: AnyObject {
    func workspaceActivePaneDidChange()
    func workspaceWantsCloseWindow()
}

/// Pencerenin sağ tarafı: tek panel ya da yan yana iki panel (F9 ile açılır/kapanır).
/// Sağ panel kapatıldığında sekmeleri saklanır; yeniden açılınca kaldığı yerden devam eder.
@MainActor
final class WorkspaceViewController: NSSplitViewController, PaneViewControllerDelegate {
    weak var host: WorkspaceHost?

    let left: PaneViewController
    let right: PaneViewController
    private lazy var leftItem = NSSplitViewItem(viewController: left)
    private lazy var rightItem = NSSplitViewItem(viewController: right)
    private var rightShownOnce = false

    private(set) lazy var activePane: PaneViewController = left

    init(url: URL) {
        left = PaneViewController(url: url)
        right = PaneViewController(url: url)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        left.delegate = self
        right.delegate = self
        leftItem.minimumThickness = 320
        rightItem.minimumThickness = 320
        rightItem.canCollapse = true
        rightItem.isCollapsed = true
        addSplitViewItem(leftItem)
        addSplitViewItem(rightItem)
    }

    var isDualPane: Bool { !rightItem.isCollapsed }
    var visiblePanes: [PaneViewController] { isDualPane ? [left, right] : [left] }
    var otherPane: PaneViewController? {
        guard isDualPane else { return nil }
        return activePane === left ? right : left
    }

    func toggleDualPane() {
        if isDualPane {
            let focusLeft = activePane === right
            rightItem.isCollapsed = true
            activate(left)
            if focusLeft { left.focusTable() }
        } else {
            if !rightShownOnce {
                rightShownOnce = true
                // Sağ panel, açıldığı andaki panelin klasörü, görünümü ve sıralamasıyla başlar.
                right.resetTabs(to: activePane.tab.url, like: activePane.tab)
            }
            rightItem.isCollapsed = false
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
            activate(activePane)
        }
    }

    /// Pencere yeniden kurulurken (dil değişimi) panelleri ve sekmeleri geri yükler.
    func restore(left leftTabs: [TabState], leftSelected: Int, right rightTabs: [TabState], rightSelected: Int,
                 dualPane: Bool, rightActive: Bool) {
        left.setTabs(leftTabs, selected: leftSelected)
        if dualPane {
            right.setTabs(rightTabs, selected: rightSelected)
            rightShownOnce = true
        } else {
            // Tek panel: sağ panel ilk açılışında etkin panelin klasörüyle başlar (eski sekmeler geri gelmez).
            rightShownOnce = false
        }
        if dualPane != isDualPane { toggleDualPane() }
        activate(dualPane && rightActive ? right : left)
    }

    func activate(_ pane: PaneViewController) {
        activePane = isDualPane ? pane : left
        left.isInDualPane = isDualPane
        right.isInDualPane = isDualPane
        left.isActive = isDualPane && activePane === left
        right.isActive = isDualPane && activePane === right
        host?.workspaceActivePaneDidChange()
    }

    /// Tab tuşu: diğer panele geç.
    func switchPane() {
        guard let other = otherPane else { return }
        activate(other)
        other.focusTable()
    }

    // MARK: PaneViewControllerDelegate

    func paneDidBecomeActive(_ pane: PaneViewController) {
        guard pane !== activePane, visiblePanes.contains(where: { $0 === pane }) else { return }
        activate(pane)
    }

    func otherPane(of pane: PaneViewController) -> PaneViewController? {
        guard isDualPane else { return nil }
        return pane === left ? right : left
    }

    func paneDidChangeLocation(_ pane: PaneViewController) {
        if pane === activePane { host?.workspaceActivePaneDidChange() }
    }

    /// Son sekme kapatılınca: çift panelde o panel kapanır, tek panelde pencere kapanır (Windows gibi).
    func paneWantsCloseLastTab(_ pane: PaneViewController) {
        guard isDualPane else {
            host?.workspaceWantsCloseWindow()
            return
        }
        if pane === left { left.adoptTabs(from: right) }
        right.resetTabs(to: left.tab.url)
        rightShownOnce = false
        rightItem.isCollapsed = true
        activate(left)
        left.focusTable()
    }
}
