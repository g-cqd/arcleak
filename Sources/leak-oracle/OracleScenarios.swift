#if os(macOS)
    import Combine
    import Dispatch
    import Foundation

    // This file intentionally constructs every leak arcleak detects — it is the
    // runtime proof of the rules. Suppress the analyzer over the whole file, with
    // the reason on record.
    // @al:disable all -- deliberate leaks: this file IS the runtime oracle for the rules

    enum OracleScenarios {
        // MARK: - Cycle scenarios judged by `leaks -atExit` (expected to leak)

        static let cyclesExpectedToLeak: [String: () -> Void] = [
            "stored_closure_cycle": {
                final class Box {
                    var onChange: (() -> Void)?
                    var value = 0
                    func arm() { onChange = { self.value += 1 } }
                }
                let box = Box()
                box.arm()
            },
            "lazy_stored_closure": {
                final class HTMLElement {
                    let name: String
                    lazy var asHTML: () -> String = { "<\(self.name) />" }
                    init(name: String) { self.name = name }
                }
                let element = HTMLElement(name: "p")
                _ = element.asHTML()
            },
            "combine_sink_cycle": {
                final class Sinker {
                    let subject = PassthroughSubject<Int, Never>()
                    var cancellables = Set<AnyCancellable>()
                    var latest = 0
                    func bind() {
                        subject.sink { value in self.latest = value }
                            .store(in: &cancellables)
                    }
                }
                let sinker = Sinker()
                sinker.bind()
            },
            "combine_assign_cycle": {
                final class Assigner {
                    let subject = PassthroughSubject<Int, Never>()
                    var cancellables = Set<AnyCancellable>()
                    var latest = 0
                    func bind() {
                        subject.assign(to: \.latest, on: self)
                            .store(in: &cancellables)
                    }
                }
                let assigner = Assigner()
                assigner.bind()
            },
            "mutual_strong_properties": {
                final class OrderService { var payments: PaymentService? }
                final class PaymentService { var orders: OrderService? }
                let orders = OrderService()
                let payments = PaymentService()
                orders.payments = payments
                payments.orders = orders
            },
            "nested_weak_task_sink": {
                // The disputed field-report shape: the sink body's ONLY `self`
                // is a nested `Task { [weak self] }`. Forming that weak box
                // forces the sink closure itself to capture self strongly, so
                // self → cancellables → sink closure → self IS a cycle. This
                // scenario is the runtime proof: if the compiler did not
                // strongly capture, the instance would deallocate and the
                // oracle would fail with "expected a leak, found none".
                // `[weak self = self]` is the compiler-suggested spelling that
                // silences its ImplicitStrongCapture warning — the OUTER
                // capture under test stays implicit and strong either way.
                final class NestedTrap {
                    let subject = PassthroughSubject<Int, Never>()
                    var cancellables = Set<AnyCancellable>()
                    func bind() {
                        subject.sink { _ in
                            Task { [weak self = self] in _ = self }
                        }
                        .store(in: &cancellables)
                    }
                }
                let trap = NestedTrap()
                trap.bind()
            },
            "dispatch_source_cycle": {
                final class Beeper {
                    // Never activated: a suspended source with a handler is a pure
                    // self → source → handler → self cycle with no GCD root.
                    let source = DispatchSource.makeTimerSource()
                    var beeps = 0
                    func arm() {
                        source.setEventHandler { self.beeps += 1 }
                    }
                }
                let beeper = Beeper()
                beeper.arm()
            },
        ]

        // MARK: - Cycle scenarios judged by `leaks -atExit` (expected clean)

        static let cyclesExpectedClean: [String: () -> Void] = [
            "weak_self_stored": {
                final class Weakly {
                    var onChange: (() -> Void)?
                    var value = 0
                    func arm() {
                        onChange = { [weak self] in self?.value += 1 }
                    }
                }
                let weakly = Weakly()
                weakly.arm()
                weakly.onChange?()
            },
            "unowned_blessed": {
                final class Blessed {
                    let id = 7
                    lazy var render: () -> String = { [unowned self] in "id=\(self.id)" }
                }
                let blessed = Blessed()
                _ = blessed.render()
            },
            "applied_lazy": {
                final class Applied {
                    let id = 3
                    lazy var banner: String = { "ready \(self.id)" }()
                }
                let applied = Applied()
                _ = applied.banner
            },
            "weak_sink": {
                final class WeakSinker {
                    let subject = PassthroughSubject<Int, Never>()
                    var cancellables = Set<AnyCancellable>()
                    var latest = 0
                    func bind() {
                        subject.sink { [weak self] value in self?.latest = value }
                            .store(in: &cancellables)
                    }
                }
                let sinker = WeakSinker()
                sinker.bind()
                sinker.subject.send(1)
            },
        ]

        // MARK: - Self-verifying anchor contracts

        static let contracts: [String: () -> Bool] = [
            // "The timer maintains a strong reference to target until it (the
            // timer) is invalidated" + "Run loops maintain strong references to
            // their timers".
            "timer_retains_target": {
                final class Target: NSObject {
                    @objc func tick() {}
                }
                weak var weakTarget: Target?
                var timer: Timer?
                autoreleasepool {
                    let target = Target()
                    weakTarget = target
                    timer = Timer.scheduledTimer(
                        timeInterval: 0.05,
                        target: target,
                        selector: #selector(Target.tick),
                        userInfo: nil,
                        repeats: true
                    )
                }
                OracleSupport.spinRunLoop(seconds: 0.2)
                let heldWhileScheduled = weakTarget != nil
                timer?.invalidate()
                return heldWhileScheduled
            },
            "timer_invalidate_releases": {
                final class Target: NSObject {
                    @objc func tick() {}
                }
                weak var weakTarget: Target?
                var timer: Timer?
                autoreleasepool {
                    let target = Target()
                    weakTarget = target
                    timer = Timer.scheduledTimer(
                        timeInterval: 0.05,
                        target: target,
                        selector: #selector(Target.tick),
                        userInfo: nil,
                        repeats: true
                    )
                }
                OracleSupport.spinRunLoop(seconds: 0.1)
                timer?.invalidate()
                timer = nil
                return OracleSupport.waitUntil(timeout: .seconds(2)) { weakTarget == nil }
            },
            // "The notification center strongly holds the copied block until you
            // remove the observer registration."
            "nc_block_holds_object": {
                final class Handler {
                    func handle() {}
                }
                weak var weakHandler: Handler?
                var token: (any NSObjectProtocol)?
                autoreleasepool {
                    let handler = Handler()
                    weakHandler = handler
                    token = NotificationCenter.default.addObserver(
                        forName: Notification.Name("oracle"),
                        object: nil,
                        queue: nil
                    ) { _ in handler.handle() }
                }
                OracleSupport.spinRunLoop(seconds: 0.1)
                let held = weakHandler != nil
                if let token { NotificationCenter.default.removeObserver(token) }
                return held
            },
            "nc_remove_releases": {
                final class Handler {
                    func handle() {}
                }
                weak var weakHandler: Handler?
                var token: (any NSObjectProtocol)?
                autoreleasepool {
                    let handler = Handler()
                    weakHandler = handler
                    token = NotificationCenter.default.addObserver(
                        forName: Notification.Name("oracle"),
                        object: nil,
                        queue: nil
                    ) { _ in handler.handle() }
                }
                if let token { NotificationCenter.default.removeObserver(token) }
                token = nil
                return OracleSupport.waitUntil(timeout: .seconds(2)) { weakHandler == nil }
            },
            // "The session object keeps a strong reference to the delegate until
            // your app exits or explicitly invalidates the session."
            "urlsession_delegate_held": {
                final class Delegate: NSObject, URLSessionDelegate {}
                weak var weakDelegate: Delegate?
                var session: URLSession?
                autoreleasepool {
                    let delegate = Delegate()
                    weakDelegate = delegate
                    session = URLSession(
                        configuration: .ephemeral,
                        delegate: delegate,
                        delegateQueue: nil
                    )
                }
                OracleSupport.spinRunLoop(seconds: 0.2)
                let held = weakDelegate != nil
                session?.invalidateAndCancel()
                return held
            },
            "urlsession_invalidate_releases": {
                final class Delegate: NSObject, URLSessionDelegate {}
                weak var weakDelegate: Delegate?
                var session: URLSession?
                autoreleasepool {
                    let delegate = Delegate()
                    weakDelegate = delegate
                    session = URLSession(
                        configuration: .ephemeral,
                        delegate: delegate,
                        delegateQueue: nil
                    )
                }
                session?.invalidateAndCancel()
                return OracleSupport.waitUntil(timeout: .seconds(5)) { weakDelegate == nil }
            },
            // Dispatch sources hold their handlers until replaced or cancelled.
            "dispatch_source_holds_then_cancel_releases": {
                final class Work {
                    func poke() {}
                }
                weak var weakWork: Work?
                let source = DispatchSource.makeTimerSource(queue: .global())
                autoreleasepool {
                    let work = Work()
                    weakWork = work
                    source.setEventHandler { work.poke() }
                    source.schedule(deadline: .now() + 10)
                    source.activate()
                }
                OracleSupport.spinRunLoop(seconds: 0.2)
                let held = weakWork != nil
                source.cancel()
                let released = OracleSupport.waitUntil(timeout: .seconds(2)) { weakWork == nil }
                return held && released
            },
            // A task retains its captures until it completes; cancellation ends a
            // cooperative loop and releases them.
            "task_pins_then_cancel_releases": {
                final class Worker {
                    func work() {}
                }
                weak var weakWorker: Worker?
                var task: Task<Void, Never>?
                autoreleasepool {
                    let worker = Worker()
                    weakWorker = worker
                    task = Task {
                        while !Task.isCancelled {
                            worker.work()
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                    }
                }
                let pinned = OracleSupport.waitUntil(timeout: .seconds(2)) { weakWorker != nil }
                OracleSupport.spinRunLoop(seconds: 0.2)
                let stillPinned = weakWorker != nil
                task?.cancel()
                let released = OracleSupport.waitUntil(timeout: .seconds(3)) { weakWorker == nil }
                return pinned && stillPinned && released
            },
        ]
    }
#endif
