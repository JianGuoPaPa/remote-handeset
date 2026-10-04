import AppKit
import WebKit

private enum PreviewConfiguration {
    static let defaultURL = URL(string: "http://127.0.0.1:8080/preview")!

    static var url: URL {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "RemotePreviewURL") as? String,
            let url = URL(string: value),
            let host = url.host,
            url.scheme == "http",
            host == "127.0.0.1" || host == "localhost"
        else {
            return defaultURL
        }
        return url
    }
}

@main
final class RemoteAndroidApplication: NSObject, NSApplicationDelegate {
    private var windowController: PreviewWindowController?

    static func main() {
        let application = NSApplication.shared
        let delegate = RemoteAndroidApplication()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        showPreview()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showPreview()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    @objc private func showPreview() {
        if windowController == nil {
            windowController = PreviewWindowController(url: PreviewConfiguration.url)
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reloadPreview() {
        windowController?.reload()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "退出泰国安卓手机",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let reload = NSMenuItem(
            title: "重新连接",
            action: #selector(reloadPreview),
            keyEquivalent: "r"
        )
        reload.target = self
        viewMenu.addItem(reload)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }
}

private final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewController: PreviewViewController

    init(url: URL) {
        previewController = PreviewViewController(url: url)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "泰国安卓手机"
        window.contentMinSize = NSSize(width: 360, height: 640)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = previewController

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        previewController.reload()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        previewController.resumeIfNeeded()
    }
}

private final class PreviewViewController: NSViewController, WKNavigationDelegate {
    private let previewURL: URL
    private let webView: WKWebView
    private var reloadWorkItem: DispatchWorkItem?
    private var retryAttempt = 0
    private var hasLoadedPreview = false

    init(url: URL) {
        previewURL = url

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        resumeIfNeeded()
    }

    func reload() {
        retryAttempt = 0
        hasLoadedPreview = false
        reloadWorkItem?.cancel()
        loadPreview()
    }

    func resumeIfNeeded() {
        if !hasLoadedPreview && webView.isLoading == false {
            loadPreview()
        }
    }

    private func loadPreview() {
        reloadWorkItem?.cancel()
        var request = URLRequest(url: previewURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        webView.load(request)
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let delays: [TimeInterval] = [1, 2, 5, 10, 30]
        let delay = delays[min(retryAttempt, delays.count - 1)]
        retryAttempt += 1

        let workItem = DispatchWorkItem { [weak self] in
            self?.loadPreview()
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryAttempt = 0
        hasLoadedPreview = true
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        hasLoadedPreview = false
        scheduleReload()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        hasLoadedPreview = false
        scheduleReload()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hasLoadedPreview = false
        scheduleReload()
    }
}
