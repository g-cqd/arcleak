import ArcLeakCore
import Testing

/// Upstream-finiteness classification: the dogfood-measured FP class.
@Suite struct FinitenessTests {
    private func findings(_ source: String) -> [Finding] {
        Analyzer().analyze(source: source, path: "test.swift").findings
    }

    @Test("Subject-backed member upstream is infinite — error severity")
    func subjectBackedIsError() {
        let source = """
            import Combine
            final class Sinker {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                var latest = 0
                func bind() {
                    subject.sink { value in self.latest = value }
                        .store(in: &cancellables)
                }
            }
            """
        let result = findings(source)
        #expect(result.map(\.rule) == [.combineSinkSelfCycle])
        #expect(result.map(\.severity) == [.error])
    }

    @Test("@Published projection upstream is infinite — error severity")
    func publishedProjectionIsError() {
        let source = """
            import Combine
            final class Model {
                @Published var count = 0
                var cancellables = Set<AnyCancellable>()
                var mirrored = 0
                func bind() {
                    $count.sink { value in self.mirrored = value }
                        .store(in: &cancellables)
                }
            }
            """
        let result = findings(source)
        #expect(result.map(\.rule) == [.combineSinkSelfCycle])
        #expect(result.map(\.severity) == [.error])
    }

    @Test("Unknown upstream (parameter publisher) hedges to warning")
    func unknownUpstreamIsWarning() {
        let source = """
            import Combine
            final class Consumer {
                var cancellables = Set<AnyCancellable>()
                var latest = 0
                func bind(publisher: AnyPublisher<Int, Never>) {
                    publisher.sink { value in self.latest = value }
                        .store(in: &cancellables)
                }
            }
            """
        let result = findings(source)
        #expect(result.map(\.rule) == [.combineSinkSelfCycle])
        #expect(result.map(\.severity) == [.warning])
    }

    @Test("Finite pipelines are silent (dataTaskPublisher, Just, first())")
    func finitePipelinesSilent() {
        let source = """
            import Combine
            import Foundation
            final class Fetcher {
                var cancellables = Set<AnyCancellable>()
                var data = Data()
                func fetch(url: URL) {
                    URLSession.shared.dataTaskPublisher(for: url)
                        .map(\\.data)
                        .replaceError(with: Data())
                        .sink { self.data = $0 }
                        .store(in: &cancellables)
                }
                func bounded(subject: PassthroughSubject<Int, Never>) {
                    subject.first()
                        .sink { self.data = Data([UInt8($0)]) }
                        .store(in: &cancellables)
                }
            }
            """
        #expect(findings(source).isEmpty)
    }
}
