// swift-format-ignore-file
// Field-report dispute, settled by the runtime oracle (nested_weak_task_sink):
// the sink body's ONLY `self` is a nested `Task { [weak self] }`. Forming the
// nested weak box forces the sink closure itself to capture self strongly, so
// self → cancellables → sink closure → self IS a cycle. The diagnostic must
// teach this (message names the nested-capture-list mechanism).
import Combine

final class Feed {
    let subject = PassthroughSubject<Int, Never>()
    var cancellables = Set<AnyCancellable>()

    func bind() {
        subject.sink { _ in // #al:expect combine-sink-self-cycle
            Task { [weak self] in _ = self }
        }
        .store(in: &cancellables)
    }
}
