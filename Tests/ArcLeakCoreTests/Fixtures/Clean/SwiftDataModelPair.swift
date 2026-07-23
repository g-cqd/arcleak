// swift-format-ignore-file
// SwiftData @Model pair with an inverse relationship: the macro rewrites
// stored properties into accessors over managed backing storage, so the
// mutual "strong" links are not ARC edges.
import Foundation
import SwiftData

@Model
final class CachedSource {
    var sourceId: String

    @Relationship(deleteRule: .cascade, inverse: \CachedTirage.source)
    var tirages: [CachedTirage]

    init(sourceId: String, tirages: [CachedTirage] = []) {
        self.sourceId = sourceId
        self.tirages = tirages
    }
}

@Model
final class CachedTirage {
    var compositeId: String
    var source: CachedSource?

    init(compositeId: String) {
        self.compositeId = compositeId
    }
}
