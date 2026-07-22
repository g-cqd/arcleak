import Foundation

// Transient escaping closures: retained only until they run once. Strong self
// here is deferred deallocation, not a leak — flagging it is cargo cult.
final class Transient {
    var value = 0

    func refresh() {
        DispatchQueue.main.async {
            self.value += 1
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            self.value += 2
        }
    }

    func fetch(session: URLSession, url: URL) {
        session.dataTask(with: url) { data, _, _ in
            self.value = data?.count ?? 0
        }.resume()
    }
}
