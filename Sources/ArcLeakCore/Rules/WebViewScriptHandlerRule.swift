/// `<…>.userContentController.add(self, name:)` — the user content controller
/// keeps its script message handlers until they are removed, and the web
/// view's configuration keeps the controller, so `self` lives as long as the
/// web view. Apple's documentation does not state the retention; public fixes
/// replace `self` with a weak proxy (firefox-ios@4d83f60171,
/// element-x-ios@f8d094516d).
///
/// Same reachability contract as the notification-observer rule: a removal
/// reachable outside `deinit` means a managed lifecycle (silent); a removal
/// that only exists in `deinit` can never run (error).
struct WebViewScriptHandlerRule: Rule {
    static let emits: [RuleID] = [.webviewScriptHandlerCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.removeScriptMessageHandler) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.removeScriptMessageHandler)

        return type.apiCalls.compactMap { call in
            guard call.kind == .scriptMessageHandlerAdd, call.targetIsSelf else { return nil }

            let severity: Severity
            let note: String
            if deinitOnly {
                severity = .error
                note =
                    "the handler is removed only in deinit — the controller's hold on self means deinit never runs; remove it from a reachable teardown path or register a weak proxy"
            } else {
                severity = configuration.severity(for: .webviewScriptHandlerCycle)
                note =
                    "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; remove the handler from a reachable teardown path or register a weak proxy"
            }
            return Finding(
                rule: .webviewScriptHandlerCycle,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "leak: the user content controller keeps its script message handler (self) until it is removed — web view → configuration → controller → self",
                note: note
            )
        }
    }
}
