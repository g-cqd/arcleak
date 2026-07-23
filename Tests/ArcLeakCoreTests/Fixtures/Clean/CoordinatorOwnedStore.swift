// swift-format-ignore-file
// store(in:) through a non-self reference (`context.coordinator.cancellables`):
// the collection's owner is unknown to syntax-level analysis, so the tool must
// make no scope-death claim (dogfood-reported FP: the coordinator outlives the
// registering call).
import Combine

final class PreviewCoordinator {
    var cancellables = Set<AnyCancellable>()
    var index = 0
}

struct PreviewContext {
    let coordinator: PreviewCoordinator
}

enum PreviewWiring {
    static func wire(subject: PassthroughSubject<Int, Never>, context: PreviewContext) {
        subject
            .sink { [weak coordinator = context.coordinator] newIndex in
                coordinator?.index = newIndex
            }
            .store(in: &context.coordinator.cancellables)
    }
}
