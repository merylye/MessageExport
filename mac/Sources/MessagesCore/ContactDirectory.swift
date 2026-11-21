import Foundation

/// Maps phone numbers and email addresses to contact names.
public final class ContactDirectory: @unchecked Sendable {
    private var names: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { names.isEmpty }
    public var count: Int { names.count }

    public func add(name: String, handles: [String]) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        for handle in handles {
            let key = HandleNormalizer.key(handle)
            if !key.isEmpty && names[key] == nil {
                names[key] = cleaned
            }
        }
    }

    /// Adds entries from another directory without overwriting existing ones.
    public func merge(_ other: ContactDirectory) {
        for (key, value) in other.names where names[key] == nil {
            names[key] = value
        }
    }

    public func name(for handle: String) -> String? {
        names[HandleNormalizer.key(handle)]
    }

    /// Reads the contacts stored inside an iPhone backup (AddressBook.sqlitedb).
    public static func fromBackup(_ backup: URL) -> ContactDirectory {
        let directory = ContactDirectory()
        let url = BackupLocator.addressBook(in: backup)
        guard FileManager.default.fileExists(atPath: url.path),
              let db = try? SQLiteDB(path: url.path, readOnly: true),
              db.tableExists("ABPerson"), db.tableExists("ABMultiValue") else { return directory }

        var people: [Int64: String] = [:]
        try? db.query("SELECT ROWID, First, Last, Organization FROM ABPerson") { row in
            let first = row.text(1) ?? ""
            let last = row.text(2) ?? ""
            var name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = row.text(3) ?? "" }
            if !name.isEmpty { people[row.int(0)] = name }
        }
        // property 3 = phone, 4 = email
        try? db.query("SELECT record_id, value FROM ABMultiValue WHERE property IN (3, 4) AND value IS NOT NULL") { row in
            if let name = people[row.int(0)], let value = row.text(1) {
                directory.add(name: name, handles: [value])
            }
        }
        return directory
    }
}
