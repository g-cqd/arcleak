// swift-format-ignore-file
import RxSwift
import SwiftSignalKit

// Reactive subscriptions that do not close a cycle: finite sources (Single,
// Completable, Maybe, just, take(1), first()) release their closures when
// they complete; [weak self] never holds self; a bag held in a local disposes
// at the end of the call; a Disposable that self does not keep holds nothing
// of self's.
final class ProfileViewModel {
    let disposeBag = DisposeBag()
    let refresh = PublishSubject<Void>()
    let api = ProfileAPI()
    let statusDisposable = MetaDisposable()
    let peerSignal: Signal<String, NoError>
    var count = 0

    init(peerSignal: Signal<String, NoError>) {
        self.peerSignal = peerSignal
    }

    func bindInputs() {
        api.fetch().asSingle().subscribe(onSuccess: { _ in self.count += 1 }).disposed(by: disposeBag)
        Completable.empty().subscribe(onCompleted: { self.count = 0 }).disposed(by: disposeBag)
        Maybe<Int>.empty().subscribe(onNext: { _ in self.count = 0 }).disposed(by: disposeBag)
        Observable.just(1).subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
        refresh.take(1).subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
        refresh.first().asObservable().subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
        Observable<Int>.empty().subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
        refresh.subscribe(onNext: { [weak self] _ in self?.count += 1 }).disposed(by: disposeBag)

        let bag = DisposeBag()
        refresh.subscribe(onNext: { _ in self.count += 1 }).disposed(by: bag)

        _ = refresh.subscribe(onNext: { _ in self.count += 1 })

        statusDisposable.set((peerSignal |> take(1)).start(next: { _ in self.count += 1 }))
        statusDisposable.set(peerSignal.start(next: { [weak self] _ in self?.count += 1 }))
    }
}
