import Foundation

/// Experimental L5: confirm capture strength from SILGen, where captures are
/// explicit — a strong `self` capture partial-applies the object directly,
/// a weak one goes through a `@sil_weak` box.
///
/// Deliberately bounded: compiles ONE file with `xcrun swiftc -emit-silgen`
/// (SDK modules only — project imports fail to `unavailable`, never guessed),
/// and FAILS OPEN: only a positive weak refutation demotes a finding.
public enum SILConfirmation {
    public enum Outcome: Sendable, Equatable {
        case confirmedStrong
        case refutedWeak
        case unavailable(String)
    }

    /// Verdict for the closure nearest `line` in `file`.
    public static func confirmSelfCapture(file: String, line: Int) -> Outcome {
        let sil: String
        switch emitSILGen(file: file) {
        case .emitted(let output): sil = output
        case .failed(let reason): return .unavailable(reason)
        }

        let baseName = URL(fileURLWithPath: file).lastPathComponent
        var best: (distance: Int, signature: String)?

        for function in sil.components(separatedBy: "// end sil function") {
            guard function.contains("closure #") else { continue }
            // Only closure DEFINITION blocks qualify (mangled closure symbols
            // contain "fU") — parent functions merely referencing closures
            // must not shadow them.
            guard
                let signatureLine = function.split(separator: "\n").first(where: { line in
                    line.hasPrefix("sil ") && line.contains(" : $@convention")
                }),
                let symbolRange = signatureLine.range(of: " : $@convention"),
                signatureLine[..<symbolRange.lowerBound].contains("fU")
            else { continue }

            // Nearest `loc "<file>":<line>` decides which closure this is.
            var nearest = Int.max
            for chunk in function.components(separatedBy: "loc \"").dropFirst() {
                guard chunk.hasPrefix(baseName) || chunk.contains(baseName) else { continue }
                let afterColon = chunk.drop(while: { $0 != ":" }).dropFirst()
                if let silLine = Int(afterColon.prefix(while: \.isNumber)) {
                    nearest = min(nearest, abs(silLine - line))
                }
            }
            guard nearest <= 3 else { continue }
            if best == nil || nearest < best!.distance {
                best = (nearest, String(signatureLine))
            }
        }

        guard let best else { return .unavailable("no closure near line \(line) in SILGen") }
        // Only the weak-box marker refutes — optional PARAMETERS are not weak captures.
        if best.signature.contains("@sil_weak") {
            return .refutedWeak
        }
        return .confirmedStrong
    }

    /// Demotion seam (testable without the CLI): keep everything except
    /// findings whose capture SIL positively refutes.
    public static func filter(
        findings: [Finding],
        confirm: (Finding) -> Outcome
    ) -> (kept: [Finding], demoted: [Finding]) {
        var kept: [Finding] = []
        var demoted: [Finding] = []
        for finding in findings {
            if case .refutedWeak = confirm(finding) {
                demoted.append(finding)
            } else {
                kept.append(finding)
            }
        }
        return (kept, demoted)
    }

    private enum SILGenResult {
        case emitted(String)
        case failed(String)
    }

    private static func emitSILGen(file: String) -> SILGenResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-emit-silgen", "-g", file]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failed("cannot launch swiftc: \(error)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let firstError =
                String(decoding: errors, as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? "swiftc failed"
            return .failed(firstError)
        }
        return .emitted(String(decoding: output, as: UTF8.self))
    }
}
