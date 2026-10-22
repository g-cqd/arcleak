// swift-format-ignore-file
import WebKit

// Removal on a reachable teardown path: the lifecycle is managed.
final class ManagedBridge: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.add(self, name: "bridge")
    }

    func close() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

// A weak proxy is registered instead of self: the controller keeps the proxy,
// and the proxy does not keep self.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

final class ProxiedBridge: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.add(WeakScriptHandler(self), name: "bridge")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

// The controller is held weakly and the handler is removed in deinit: self
// keeps neither the web view nor the controller, so there is no cycle. The
// controller keeps self only while the web view lives, and deinit runs once
// it is gone.
final class WeakControllerBridge: NSObject, WKScriptMessageHandler {
    weak var contentController: WKUserContentController?

    func attach(to contentController: WKUserContentController) {
        self.contentController = contentController
        contentController.add(self, name: "b")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController?.removeScriptMessageHandler(forName: "b")
    }
}

// SwiftUI's WebView struct is not a WKWebView: keeping one does not make a
// parameter controller the owned web view's, so the deinit-only removal is
// silent, as for a type that keeps no web view.
final class SwiftUIPreviewBridge: NSObject, WKScriptMessageHandler {
    var preview: WebView?
    weak var contentController: WKUserContentController?

    func attach(to contentController: WKUserContentController) {
        self.contentController = contentController
        contentController.add(self, name: "a")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController?.removeScriptMessageHandler(forName: "a")
    }
}
