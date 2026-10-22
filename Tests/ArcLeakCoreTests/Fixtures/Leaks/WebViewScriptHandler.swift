// swift-format-ignore-file
import WebKit

// The user content controller keeps the handler until it is removed, and the
// web view keeps the controller: web view → configuration → controller → self.
// Public fixes register a weak proxy instead (firefox-ios@4d83f60171,
// element-x-ios@f8d094516d).

// Removal only in deinit, which never runs while the controller holds self.
// Definite leak (error).
final class BridgeController: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.add(self, name: "bridge") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }
}

// No removal anywhere, through the content-world overload (warning).
final class PageController: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        let contentController = webView.configuration.userContentController
        contentController.add(self, contentWorld: .page, name: "page") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

// The reply-handler registration keeps its handler the same way (warning).
final class ReplyController: NSObject, WKScriptMessageHandlerWithReply {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "reply") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {}
}
