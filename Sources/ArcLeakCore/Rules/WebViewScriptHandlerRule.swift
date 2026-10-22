/// `<…>.userContentController.add(self, name:)` — the user content controller
/// keeps its script message handlers until they are removed, and the web
/// view's configuration keeps the controller, so `self` lives as long as the
/// web view. Apple's documentation does not state the retention; public fixes
/// replace `self` with a weak proxy (firefox-ios@4d83f60171,
/// element-x-ios@f8d094516d).
///
/// Same reachability contract as the notification-observer rule: a removal
/// reachable outside `deinit` means a managed lifecycle (silent). A removal
/// that only exists in `deinit` can never run when `self` closes the loop by
/// keeping the web view, its configuration or its content controller in a
/// strong stored property (error). Without that edge `self` is not in a
/// cycle: the controller keeps it only while the web view lives, so a
/// deinit-only removal is silent and a missing removal is a warning about the
/// observed retention.
struct WebViewScriptHandlerRule: Rule {
    static let emits: [RuleID] = [.webviewScriptHandlerCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.removeScriptMessageHandler) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.removeScriptMessageHandler)
        let ownsWebView = keepsWebView(type)
        guard ownsWebView || !deinitOnly else { return [] }

        return type.apiCalls.compactMap { call in
            guard call.kind == .scriptMessageHandlerAdd, call.targetIsSelf else { return nil }

            let severity: Severity
            let message: String
            let note: String
            if !ownsWebView {
                severity = min(configuration.severity(for: .webviewScriptHandlerCycle), .warning)
                message =
                    "observed: the user content controller keeps its script message handler (self) until it is removed — self lives as long as the web view"
                note =
                    "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; this type keeps no web view, configuration or content controller, so no cycle is proven — remove the handler when the page is done or register a weak proxy"
            } else if deinitOnly {
                severity = .error
                message = cycleMessage
                note =
                    "the handler is removed only in deinit — the controller's hold on self means deinit never runs; remove it from a reachable teardown path or register a weak proxy"
            } else {
                severity = configuration.severity(for: .webviewScriptHandlerCycle)
                message = cycleMessage
                note =
                    "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; remove the handler from a reachable teardown path or register a weak proxy"
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

    /// A strong stored property typed as a web view (`WKWebView` or a
    /// subclass named `…WebView`), its configuration or its user content
    /// controller: the edge from `self` that closes the loop.
    private static func keepsWebView(_ type: TypeFacts) -> Bool {
        type.storedProperties.contains { property in
            property.strength == .strong
                && property.referencedTypeNames.contains { name in
                    name.hasSuffix("WebView") || name == "WKWebViewConfiguration" || name == "WKUserContentController"
                }
        }
    }
}
