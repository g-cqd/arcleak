import Foundation
import ArcLeakCore
import Testing

/// Cross-file analysis: golden runner over Fixtures/Corpus (each subdirectory
/// analyzed as one unit) plus adversarial graph checks through the public API.
@Suite struct CorpusTests {
    struct FileExpectation: Hashable, CustomStringConvertible {
        let file: String
        let line: Int
        let rule: RuleID
        var description: String { "\(rule.rawValue)@\(file):\(line)" }
    }

    @Test("Corpus fixtures: multi-file units, exact finding sets")
    func corpusFixtures() async throws {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let corpusRoot = root.appending(path: "Corpus")
        let units = try FileManager.default
            .contentsOfDirectory(at: corpusRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
        #expect(!units.isEmpty, "no corpus fixture units found")

        for unit in units {
            let files = try FileManager.default
                .contentsOfDirectory(at: unit, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
                .sorted { $0.path < $1.path }

            var expected: Set<FileExpectation> = []
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for expectation in FixtureRunnerTests.expectations(in: source, marker: "arcleak-expect: ") {
                    expected.insert(
                        FileExpectation(
                            file: file.lastPathComponent,
                            line: expectation.line,
                            rule: expectation.rule
                        )
                    )
                }
            }

            let report = await Analyzer().analyze(files: files.map(\.path))
            let actual = Set(report.findings.map {
                FileExpectation(
                    file: URL(fileURLWithPath: $0.path).lastPathComponent,
                    line: $0.line,
                    rule: $0.rule
                )
            })

            #expect(
                actual == expected,
                """
                \(unit.lastPathComponent):
                  missing: \(expected.subtracting(actual).sorted { $0.description < $1.description })
                  extra:   \(actual.subtracting(expected).sorted { $0.description < $1.description })
                """
            )
        }
    }

    private func findings(_ source: String) -> [Finding] {
        Analyzer().analyze(source: source, path: "test.swift").findings
    }

    @Test("Two classes in one file close a cycle (corpus of one)")
    func singleFileMutualCycle() {
        let source = """
        final class A {
            var b: B?
        }
        final class B {
            let a: A
            init(a: A) { self.a = a }
        }
        """
        let result = findings(source)
        #expect(result.map(\.rule) == [.mutualStrongProperties])
        #expect(result.first?.message.contains("A → B → A") == true)
    }

    @Test("Initializer-inferred type (`= ServiceB()`) participates in the graph")
    func initializerInference() {
        let source = """
        final class ServiceA {
            var partner = ServiceB()
        }
        final class ServiceB {
            var back: ServiceA?
        }
        """
        #expect(findings(source).map(\.rule) == [.mutualStrongProperties])
    }

    @Test("weak/unowned back-references break the cycle; computed and static don't count")
    func nonEdgesProduceNoCycle() {
        let source = """
        final class Owner {
            var item: Item?
            static var shared: Owner?
            var view: Item { Item() }
        }
        final class Item {
            weak var owner: Owner?
            unowned var boss: Owner
            init(boss: Owner) { self.boss = boss }
            init() { fatalError() }
        }
        """
        #expect(findings(source).isEmpty)
    }

    @Test("5000-node ring: one finding, bounded message, no stack blowup")
    func giantRingIsStackSafe() {
        let count = 5000
        let source = (0..<count)
            .map { "final class R\($0) { var next: R\(($0 + 1) % count)? }" }
            .joined(separator: "\n")
        let result = findings(source)
        #expect(result.count == 1)
        #expect(result.first?.rule == .mutualStrongProperties)
        if let message = result.first?.message {
            #expect(message.count < 2000, "diagnostic must stay bounded, got \(message.count) chars")
            #expect(message.contains("more links"))
        }
    }

    @Test("Corpus findings are suppressible like local ones")
    func corpusFindingSuppression() {
        let source = """
        final class Left {
            // arcleak:deliberate -- torn down manually in close()
            var right: Right?
        }
        final class Right {
            var left: Left?
        }
        """
        let result = Analyzer().analyze(source: source, path: "test.swift")
        #expect(result.findings.isEmpty)
        #expect(result.suppressed.count == 1)
        #expect(result.suppressed.first?.reason?.contains("close()") == true)
    }
}
