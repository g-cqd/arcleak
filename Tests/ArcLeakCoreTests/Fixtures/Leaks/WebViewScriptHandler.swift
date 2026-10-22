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

// Keeping the content controller strongly closes the loop too: self →
// controller → self, and the deinit-only removal never runs (error).
final class OwningBridge: NSObject, WKScriptMessageHandler {
    let contentController = WKUserContentController()

    func attach() {
        contentController.add(self, name: "owning") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController.removeScriptMessageHandler(forName: "owning")
    }
}

// A controller the type does not keep, and no removal: no cycle is proven,
// but self lives as long as the web view (observed behaviour; warning).
final class AttachedBridge: NSObject, WKScriptMessageHandler {
    func attach(to contentController: WKUserContentController) {
        contentController.add(self, name: "attached") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

// The type keeps a web view for something else and registers on a controller
// it is given: the receiver is a parameter, so no cycle is proven (warning,
// with a message that starts with observed:), not the deinit-only error.
final class PreviewBridge: NSObject, WKScriptMessageHandler {
    let preview = WKWebView()
    weak var contentController: WKUserContentController?

    func attach(to contentController: WKUserContentController) {
        self.contentController = contentController
        contentController.add(self, name: "a") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController?.removeScriptMessageHandler(forName: "a")
    }
}
