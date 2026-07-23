import Foundation

/// Experimental L5: confirm capture strength from SILGen, where captures are
/// explicit — a strong `self` capture partial-applies the object directly,
/// a weak one goes through a `@sil_weak` box.
///
/// Deliberately bounded: compiles ONE file with `xcrun swiftc -emit-silgen`
/// (SDK modules only — project imports fail to `unavailable`, never guessed),
/// and FAILS OPEN: only a positive weak refutation demotes a finding.
///
/// Robustness: reads stdout and stderr concurrently (a serial drain deadlocks
/// when swiftc floods the other pipe), enforces a wall-clock timeout via
/// `ContinuousClock` (a hung compiler must not hang the run), and memoizes
/// SILGen per file so N findings in one file compile it once — see
/// `SILConfirmationSession`.
public enum SILConfirmation {
    public enum Outcome: Sendable, Equatable {
        case confirmedStrong
        case refutedWeak
        case unavailable(String)
    }

    /// Default wall-clock budget for one SILGen compile.
    public static let defaultTimeout: Duration = .seconds(30)

    /// One-shot verdict for the closure nearest `line` in `file`. For multiple
    /// findings in the same file, use `SILConfirmationSession` to compile once.
    public static func confirmSelfCapture(
        file: String,
        line: Int,
        timeout: Duration = defaultTimeout
    ) async -> Outcome {
        await SILConfirmationSession(timeout: timeout).confirmSelfCapture(file: file, line: line)
    }

    /// Demotion seam (testable without the CLI): keep everything except
    /// findings whose capture SIL positively refutes.
    public static func filter(
        findings: [Finding],
        confirm: (Finding) async -> Outcome
    ) async -> (kept: [Finding], demoted: [Finding]) {
        var kept: [Finding] = []
        var demoted: [Finding] = []
        for finding in findings {
            if case .refutedWeak = await confirm(finding) {
                demoted.append(finding)
            } else {
                kept.append(finding)
            }
        }
        return (kept, demoted)
    }

    /// Parses a SILGen dump for the capture strength of the closure nearest
    /// `line`. Pure — no I/O; the load-bearing text logic, unit-testable.
    static func verdict(fromSIL sil: Substring, file: String, line: Int) -> Outcome {
        let baseName = URL(fileURLWithPath: file).lastPathComponent
        var best: (distance: Int, signature: Substring)?

        for function in sil.split(separator: "// end sil function") {
            guard function.contains("closure #") else { continue }
            // Only closure DEFINITION blocks qualify (mangled closure symbols
            // contain "fU") — parent functions merely referencing closures
            // must not shadow them.
            guard
                let signatureLine = function.split(separator: "\n").first(where: {
                    $0.hasPrefix("sil ") && $0.contains(" : $@convention")
                }),
                let symbolRange = signatureLine.range(of: " : $@convention"),
                signatureLine[..<symbolRange.lowerBound].contains("fU")
            else { continue }

            var nearest = Int.max
            for chunk in function.split(separator: "loc \"").dropFirst() {
                guard chunk.contains(baseName) else { continue }
                let afterColon = chunk.drop(while: { $0 != ":" }).dropFirst()
                if let silLine = Int(afterColon.prefix(while: \.isNumber)) {
                    nearest = min(nearest, abs(silLine - line))
                }
            }
            guard nearest <= 3 else { continue }
            if best == nil || nearest < best!.distance {
                best = (nearest, signatureLine)
            }
        }

        guard let best else { return .unavailable("no closure near line \(line) in SILGen") }
        // Only the weak-box marker refutes — optional PARAMETERS are not weak captures.
        return best.signature.contains("@sil_weak") ? .refutedWeak : .confirmedStrong
    }
}
