// swift-format-ignore-file
import RxCocoa
import RxSwift

// self → disposeBag → subscription → onNext closure → self. The bag disposes
// its subscriptions in its own deinit, which runs only after self's — never,
// while the closure holds self. Warning: whether the source completes cannot
// be read from the source.
final class FeedViewModel {
    let disposeBag = DisposeBag()
    let refresh = PublishSubject<Void>()
    let title = BehaviorRelay<String>(value: "")
    var subscription: Disposable?
    var count = 0

    func bindInputs() {
        refresh.subscribe(onNext: { _ in // #al:expect combine-sink-self-cycle
            self.count += 1
        }).disposed(by: disposeBag)
        title.asDriver().drive(onNext: { text in self.render(text) }).disposed(by: self.disposeBag) // #al:expect combine-sink-self-cycle
        refresh.bind { _ in self.count = 0 }.disposed(by: disposeBag) // #al:expect combine-sink-self-cycle
        subscription = refresh.subscribe(onNext: { _ in self.count += 2 }) // #al:expect combine-sink-self-cycle
    }

    func render(_ text: String) {}
}
