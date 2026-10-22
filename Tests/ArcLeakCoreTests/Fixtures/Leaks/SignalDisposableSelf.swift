// swift-format-ignore-file
import SwiftSignalKit

// SwiftSignalKit: self → disposable → subscription → next closure → self.
// MetaDisposable and DisposableSet dispose in their own deinit, which never
// runs while the closure holds self. Warning: completion of the signal
// cannot be read from the source.
final class PeerController {
    let statusDisposable = MetaDisposable()
    let disposables = DisposableSet()
    var stateDisposable: Disposable?
    let peerSignal: Signal<String, NoError>

    init(peerSignal: Signal<String, NoError>) {
        self.peerSignal = peerSignal
    }

    func load() {
        self.statusDisposable.set(peerSignal.start(next: { value in // #al:expect combine-sink-self-cycle
            self.apply(value)
        }))
        disposables.add(peerSignal.start(next: { value in self.apply(value) })) // #al:expect combine-sink-self-cycle
        stateDisposable = (peerSignal |> deliverOnMainQueue).start(next: { value in self.apply(value) }) // #al:expect combine-sink-self-cycle
    }

    func apply(_ value: String) {}
}
