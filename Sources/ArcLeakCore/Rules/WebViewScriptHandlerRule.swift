/// `<…>.userContentController.add(self, name:)` — the user content controller
/// keeps its script message handlers until they are removed, and the web
/// view's configuration keeps the controller, so `self` lives as long as the
/// web view. Apple's documentation does not state the retention; public fixes
/// replace `self` with a weak proxy (firefox-ios@4d83f60171,
/// element-x-ios@f8d094516d).
///
/// Same reachability contract as the notification-observer rule: a removal
/// reachable outside `deinit` means a managed lifecycle (silent). A removal
/// that only exists in `deinit` can never run when the `add` call's receiver
/// starts at a strong stored property of `self` typed `WKWebView`,
/// `WKWebViewConfiguration` or `WKUserContentController`
/// (`webView.configuration.userContentController`, `contentController`):
/// `self` closes the loop (error). A receiver that is a parameter or a local
/// proves no cycle, even when the type keeps a web view for something else:
/// the finding is capped at warning with an "observed" message. A type that
/// keeps none of them is not in a cycle (the controller keeps it only while
/// the web view lives), so a deinit-only removal is silent there.
struct WebViewScriptHandlerRule: Rule {
    static let emits: [RuleID] = [.webviewScriptHandlerCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.removeScriptMessageHandler) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.removeScriptMessageHandler)
        let owned = ownedWebViewMembers(type)
        guard !owned.isEmpty || !deinitOnly else { return [] }
        let configured = configuration.severity(for: .webviewScriptHandlerCycle)

        return type.apiCalls.compactMap { call in
            guard call.kind == .scriptMessageHandlerAdd, call.targetIsSelf else { return nil }

            let severity: Severity
            let message: String
            let note: String
            if let root = call.receiverRootMember, owned.contains(root) {
                severity = deinitOnly ? .error : configured
                message = cycleMessage
                note =
                    deinitOnly
                    ? "the handler is removed only in deinit — the controller's hold on self means deinit never runs; remove it from a reachable teardown path or register a weak proxy"
                    : "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; remove the handler from a reachable teardown path or register a weak proxy"
            } else if owned.isEmpty {
                severity = min(configured, .warning)
                message =
                    "observed: the user content controller keeps its script message handler (self) until it is removed — self lives as long as the web view"
                note =
                    "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; this type keeps no web view, configuration or content controller, so no cycle is proven — remove the handler when the page is done or register a weak proxy"
            } else {
                severity = min(configured, .warning)
                message =
                    "observed: the user content controller keeps its script message handler (self) until it is removed — when this controller belongs to the web view this type keeps, web view → configuration → controller → self"
                note =
                    deinitOnly
                    ? "the handler is removed only in deinit, and this controller is not reached from a web view, configuration or content controller this type keeps (it is a parameter or a local), so no cycle is proven; when it belongs to the owned web view, deinit never runs — remove the handler from a reachable teardown path or register a weak proxy"
                    : "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; this controller is not reached from a web view, configuration or content controller this type keeps (it is a parameter or a local), so no cycle is proven — remove the handler when the page is done or register a weak proxy"
            }
            return Finding(
                rule: .webviewScriptHandlerCycle,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message: message,
                note: note
            )
        }
    }

    private static let cycleMessage =
        "leak: the user content controller keeps its script message handler (self) until it is removed — web view → configuration → controller → self"

    /// Names of the strong stored properties typed `WKWebView`,
    /// `WKWebViewConfiguration` or `WKUserContentController`: the edges from
    /// `self` that can close the loop. Exact names only, so SwiftUI's
    /// `WebView` struct (and any other `…WebView` type) does not count.
    private static func ownedWebViewMembers(_ type: TypeFacts) -> Set<String> {
        Set(
            type.storedProperties.filter { property in
                property.strength == .strong
                    && property.referencedTypeNames.contains { webKitOwnerTypes.contains($0) }
            }
            .map(\.name)
        )
    }

    private static let webKitOwnerTypes: Set<String> = [
        "WKWebView", "WKWebViewConfiguration", "WKUserContentController",
    ]
}
