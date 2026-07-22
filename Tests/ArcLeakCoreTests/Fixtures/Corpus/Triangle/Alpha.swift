// Three-file cycle: Alpha → Beta → Gamma → Alpha. One finding, anchored here
// (smallest type name), with the full path in the message.
final class Alpha {
    var beta: Beta? // arcleak-expect: mutual-strong-properties
}
