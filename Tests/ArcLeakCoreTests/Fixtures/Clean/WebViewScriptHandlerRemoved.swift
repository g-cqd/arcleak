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
