import Foundation

/// One conversation as the user sees it. Chats with the same people over iMessage
/// and SMS are merged into one conversation.
public struct Conversation: Identifiable, Hashable, Sendable {
    public let id: String
    public var chatIDs: [Int64]
    public var groupName: String?
    public var handles: [String]
    public var isGroup: Bool
    public var messageCount: Int
    public var firstDate: Date?
    public var lastDate: Date?
    public var services: [String]

    /// Filled in after contacts are loaded.
    public var participantNames: [String: String] = [:]

    public func name(for handle: String) -> String {
        participantNames[handle] ?? handle
    }

    public var title: String {
        if let groupName, !groupName.isEmpty { return groupName }
        if handles.isEmpty { return "Unknown" }
        return handles.map { name(for: $0) }.joined(separator: ", ")
    }

    public var subtitle: String {
        let people = handles.joined(separator: ", ")
        return isGroup ? "Group · \(people)" : people
    }
}

public enum AttachmentMode: String, CaseIterable, Codable, Sendable {
    /// Record only the file type of each attachment.
    case typeOnly
    /// Copy attachment files into the export folder.
    case copy
}

public struct ExportOptions: Sendable {
    public var writeCSV: Bool
    public var writeJSON: Bool
    public var attachments: AttachmentMode

    public init(writeCSV: Bool = true, writeJSON: Bool = true, attachments: AttachmentMode = .typeOnly) {
        self.writeCSV = writeCSV
        self.writeJSON = writeJSON
        self.attachments = attachments
    }
}

public struct ExportRequest: Sendable {
    public var conversation: Conversation
    /// nil means no lower bound.
    public var start: Date?
    /// nil means no upper bound. Inclusive.
    public var end: Date?

    public init(conversation: Conversation, start: Date?, end: Date?) {
        self.conversation = conversation
        self.start = start
        self.end = end
    }
}

public struct ExportedAttachment: Codable, Sendable {
    /// Always present, e.g. "image/jpeg" or "heic".
    public var type: String
    /// Only present when attachments are copied.
    public var filename: String?
    /// Path relative to the export folder, only when copied.
    public var path: String?
    /// True when the file was supposed to be copied but wasn't found on disk
    /// (for example, it lives only in iCloud).
    public var missing: Bool?
}

public struct ExportedReaction: Codable, Sendable {
    public var sender: String
    public var reaction: String
}

public struct ExportedMessage: Codable, Sendable {
    public var id: String
    public var timestamp: String
    public var sender: String
    public var senderHandle: String?
    public var isFromMe: Bool
    public var text: String
    public var service: String?
    public var attachments: [ExportedAttachment]
    public var reactions: [ExportedReaction]
    public var replyTo: String?
    public var edited: Bool
}

public struct ExportedParticipant: Codable, Sendable {
    public var handle: String
    public var name: String?
}

public struct ExportedConversation: Codable, Sendable {
    public var conversation: String
    public var isGroup: Bool
    public var participants: [ExportedParticipant]
    public var rangeStart: String?
    public var rangeEnd: String?
    public var exportedAt: String
    public var messageCount: Int
    public var messages: [ExportedMessage]
}

public struct ExportSummary: Sendable {
    public var folder: URL
    public var conversations: Int
    public var messages: Int
    public var attachmentsCopied: Int
    public var attachmentsMissing: Int
}

enum AppleTime {
    /// Seconds between 1970-01-01 and 2001-01-01.
    static let offset: TimeInterval = 978_307_200

    static func date(from raw: Int64) -> Date {
        // Since macOS 10.13 / iOS 11 the value is in nanoseconds; before that, seconds.
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSince1970: seconds + offset)
    }

    static func raw(from date: Date, nanoseconds: Bool) -> Int64 {
        let seconds = date.timeIntervalSince1970 - offset
        return nanoseconds ? Int64(seconds * 1_000_000_000) : Int64(seconds)
    }
}

public enum HandleNormalizer {
    /// Turns "+1 (412) 555-1234" and "4125551234" into the same key, and lowercases emails.
    public static func key(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed.lowercased() }
        let digits = trimmed.filter(\.isNumber)
        if digits.isEmpty { return trimmed.lowercased() }
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }
}
