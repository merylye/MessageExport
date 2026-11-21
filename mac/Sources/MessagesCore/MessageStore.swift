import Foundation

public enum MessageSource: Hashable, Sendable {
    /// ~/Library/Messages/chat.db on this Mac.
    case mac
    /// An iPhone backup made by Finder.
    case backup(BackupInfo)
}

public enum MessageStoreError: Error, LocalizedError {
    case needsFullDiskAccess
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .needsFullDiskAccess:
            return "This app needs Full Disk Access to read your messages."
        case .notFound(let path):
            return "No Messages database was found at \(path). Open the Messages app on this Mac and sign in, or choose an iPhone backup instead."
        }
    }
}

struct RawMessage {
    var rowID: Int64
    var guid: String
    var text: String
    var date: Date
    var isFromMe: Bool
    var handle: String?
    var service: String?
    var associatedType: Int64
    var associatedGUID: String?
    var threadOriginatorGUID: String?
    var edited: Bool
    var emoji: String?
    var itemType: Int64
}

struct RawAttachment {
    var storedPath: String?
    var mimeType: String?
    var uti: String?
    var transferName: String?
}

/// Reads conversations and messages from a Messages database (chat.db on a Mac,
/// sms.db in an iPhone backup; both share the same schema).
public final class MessageStore: @unchecked Sendable {
    public let source: MessageSource
    private let db: SQLiteDB
    private let home: URL
    private let tempFolder: URL?
    private let messageColumns: Set<String>
    private let attachmentColumns: Set<String>
    private let chatColumns: Set<String>

    /// Opens the given source. For the Mac database, a snapshot copy is read so the
    /// live database used by the Messages app is never touched.
    public static func open(_ source: MessageSource,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> MessageStore {
        switch source {
        case .mac:
            let live = home.appendingPathComponent("Library/Messages/chat.db")
            try checkReadable(live)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadMyMessages-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: live.path + suffix)
                let to = temp.appendingPathComponent("chat.db" + suffix)
                if FileManager.default.fileExists(atPath: from.path) {
                    try FileManager.default.copyItem(at: from, to: to)
                }
            }
            return try MessageStore(databaseURL: temp.appendingPathComponent("chat.db"),
                                    source: source, home: home, tempFolder: temp, readOnly: false)
        case .backup(let backup):
            if backup.isEncrypted { throw BackupError.encrypted }
            let url = BackupLocator.messagesDatabase(in: backup.url)
            guard FileManager.default.fileExists(atPath: url.path) else { throw BackupError.noMessages }
            try checkReadable(url)
            return try MessageStore(databaseURL: url, source: source, home: home, tempFolder: nil, readOnly: true)
        }
    }

    private static func checkReadable(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Without Full Disk Access, macOS hides the file entirely in some versions.
            let parent = url.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) == nil,
               FileManager.default.fileExists(atPath: parent.path) {
                throw MessageStoreError.needsFullDiskAccess
            }
            throw MessageStoreError.notFound(url.path)
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
        } catch {
            throw MessageStoreError.needsFullDiskAccess
        }
    }

    /// Opens a database file directly. Used by the self-test.
    public init(databaseURL: URL, source: MessageSource, home: URL, tempFolder: URL? = nil, readOnly: Bool = true) throws {
        self.source = source
        self.home = home
        self.tempFolder = tempFolder
        self.db = try SQLiteDB(path: databaseURL.path, readOnly: readOnly)
        self.messageColumns = db.columns(of: "message")
        self.attachmentColumns = db.columns(of: "attachment")
        self.chatColumns = db.columns(of: "chat")
        guard !messageColumns.isEmpty, db.tableExists("chat"), db.tableExists("chat_message_join") else {
            throw SQLiteError.open("This file doesn't look like a Messages database.")
        }
    }

    deinit {
        if let tempFolder {
            try? FileManager.default.removeItem(at: tempFolder)
        }
    }

    private func messageColumn(_ name: String, fallback: String = "NULL") -> String {
        messageColumns.contains(name) ? "m.\(name)" : fallback
    }

    /// Filters out tapbacks and group events (renames, people joining or leaving).
    private var visibleMessageFilter: String {
        "\(messageColumn("associated_message_type", fallback: "0")) = 0 AND \(messageColumn("item_type", fallback: "0")) = 0"
    }

    // MARK: Conversations

    public func loadConversations() throws -> [Conversation] {
        var handles: [Int64: String] = [:]
        try db.query("SELECT ROWID, id FROM handle") { row in
            if let id = row.text(1) { handles[row.int(0)] = id }
        }

        var chatHandles: [Int64: [String]] = [:]
        if db.tableExists("chat_handle_join") {
            try db.query("SELECT chat_id, handle_id FROM chat_handle_join ORDER BY chat_id, handle_id") { row in
                if let handle = handles[row.int(1)] {
                    chatHandles[row.int(0), default: []].append(handle)
                }
            }
        }

        struct Stats { var count: Int; var first: Int64; var last: Int64 }
        var stats: [Int64: Stats] = [:]
        try db.query("""
            SELECT cmj.chat_id, COUNT(*), MIN(m.date), MAX(m.date)
            FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE \(visibleMessageFilter)
            GROUP BY cmj.chat_id
            """) { row in
            stats[row.int(0)] = Stats(count: Int(row.int(1)), first: row.int(2), last: row.int(3))
        }

        let styleColumn = chatColumns.contains("style") ? "style" : "0"
        let serviceColumn = chatColumns.contains("service_name") ? "service_name" : "NULL"
        let nameColumn = chatColumns.contains("display_name") ? "display_name" : "NULL"

        var merged: [String: Conversation] = [:]
        var order: [String] = []
        try db.query("SELECT ROWID, chat_identifier, \(nameColumn), \(serviceColumn), \(styleColumn) FROM chat") { row in
            let chatID = row.int(0)
            guard let stat = stats[chatID], stat.count > 0 else { return }
            let identifier = row.text(1) ?? "Unknown"
            let groupName = row.text(2).flatMap { $0.isEmpty ? nil : $0 }
            let service = row.text(3)
            let style = row.int(4)

            var people: [String] = []
            var seen = Set<String>()
            for handle in chatHandles[chatID] ?? [] where seen.insert(HandleNormalizer.key(handle)).inserted {
                people.append(handle)
            }
            if people.isEmpty { people = [identifier] }
            let isGroup = people.count > 1 || style == 43

            let key: String
            if isGroup {
                key = "group:" + people.map(HandleNormalizer.key).sorted().joined(separator: ",") + "|" + (groupName ?? "")
            } else {
                key = "person:" + HandleNormalizer.key(people[0])
            }

            let first = AppleTime.date(from: stat.first)
            let last = AppleTime.date(from: stat.last)
            if var existing = merged[key] {
                existing.chatIDs.append(chatID)
                existing.messageCount += stat.count
                existing.firstDate = min(existing.firstDate ?? first, first)
                existing.lastDate = max(existing.lastDate ?? last, last)
                if let service, !existing.services.contains(service) { existing.services.append(service) }
                if existing.groupName == nil { existing.groupName = groupName }
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = Conversation(
                    id: key, chatIDs: [chatID], groupName: groupName, handles: people, isGroup: isGroup,
                    messageCount: stat.count, firstDate: first, lastDate: last,
                    services: service.map { [$0] } ?? []
                )
            }
        }

        return order.compactMap { merged[$0] }
            .sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    public static func applyContacts(_ contacts: ContactDirectory, to conversations: [Conversation]) -> [Conversation] {
        conversations.map { conversation in
            var copy = conversation
            for handle in conversation.handles {
                if let name = contacts.name(for: handle) { copy.participantNames[handle] = name }
            }
            return copy
        }
    }

    // MARK: Messages

    /// Returns visible messages in [start, end] plus every tapback sent on or after `start`
    /// (so a reaction added after the end date to an in-range message is still counted).
    func fetchMessages(chatIDs: [Int64], start: Date?, end: Date?) throws -> (messages: [RawMessage], reactions: [RawMessage]) {
        guard !chatIDs.isEmpty else { return ([], []) }
        let ids = chatIDs.map(String.init).joined(separator: ",")
        var params: [SQLValue] = []
        var dateFilter = ""
        if let start {
            dateFilter = "AND m.date >= ?"
            params.append(.int(AppleTime.raw(from: start, nanoseconds: usesNanoseconds)))
        }

        let sql = """
            SELECT m.ROWID, m.guid, m.text, \(messageColumn("attributedBody")), m.date, m.is_from_me, h.id,
                   \(messageColumn("service")), \(messageColumn("associated_message_type", fallback: "0")),
                   \(messageColumn("associated_message_guid")), \(messageColumn("thread_originator_guid")),
                   \(messageColumn("date_edited", fallback: "0")), \(messageColumn("associated_message_emoji")),
                   \(messageColumn("item_type", fallback: "0"))
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(ids)) \(dateFilter)
            ORDER BY m.date, m.ROWID
            """

        var seen = Set<Int64>()
        var messages: [RawMessage] = []
        var reactions: [RawMessage] = []
        try db.query(sql, params) { row in
            let rowID = row.int(0)
            guard seen.insert(rowID).inserted else { return }
            var text = row.text(2) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let body = row.blob(3) {
                text = AttributedBodyDecoder.text(from: body) ?? ""
            }
            let message = RawMessage(
                rowID: rowID,
                guid: row.text(1) ?? String(rowID),
                text: text,
                date: AppleTime.date(from: row.int(4)),
                isFromMe: row.int(5) != 0,
                handle: row.text(6),
                service: row.text(7),
                associatedType: row.optionalInt(8) ?? 0,
                associatedGUID: row.text(9),
                threadOriginatorGUID: row.text(10),
                edited: (row.optionalInt(11) ?? 0) != 0,
                emoji: row.text(12),
                itemType: row.optionalInt(13) ?? 0
            )
            if message.associatedType != 0 {
                reactions.append(message)
            } else if message.itemType == 0 {
                if let end, message.date > end { return }
                messages.append(message)
            }
        }
        return (messages, reactions)
    }

    func fetchAttachments(chatIDs: [Int64]) throws -> [Int64: [RawAttachment]] {
        guard !chatIDs.isEmpty, db.tableExists("message_attachment_join"), !attachmentColumns.isEmpty else { return [:] }
        let ids = chatIDs.map(String.init).joined(separator: ",")
        func col(_ name: String) -> String { attachmentColumns.contains(name) ? "a.\(name)" : "NULL" }
        var result: [Int64: [RawAttachment]] = [:]
        var seen = Set<String>()
        try db.query("""
            SELECT maj.message_id, maj.attachment_id, \(col("filename")), \(col("mime_type")), \(col("uti")), \(col("transfer_name"))
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            JOIN chat_message_join cmj ON cmj.message_id = maj.message_id
            WHERE cmj.chat_id IN (\(ids))
            ORDER BY maj.message_id, maj.attachment_id
            """) { row in
            guard seen.insert("\(row.int(0))-\(row.int(1))").inserted else { return }
            result[row.int(0), default: []].append(RawAttachment(
                storedPath: row.text(2), mimeType: row.text(3), uti: row.text(4), transferName: row.text(5)
            ))
        }
        return result
    }

    /// Where an attachment's file lives on disk, if anywhere.
    func fileURL(for attachment: RawAttachment) -> URL? {
        guard let stored = attachment.storedPath, !stored.isEmpty else { return nil }
        switch source {
        case .mac:
            if stored.hasPrefix("~/") {
                return home.appendingPathComponent(String(stored.dropFirst(2)))
            }
            return URL(fileURLWithPath: stored)
        case .backup(let backup):
            return BackupLocator.attachmentURL(in: backup.url, storedPath: stored)
        }
    }

    private lazy var usesNanoseconds: Bool = {
        var maxDate: Int64 = 0
        try? db.query("SELECT MAX(date) FROM message") { row in maxDate = row.int(0) }
        return maxDate > 1_000_000_000_000
    }()
}
