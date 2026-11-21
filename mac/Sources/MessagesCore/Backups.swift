import Foundation
import CryptoKit

/// An iPhone backup made by Finder (or iTunes) on this Mac.
public struct BackupInfo: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let deviceName: String
    public let lastBackup: Date?
    public let isEncrypted: Bool

    public var label: String {
        var parts = ["iPhone backup: \(deviceName)"]
        if let lastBackup {
            parts.append(DateFormatter.localizedString(from: lastBackup, dateStyle: .medium, timeStyle: .none))
        }
        return parts.joined(separator: " · ")
    }
}

public enum BackupError: Error, LocalizedError {
    case encrypted
    case noMessages

    public var errorDescription: String? {
        switch self {
        case .encrypted:
            return "This iPhone backup is encrypted. Encrypted backups aren't supported yet. In Finder, select your iPhone, uncheck \"Encrypt local backup\" (it asks for the backup password), and back up again."
        case .noMessages:
            return "This backup doesn't contain a Messages database."
        }
    }
}

public enum BackupLocator {
    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    }

    /// Lists backups in the default Finder location. Requires Full Disk Access.
    public static func findBackups(root: URL = defaultRoot()) -> [BackupInfo] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return folders.compactMap { info(for: $0) }
            .sorted { ($0.lastBackup ?? .distantPast) > ($1.lastBackup ?? .distantPast) }
    }

    /// Reads one backup folder. Returns nil if it isn't a backup.
    public static func info(for folder: URL) -> BackupInfo? {
        let fm = FileManager.default
        let manifestDB = folder.appendingPathComponent("Manifest.db")
        let infoPlist = folder.appendingPathComponent("Info.plist")
        guard fm.fileExists(atPath: manifestDB.path) || fm.fileExists(atPath: infoPlist.path) else { return nil }

        var deviceName = folder.lastPathComponent
        var lastBackup: Date?
        if let data = try? Data(contentsOf: infoPlist),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            deviceName = (plist["Device Name"] as? String) ?? (plist["Display Name"] as? String) ?? deviceName
            lastBackup = plist["Last Backup Date"] as? Date
        }

        var encrypted = false
        if let data = try? Data(contentsOf: folder.appendingPathComponent("Manifest.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            encrypted = (plist["IsEncrypted"] as? Bool) ?? false
        }

        return BackupInfo(url: folder, deviceName: deviceName, lastBackup: lastBackup, isEncrypted: encrypted)
    }

    /// Files in an unencrypted backup are stored as <first 2 hex chars>/<SHA1("Domain-relativePath")>.
    public static func fileURL(in backup: URL, domain: String, relativePath: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data("\(domain)-\(relativePath)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let nested = backup.appendingPathComponent(String(hex.prefix(2))).appendingPathComponent(hex)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        // Very old backups stored files flat.
        return backup.appendingPathComponent(hex)
    }

    public static func messagesDatabase(in backup: URL) -> URL {
        fileURL(in: backup, domain: "HomeDomain", relativePath: "Library/SMS/sms.db")
    }

    public static func addressBook(in backup: URL) -> URL {
        fileURL(in: backup, domain: "HomeDomain", relativePath: "Library/AddressBook/AddressBook.sqlitedb")
    }

    /// Attachment paths in sms.db look like "~/Library/SMS/Attachments/..." or
    /// "/var/mobile/Library/SMS/Attachments/...".
    public static func attachmentURL(in backup: URL, storedPath: String) -> URL? {
        var path = storedPath
        for prefix in ["~/", "/var/mobile/", "/private/var/mobile/"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
            break
        }
        guard path.hasPrefix("Library/") else { return nil }
        return fileURL(in: backup, domain: "MediaDomain", relativePath: path)
    }
}
