// swift-format-ignore-file
// Correct ownership: parent strongly owns children, the back-reference is weak.
// No strongly-connected component — silent.
final class Parent {
    var children: [Child] = []
}