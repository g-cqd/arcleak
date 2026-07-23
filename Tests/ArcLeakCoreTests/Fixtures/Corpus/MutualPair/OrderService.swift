// swift-format-ignore-file
// One half of a cross-file mutual strong reference: OrderService owns
// PaymentService, PaymentService (other file) owns OrderService back.
final class OrderService {
    var payments: PaymentService? // #al:expect mutual-strong-properties

    func total() -> Int { 0 }
}