// swift-format-ignore-file: NoLeadingUnderscores
// `__aepbEncode`/`__aepbDecode` are AemiProtobuf's protocol requirements, named by it.

//  The facts cache's payload on AemiProtobuf's wire (analyzerkit roadmap 0017), written by hand with analyzerkit's field
//  helpers so the models keep their `let`s and enumerations. An enumeration with associated values is a message of its
//  case's name and its payload. Sets are written sorted, so a payload is byte-stable. Field numbers are the format: never
//  renumber one, and give a new field a new number.

public import AemiProtobuf
public import AemiProtobufCore
import CorpusScan

extension ExtractedFacts: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        try writer.field(1, facts)
        writer.field(2, degraded)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var facts: FileFacts?
        var degraded: String?
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: facts = try reader.readMessage(FileFacts.self)
            case 2: degraded = try reader.readString()
            default: try reader.skipField(tag)
            }
        }
        return Self(facts: facts, degraded: degraded)
    }
}

extension FileFacts: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        writer.field(1, path)
        try writer.field(2, types)
        try writer.field(3, directives)
        try writer.field(4, regionSpans)
        writer.field(5, isTestCode)
        writer.field(6, isGenerated)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var path = ""
        var types: [TypeFacts] = []
        var directives: [SuppressionDirective] = []
        var spans: [RegionSpanFact] = []
        var isTestCode = false
        var isGenerated = false
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: path = try reader.readString()
            case 2: types.append(try reader.readMessage(TypeFacts.self))
            case 3: directives.append(try reader.readMessage(SuppressionDirective.self))
            case 4: spans.append(try reader.readMessage(RegionSpanFact.self))
            case 5: isTestCode = try reader.readBool()
            case 6: isGenerated = try reader.readBool()
            default: try reader.skipField(tag)
            }
        }
        return Self(
            path: path, types: types, directives: directives, regionSpans: spans, isTestCode: isTestCode,
            isGenerated: isGenerated)
    }
}

extension TypeFacts: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        writer.field(1, name)
        writer.field(2, isReferenceType)
        writer.field(3, memberNames.sorted())
        writer.field(4, inheritedTypeNames.sorted())
        writer.field(5, methodNames.sorted())
        writer.field(6, attributeNames.sorted())
        try writer.field(7, deadWeakCaptures)
        try writer.field(8, storedProperties)
        try writer.field(9, storedClosures)
        try writer.field(10, apiCalls)
        try writer.field(11, taskSpawns)
        try writer.field(12, releaseSites)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var name = ""
        var isReferenceType: Bool?
        var members: Set<String> = []
        var inherited: Set<String> = []
        var methods: Set<String> = []
        var attributes: Set<String> = []
        var deadWeak: [SourcePosition] = []
        var properties: [StoredPropertyFact] = []
        var closures: [StoredClosureFact] = []
        var calls: [APICallFact] = []
        var spawns: [TaskSpawnFact] = []
        var releases: [ReleaseSite] = []
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: name = try reader.readString()
            case 2: isReferenceType = try reader.readBool()
            case 3: members.insert(try reader.readString())
            case 4: inherited.insert(try reader.readString())
            case 5: methods.insert(try reader.readString())
            case 6: attributes.insert(try reader.readString())
            case 7: deadWeak.append(try reader.readMessage(SourcePosition.self))
            case 8: properties.append(try reader.readMessage(StoredPropertyFact.self))
            case 9: closures.append(try reader.readMessage(StoredClosureFact.self))
            case 10: calls.append(try reader.readMessage(APICallFact.self))
            case 11: spawns.append(try reader.readMessage(TaskSpawnFact.self))
            case 12: releases.append(try reader.readMessage(ReleaseSite.self))
            default: try reader.skipField(tag)
            }
        }
        return Self(
            name: name, isReferenceType: isReferenceType, memberNames: members, inheritedTypeNames: inherited,
            methodNames: methods, attributeNames: attributes, deadWeakCaptures: deadWeak,
            storedProperties: properties, storedClosures: closures, apiCalls: calls, taskSpawns: spawns,
            releaseSites: releases)
    }
}

extension SourcePosition: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        writer.field(1, line)
        writer.field(2, column)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var line = 0
        var column = 0
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: line = try reader.readInt()
            case 2: column = try reader.readInt()
            default: try reader.skipField(tag)
            }
        }
        return Self(line: line, column: column)
    }
}

extension RegionSpanFact: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        writer.field(1, startLine)
        writer.field(2, endLine)
        writer.field(3, Int(region))
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var start = 0
        var end = 0
        var region = 0
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: start = try reader.readInt()
            case 2: end = try reader.readInt()
            case 3: region = try reader.readInt()
            default: try reader.skipField(tag)
            }
        }
        return Self(startLine: start, endLine: end, region: UInt8(truncatingIfNeeded: region))
    }
}

extension StoredPropertyFact: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        writer.field(1, name)
        writer.field(2, strength)
        writer.field(3, referencedTypeNames)
        writer.field(4, hasPublishedAttribute)
        writer.field(5, hasTransientAttribute)
        try writer.field(6, position)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var name = ""
        var strength = ReferenceStrength.strong
        var referenced: [String] = []
        var published = false
        var transient = false
        var position = SourcePosition(line: 0, column: 0)
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: name = try reader.readString()
            case 2: strength = try reader.readEnum(ReferenceStrength.self)
            case 3: referenced.append(try reader.readString())
            case 4: published = try reader.readBool()
            case 5: transient = try reader.readBool()
            case 6: position = try reader.readMessage(SourcePosition.self)
            default: try reader.skipField(tag)
            }
        }
        return Self(
            name: name, strength: strength, referencedTypeNames: referenced, hasPublishedAttribute: published,
            hasTransientAttribute: transient, position: position)
    }
}

extension StoredClosureFact: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        try writer.field(1, position)
        writer.field(2, targetMember)
        try writer.field(3, selfCapture)
        writer.field(4, isMethodReference)
        writer.field(5, ownedChild)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var position = SourcePosition(line: 0, column: 0)
        var target = ""
        var capture = SelfCaptureKind.none
        var isMethodReference = false
        var ownedChild: String?
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: position = try reader.readMessage(SourcePosition.self)
            case 2: target = try reader.readString()
            case 3: capture = try reader.readMessage(SelfCaptureKind.self)
            case 4: isMethodReference = try reader.readBool()
            case 5: ownedChild = try reader.readString()
            default: try reader.skipField(tag)
            }
        }
        return Self(
            position: position, targetMember: target, selfCapture: capture, isMethodReference: isMethodReference,
            ownedChild: ownedChild)
    }
}

extension TaskSpawnFact: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        try writer.field(1, position)
        try writer.field(2, selfCapture)
        writer.field(3, hasNonterminatingBody)
        try writer.field(4, consumption)
        writer.field(5, bodyAwaits)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var position = SourcePosition(line: 0, column: 0)
        var capture = SelfCaptureKind.none
        var nonterminating = false
        var consumption = ResultConsumption.other
        var awaits = false
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: position = try reader.readMessage(SourcePosition.self)
            case 2: capture = try reader.readMessage(SelfCaptureKind.self)
            case 3: nonterminating = try reader.readBool()
            case 4: consumption = try reader.readMessage(ResultConsumption.self)
            case 5: awaits = try reader.readBool()
            default: try reader.skipField(tag)
            }
        }
        return Self(
            position: position, selfCapture: capture, hasNonterminatingBody: nonterminating, consumption: consumption,
            bodyAwaits: awaits)
    }
}

extension ReleaseSite: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        writer.field(1, kind)
        writer.field(2, inDeinit)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var kind = Kind.invalidate
        var inDeinit = false
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: kind = try reader.readEnum(Kind.self)
            case 2: inDeinit = try reader.readBool()
            default: try reader.skipField(tag)
            }
        }
        return Self(kind: kind, inDeinit: inDeinit)
    }
}

extension APICallFact: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        try writer.appendMessage(field: 1) { writer throws(WireError) in
            let (name, payload) = Self.wire(kind)
            writer.field(1, name)
            writer.field(2, payload)
        }
        try writer.field(2, position)
        writer.field(3, repeats)
        writer.field(4, targetIsSelf)
        writer.field(5, receiverIsSelfMember)
        writer.field(6, receiverRootMember)
        writer.field(7, upstreamFiniteness)
        writer.field(8, upstreamRootMember)
        try writer.field(9, closureSelfCapture)
        writer.field(10, selfCaptureViaNestedListOnly)
        try writer.field(11, consumption)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var kind = Kind.timerScheduledBlock
        var position = SourcePosition(line: 0, column: 0)
        var repeats: Bool?
        var targetIsSelf = false
        var receiverIsSelfMember = false
        var receiverRootMember: String?
        var upstream = UpstreamFiniteness.unknown
        var upstreamRootMember: String?
        var capture: SelfCaptureKind?
        var nestedOnly = false
        var consumption = ResultConsumption.other
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1:
                kind = try reader.readMessage { reader throws(WireError) in
                    var name = ""
                    var payload = ""
                    try reader.forEachField { tag, reader throws(WireError) in
                        switch tag.fieldNumber {
                        case 1: name = try reader.readString()
                        case 2: payload = try reader.readString()
                        default: try reader.skipField(tag)
                        }
                    }
                    guard let kind = Self.kind(name, payload) else { throw .missingRequired(path: "Kind.\(name)") }
                    return kind
                }
            case 2: position = try reader.readMessage(SourcePosition.self)
            case 3: repeats = try reader.readBool()
            case 4: targetIsSelf = try reader.readBool()
            case 5: receiverIsSelfMember = try reader.readBool()
            case 6: receiverRootMember = try reader.readString()
            case 7: upstream = try reader.readEnum(UpstreamFiniteness.self)
            case 8: upstreamRootMember = try reader.readString()
            case 9: capture = try reader.readMessage(SelfCaptureKind.self)
            case 10: nestedOnly = try reader.readBool()
            case 11: consumption = try reader.readMessage(ResultConsumption.self)
            default: try reader.skipField(tag)
            }
        }
        return Self(
            kind: kind, position: position, repeats: repeats, targetIsSelf: targetIsSelf,
            receiverIsSelfMember: receiverIsSelfMember, receiverRootMember: receiverRootMember,
            upstreamFiniteness: upstream, upstreamRootMember: upstreamRootMember, closureSelfCapture: capture,
            selfCaptureViaNestedListOnly: nestedOnly, consumption: consumption)
    }

    private static func wire(_ kind: Kind) -> (String, String?) {
        switch kind {
        case .timerScheduledBlock: ("timerScheduledBlock", nil)
        case .timerScheduledTarget: ("timerScheduledTarget", nil)
        case .displayLinkTarget: ("displayLinkTarget", nil)
        case .notificationAddObserverBlock: ("notificationAddObserverBlock", nil)
        case .combineSink: ("combineSink", nil)
        case .combineAssignOn: ("combineAssignOn", nil)
        case .kvoObserve: ("kvoObserve", nil)
        case .periodicTimeObserver: ("periodicTimeObserver", nil)
        case .urlSessionWithDelegate: ("urlSessionWithDelegate", nil)
        case .dispatchSourceHandler: ("dispatchSourceHandler", nil)
        case .scriptMessageHandlerAdd: ("scriptMessageHandlerAdd", nil)
        case .userTokenProducer(let callee): ("userTokenProducer", callee)
        case .userSinkWrapper(let callee): ("userSinkWrapper", callee)
        case .reactiveSubscription(let callee): ("reactiveSubscription", callee)
        }
    }

    private static func kind(_ name: String, _ payload: String) -> Kind? {
        switch name {
        case "timerScheduledBlock": .timerScheduledBlock
        case "timerScheduledTarget": .timerScheduledTarget
        case "displayLinkTarget": .displayLinkTarget
        case "notificationAddObserverBlock": .notificationAddObserverBlock
        case "combineSink": .combineSink
        case "combineAssignOn": .combineAssignOn
        case "kvoObserve": .kvoObserve
        case "periodicTimeObserver": .periodicTimeObserver
        case "urlSessionWithDelegate": .urlSessionWithDelegate
        case "dispatchSourceHandler": .dispatchSourceHandler
        case "scriptMessageHandlerAdd": .scriptMessageHandlerAdd
        case "userTokenProducer": .userTokenProducer(payload)
        case "userSinkWrapper": .userSinkWrapper(payload)
        case "reactiveSubscription": .reactiveSubscription(payload)
        default: nil
        }
    }
}

extension SelfCaptureKind: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        switch self {
        case .none: writer.field(1, "none")
        case .strong(let implicit):
            writer.field(1, "strong")
            writer.field(2, implicit)
        case .weak: writer.field(1, "weak")
        case .unowned: writer.field(1, "unowned")
        }
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var name = ""
        var implicit = false
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: name = try reader.readString()
            case 2: implicit = try reader.readBool()
            default: try reader.skipField(tag)
            }
        }
        switch name {
        case "none": return .none
        case "strong": return .strong(implicit: implicit)
        case "weak": return .weak
        case "unowned": return .unowned
        default: throw .missingRequired(path: "SelfCaptureKind.\(name)")
        }
    }
}

extension ResultConsumption: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        switch self {
        case .discarded: writer.field(1, "discarded")
        case .storedToSelfMember(let name):
            writer.field(1, "storedToSelfMember")
            writer.field(2, name)
        case .storedToLocalOnly(let name):
            writer.field(1, "storedToLocalOnly")
            writer.field(2, name)
        case .storedToLocalEscaping(let name):
            writer.field(1, "storedToLocalEscaping")
            writer.field(2, name)
        case .chainedStoreIn(let memberOfSelf):
            writer.field(1, "chainedStoreIn")
            writer.field(3, memberOfSelf)
        case .chainedStoreInCapturedLocal(let name):
            writer.field(1, "chainedStoreInCapturedLocal")
            writer.field(2, name)
        case .returned: writer.field(1, "returned")
        case .other: writer.field(1, "other")
        }
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var name = ""
        var payload = ""
        var flag = false
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: name = try reader.readString()
            case 2: payload = try reader.readString()
            case 3: flag = try reader.readBool()
            default: try reader.skipField(tag)
            }
        }
        switch name {
        case "discarded": return .discarded
        case "storedToSelfMember": return .storedToSelfMember(payload)
        case "storedToLocalOnly": return .storedToLocalOnly(payload)
        case "storedToLocalEscaping": return .storedToLocalEscaping(payload)
        case "chainedStoreIn": return .chainedStoreIn(memberOfSelf: flag)
        case "chainedStoreInCapturedLocal": return .chainedStoreInCapturedLocal(payload)
        case "returned": return .returned
        case "other": return .other
        default: throw .missingRequired(path: "ResultConsumption.\(name)")
        }
    }
}

extension SuppressionDirective: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        for rule in rules.sorted(by: { $0.rawValue < $1.rawValue }) { writer.field(1, rule) }
        writer.field(2, Self.wireName(kind))
        writer.field(3, line)
        writer.field(4, reason)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var rules: Set<RuleID> = []
        var kind = Kind.accept
        var line = 0
        var reason: String?
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: rules.insert(try reader.readEnum(RuleID.self))
            case 2:
                let name = try reader.readString()
                guard let known = Self.kind(wireName: name) else { throw .missingRequired(path: "Kind.\(name)") }
                kind = known
            case 3: line = try reader.readInt()
            case 4: reason = try reader.readString()
            default: try reader.skipField(tag)
            }
        }
        return Self(rules: rules, kind: kind, line: line, reason: reason)
    }

    private static func wireName(_ kind: Kind) -> String {
        switch kind {
        case .accept: "accept"
        case .acceptThis: "acceptThis"
        case .acceptNext: "acceptNext"
        case .regionDisable: "regionDisable"
        case .regionEnable: "regionEnable"
        }
    }

    private static func kind(wireName: String) -> Kind? {
        switch wireName {
        case "accept": .accept
        case "acceptThis": .acceptThis
        case "acceptNext": .acceptNext
        case "regionDisable": .regionDisable
        case "regionEnable": .regionEnable
        default: nil
        }
    }
}
