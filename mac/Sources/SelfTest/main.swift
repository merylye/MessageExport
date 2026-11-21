import Foundation
import MessagesCore

// Builds a small fake Messages database that mimics the real schema, exports it,
// and checks the results. Run with: swift run SelfTest

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("  ok    \(message)")
    } else {
        print("  FAIL  \(message)")
        failures += 1
    }
}

/// An attributedBody blob shaped like the ones newer macOS versions write.
func attributedBody(_ text: String) -> Data {
    var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
    bytes += [0x12] + Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8)
    bytes += [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
    let utf8 = Array(text.utf8)
    if utf8.count < 0x80 {
        bytes.append(UInt8(utf8.count))
    } else {
        bytes += [0x81, UInt8(utf8.count & 0xFF), UInt8((utf8.count >> 8) & 0xFF)]
    }
    bytes += utf8
    bytes += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01]
    return Data(bytes)
}

func appleNanos(_ iso: String) -> Int64 {
    let date = ISO8601DateFormatter().date(from: iso)!
    return Int64((date.timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("dmm-selftest-\(UUID().uuidString)")
let home = root.appendingPathComponent("home")
try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
let dbURL = root.appendingPathComponent("chat.db")

print("Attributed body decoding")
check(AttributedBodyDecoder.text(from: attributedBody("hello there")) == "hello there", "short text")
let long = String(repeating: "long message 🎉 ", count: 40)
check(AttributedBodyDecoder.text(from: attributedBody(long)) == long, "text longer than 127 bytes")
check(AttributedBodyDecoder.text(from: Data([1, 2, 3])) == nil, "garbage returns nil")

print("Building fake database at \(dbURL.path)")
do {
    let db = try SQLiteDB(path: dbURL.path, readOnly: false)
    try db.execute("""
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT, style INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER,
            date INTEGER, is_from_me INTEGER, service TEXT, associated_message_type INTEGER DEFAULT 0,
            associated_message_guid TEXT, thread_originator_guid TEXT, date_edited INTEGER DEFAULT 0,
            associated_message_emoji TEXT, item_type INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, uti TEXT, transfer_name TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);

        INSERT INTO handle VALUES (1, '+14125551234', 'iMessage'), (2, '4125551234', 'SMS'), (3, 'friend@example.com', 'iMessage');
        -- Alex over iMessage and SMS (should merge), plus a group chat.
        INSERT INTO chat VALUES (1, 'iMessage;-;+14125551234', '+14125551234', '', 'iMessage', 45),
                                (2, 'SMS;-;4125551234', '4125551234', '', 'SMS', 45),
                                (3, 'iMessage;+;chat123', 'chat123', 'Trip Planning', 'iMessage', 43);
        INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (3, 1), (3, 3);
        """)

    let rows: [(Int64, String, String?, Data?, Int64, String, Int64, String, Int64, String?, String?, Int64)] = [
        // rowid, guid, text, body, handle, date, from_me, service, assoc_type, assoc_guid, thread_orig, item_type
        (1, "G1", "Hey, are you free Saturday?", nil, 1, "2024-01-10T15:00:00Z", 0, "iMessage", 0, nil, nil, 0),
        (2, "G2", nil, attributedBody("Yes! Brunch?"), 1, "2024-01-10T15:05:00Z", 1, "iMessage", 0, nil, nil, 0),
        (3, "G3", "Sounds good, \"Cafe\", 11am", nil, 2, "2024-06-01T12:00:00Z", 0, "SMS", 0, nil, nil, 0),
        (4, "G4", "\u{FFFC}", nil, 2, "2024-06-02T12:00:00Z", 1, "SMS", 0, nil, nil, 0),
        (5, "R1", "Loved “Yes! Brunch?”", nil, 1, "2025-03-01T00:00:00Z", 0, "iMessage", 2000, "p:0/G2", nil, 0),
        (6, "R2", "Liked “Hey”", nil, 1, "2024-01-10T16:00:00Z", 1, "iMessage", 2001, "p:0/G1", nil, 0),
        (7, "R3", "Removed a like", nil, 1, "2024-01-10T16:01:00Z", 1, "iMessage", 3001, "p:0/G1", nil, 0),
        (8, "G5", "Group hello", nil, 3, "2024-02-01T10:00:00Z", 0, "iMessage", 0, nil, nil, 0),
        (9, "G6", "Replying in thread", nil, 1, "2024-02-01T10:05:00Z", 0, "iMessage", 0, nil, "G5", 0),
        (10, "G7", nil, nil, 0, "2024-02-01T10:06:00Z", 1, "iMessage", 0, nil, nil, 2), // renamed the group
    ]
    for r in rows {
        try db.run("""
            INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me, service,
                associated_message_type, associated_message_guid, thread_originator_guid, item_type)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.int(r.0), .text(r.1), r.2.map { SQLValue.text($0) } ?? SQLValue.null, r.3.map { SQLValue.blob($0) } ?? SQLValue.null,
                  .int(r.4), .int(appleNanos(r.5)), .int(r.6), .text(r.7), .int(r.8),
                  r.9.map { SQLValue.text($0) } ?? SQLValue.null, r.10.map { SQLValue.text($0) } ?? SQLValue.null, .int(r.11)])
    }
    try db.execute("""
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,1),(1,2),(2,3),(2,4),(1,5),(1,6),(1,7),(3,8),(3,9),(3,10);
        INSERT INTO attachment VALUES (1, 'A1', '~/Library/Messages/Attachments/ab/01/A1/IMG_0001.jpeg', 'image/jpeg', 'public.jpeg', 'IMG_0001.jpeg');
        INSERT INTO message_attachment_join VALUES (4, 1);
        """)
}

// Put the attachment file where the database says it is.
let attachmentFile = home.appendingPathComponent("Library/Messages/Attachments/ab/01/A1/IMG_0001.jpeg")
try FileManager.default.createDirectory(at: attachmentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("fake jpeg".utf8).write(to: attachmentFile)

print("Loading conversations")
let store = try MessageStore(databaseURL: dbURL, source: .mac, home: home)
let contacts = ContactDirectory()
contacts.add(name: "Alex Kim", handles: ["(412) 555-1234"])
var conversations = MessageStore.applyContacts(contacts, to: try store.loadConversations())
check(conversations.count == 2, "iMessage and SMS chats with the same person merge (2 conversations, got \(conversations.count))")
let alex = conversations.first { !$0.isGroup }!
let group = conversations.first { $0.isGroup }!
check(alex.title == "Alex Kim", "contact name resolves across number formats (got \(alex.title))")
check(alex.messageCount == 4, "tapbacks aren't counted as messages (got \(alex.messageCount))")
check(group.title == "Trip Planning", "group chat uses its name")
check(group.messageCount == 2, "group events aren't counted as messages (got \(group.messageCount))")

print("Exporting with a different range per conversation")
let outDir = root.appendingPathComponent("out")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let iso = ISO8601DateFormatter()
let summary = try Exporter.export(
    requests: [
        ExportRequest(conversation: alex, start: nil, end: nil),
        ExportRequest(conversation: group, start: iso.date(from: "2024-02-01T10:03:00Z"), end: iso.date(from: "2024-02-02T00:00:00Z")),
    ],
    store: store, contacts: contacts,
    options: ExportOptions(writeCSV: true, writeJSON: true, attachments: .copy),
    into: outDir
)
check(summary.conversations == 2, "two conversations exported")
check(summary.messages == 5, "five messages exported: 4 + 1 in the group's range (got \(summary.messages))")
check(summary.attachmentsCopied == 1, "one attachment copied")

struct Doc: Decodable {
    struct Msg: Decodable {
        let text: String
        let sender: String
        let reactions: [Reaction]
        let attachments: [Att]
        let replyTo: String?
    }
    struct Reaction: Decodable { let sender: String; let reaction: String }
    struct Att: Decodable { let type: String; let path: String? }
    let messages: [Msg]
}
let alexDoc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: summary.folder.appendingPathComponent("Alex Kim.json")))
check(alexDoc.messages.map(\.text) == ["Hey, are you free Saturday?", "Yes! Brunch?", "Sounds good, \"Cafe\", 11am", ""],
      "texts in order, including attributedBody text (got \(alexDoc.messages.map(\.text)))")
check(alexDoc.messages[1].reactions.first?.reaction == "loved", "reaction added after the message is attached to it")
check(alexDoc.messages[0].reactions.isEmpty, "removed reaction is dropped")
check(alexDoc.messages[0].sender == "Alex Kim" && alexDoc.messages[1].sender == "Me", "senders resolve")
check(alexDoc.messages[3].attachments.first?.path?.hasPrefix("attachments/Alex Kim/") == true, "attachment path recorded")

let groupDoc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: summary.folder.appendingPathComponent("Trip Planning.json")))
check(groupDoc.messages.count == 1 && groupDoc.messages[0].replyTo == "G5", "group range filter and thread reply")

let csv = try String(contentsOf: summary.folder.appendingPathComponent("Alex Kim.csv"), encoding: .utf8)
check(csv.contains("\"Sounds good, \"\"Cafe\"\", 11am\""), "CSV escapes quotes and commas")

print("Exporting with attachments as type only")
let typeOnly = try Exporter.export(
    requests: [ExportRequest(conversation: alex, start: nil, end: nil)],
    store: store, contacts: contacts,
    options: ExportOptions(writeCSV: true, writeJSON: true, attachments: .typeOnly),
    into: outDir
)
let typeDoc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: typeOnly.folder.appendingPathComponent("Alex Kim.json")))
check(typeDoc.messages[3].attachments.first?.type == "image/jpeg" && typeDoc.messages[3].attachments.first?.path == nil,
      "type-only export records just the file type")
check(!FileManager.default.fileExists(atPath: typeOnly.folder.appendingPathComponent("attachments").path), "no files copied")

print("Backup file hashing")
let smsURL = BackupLocator.messagesDatabase(in: URL(fileURLWithPath: "/backup"))
check(smsURL.lastPathComponent == "3d0d7e5fb2ce288813306e4d4636395e047a3d28", "sms.db file id matches the known hash")

try? FileManager.default.removeItem(at: root)
print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
