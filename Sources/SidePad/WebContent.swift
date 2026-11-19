import AppKit
import Combine
import WebKit

final class ClickableWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class WebContent: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let initialURL = URL(string: "https://chatgpt.com/")!
    @Published private(set) var webView: WKWebView?
    @Published private(set) var sleepingIDs: Set<UUID> = []
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    private(set) var restorationURLs: [UUID: URL] = [:]
    private(set) var activeID: UUID?

    init(loadPage: Bool = true) {
        super.init()
        if loadPage { open(WebItem.chatGPTID, url: Self.initialURL) }
    }

    func isActive(_ id: UUID) -> Bool { !sleepingIDs.contains(id) }
    func lastURL(for item: WebItem) -> URL { restorationURLs[item.id] ?? item.url }

    func select(_ selection: WorkspaceSelection, store: WorkspaceStore?) {
        if let previous = activeID, selection != .web(previous) {
            if let url = webView?.url { rememberURL(url, for: previous) }
            if store?.webItem(id: previous)?.autoSleepWhenInactive == true { sleep(previous) }
        }
        guard case let .web(id) = selection, let item = store?.webItem(id: id) else { return }
        if activeID != id || webView == nil { wake(id, url: lastURL(for: item)) }
    }

    func sleep(_ id: UUID) {
        sleepingIDs.insert(id)
        guard activeID == id else { return }
        if let url = webView?.url { rememberURL(url, for: id) }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil // The SwiftUI container detaches this view; WebKit may retain its process/cache separately.
        activeID = nil
        canGoBack = false
        canGoForward = false
    }

    func wake(_ id: UUID, url: URL) {
        sleepingIDs.remove(id)
        if activeID == id, webView != nil { return }
        open(id, url: restorationURLs[id] ?? url)
    }

    private func open(_ id: UUID, url: URL) {
        activeID = id
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let view = ClickableWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            view.autoresizingMask = [.width, .height]
            webView = view
        }
        webView?.load(URLRequest(url: url))
    }

    func load(_ url: URL) { webView?.load(URLRequest(url: url)) }
    func rememberURL(_ url: URL, for id: UUID) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        restorationURLs[id] = url
    }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateNavigation(webView) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateNavigation(webView) }
    private func updateNavigation(_ view: WKWebView) {
        guard view === webView else { return }
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        if let id = activeID, let url = view.url { rememberURL(url, for: id) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            if navigationAction.navigationType == .linkActivated,
               !["javascript", "data", "file", ""].contains(scheme) { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let scheme = navigationAction.request.url?.scheme?.lowercased(),
           ["http", "https"].contains(scheme) { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("Side Pad navigation failed (code %ld)", (error as NSError).code)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        NSLog("Side Pad web content process terminated")
        webView.reload()
    }
}
