// One half of a cross-file mutual strong reference: OrderService owns
// PaymentService, PaymentService (other file) owns OrderService back.
final class OrderService {
    var payments: PaymentService? // arcleak-expect: mutual-strong-properties

    func total() -> Int { 0 }
}
