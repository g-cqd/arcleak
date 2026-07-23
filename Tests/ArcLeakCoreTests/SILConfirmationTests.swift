#if os(macOS)
    import ArcLeakCore
    import Foundation
    import Testing

    /// Experimental SIL confirmation: SILGen ground truth confirms a strong
    /// capture, refutes a weak one, and the demotion seam flips a crafted verdict.
    /// Compiles single files with the local toolchain — macOS only.
    @Suite struct SILConfirmationTests {
        private func write(_ source: String) throws -> String {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "arcleak-sil-\(UUID().uuidString).swift")
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        @Test("SILGen confirms a strong self capture the analyzer flagged")
        func confirmsStrongCapture() throws {
            let source = """
                final class Box {
                    var handler: (() -> Void)?
                    var value = 0
                    func arm() {
                        handler = {
                            self.value += 1
                        }
                    }
                }
                """
            let path = try write(source)
            let findings = Analyzer().analyze(source: source, path: path).findings
            let line = try #require(findings.first?.line)

            let outcome = SILConfirmation.confirmSelfCapture(file: path, line: line)
            #expect(outcome == .confirmedStrong, "\(outcome)")
        }

        @Test("SILGen refutes a weak capture, and the seam demotes the crafted finding")
        func refutesWeakAndDemotes() throws {
            let source = """
                final class Box {
                    var handler: (() -> Void)?
                    var value = 0
                    func arm() {
                        handler = { [weak self] in
                            self?.value += 1
                        }
                    }
                }
                """
            let path = try write(source)
            // The analyzer correctly stays silent; craft the over-approximated
            // finding a coarser tier might produce, and let SIL flip it.
            let crafted = Finding(
                rule: .storedClosureStrongSelf,
                severity: .error,
                path: path,
                line: 5,
                column: 19,
                message: "crafted over-approximation"
            )

            let outcome = SILConfirmation.confirmSelfCapture(file: path, line: 5)
            #expect(outcome == .refutedWeak, "\(outcome)")

            let (kept, demoted) = SILConfirmation.filter(findings: [crafted]) {
                SILConfirmation.confirmSelfCapture(file: $0.path, line: $0.line)
            }
            #expect(kept.isEmpty)
            #expect(demoted.count == 1)
        }

        @Test("Uncompilable files fail open as unavailable")
        func unavailableFailsOpen() throws {
            let path = try write("import NotARealModuleAnywhere\n")
            let outcome = SILConfirmation.confirmSelfCapture(file: path, line: 1)
            guard case .unavailable = outcome else {
                Issue.record("expected unavailable, got \(outcome)")
                return
            }
            let finding = Finding(
                rule: .storedClosureStrongSelf,
                severity: .error,
                path: path,
                line: 1,
                column: 1,
                message: "kept on unavailable"
            )
            let (kept, demoted) = SILConfirmation.filter(findings: [finding]) { _ in outcome }
            #expect(kept.count == 1)
            #expect(demoted.isEmpty)
        }
    }
#endif
