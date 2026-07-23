// swift-format-ignore-file
// Three-file cycle: Alpha → Beta → Gamma → Alpha. One finding, anchored here
// (smallest type name), with the full path in the message.
final class Alpha {
    var beta: Beta? // #al:expect mutual-strong-properties
}