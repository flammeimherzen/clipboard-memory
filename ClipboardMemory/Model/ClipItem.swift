import Foundation

struct PixelSize: Codable, Hashable, Sendable {
    var width: Double
    var height: Double
}

struct SourceApp: Equatable, Sendable {
    var bundleID: String?
    var name: String?
}

struct ClipItem: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    var text: String?
    var imageFileName: String?
    var textFileName: String?
    var pixelSize: PixelSize?
    let contentHash: String
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var lastUsedAt: Date
    var isPinned: Bool
}

extension ClipItem: Equatable {
    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension ClipItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct DayArchive: Identifiable, Sendable {
    var id: String
    var date: Date
    var items: [ClipItem]
}
