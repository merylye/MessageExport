import AppKit
import Foundation
import MessagesCore
import SwiftUI

enum RangePreset: String, CaseIterable, Identifiable {
    case allTime = "All time"
    case last30Days = "Last 30 days"
    case last6Months = "Last 6 months"
    case lastYear = "Last year"
    case custom = "Custom"

    var id: String { rawValue }
}

struct ConversationRow: Identifiable {
    var conversation: Conversation
    var selected = false
    var preset: RangePreset = .allTime
    var customStart: Date
    var customEnd: Date

    var id: String { conversation.id }

    init(conversation: Conversation) {
        self.conversation = conversation
        let calendar = Calendar.current
        let last = conversation.lastDate ?? Date()
        customEnd = calendar.startOfDay(for: last)
        customStart = calendar.startOfDay(for: conversation.firstDate ?? calendar.date(byAdding: .month, value: -6, to: last)!)
    }

    /// The date range this row will export. nil bounds mean unbounded.
    func range(now: Date = Date()) -> (start: Date?, end: Date?) {
        let calendar = Calendar.current
        switch preset {
        case .allTime:
            return (nil, nil)
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: now), nil)
        case .last6Months:
            return (calendar.date(byAdding: .month, value: -6, to: now), nil)
        case .lastYear:
            return (calendar.date(byAdding: .year, value: -1, to: now), nil)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let endDay = calendar.startOfDay(for: max(customStart, customEnd))
            // Include the whole end day.
            let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endDay)
            return (start, end)
        }
    }
}

enum SourceChoice: Hashable {
    case mac
    case backup(BackupInfo)

    var messageSource: MessageSource {
        switch self {
        case .mac: return .mac
        case .backup(let info): return .backup(info)
        }
    }

    var label: String {
        switch self {
        case .mac: return "This Mac's Messages app"
        case .backup(let info): return info.label
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [SourceChoice] = [.mac]
    @Published var source: SourceChoice = .mac
    @Published var rows: [ConversationRow] = []
    @Published var search = ""
    @Published var writeCSV = true
    @Published var writeJSON = true
    @Published var copyAttachments = false

    @Published var isLoading = false
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var needsFullDiskAccess = false
    @Published var lastExportFolder: URL?

    private var store: MessageStore?
    private var contacts = ContactDirectory()

    var visibleRows: [ConversationRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.conversation.title.lowercased().contains(query)
                || $0.conversation.handles.contains { $0.lowercased().contains(query) }
        }
    }

    var selectedCount: Int { rows.filter(\.selected).count }

    var canExport: Bool {
        selectedCount > 0 && (writeCSV || writeJSON) && !isExporting && !isLoading
    }

    func binding(for id: String) -> Binding<ConversationRow> {
        Binding(
            get: { self.rows.first { $0.id == id } ?? self.rows[0] },
            set: { newValue in
                if let index = self.rows.firstIndex(where: { $0.id == id }) {
                    self.rows[index] = newValue
                }
            }
        )
    }

    func setSelection(_ selected: Bool, onlyVisible: Bool = true) {
        let ids = Set((onlyVisible ? visibleRows : rows).map(\.id))
        for index in rows.indices where ids.contains(rows[index].id) {
            rows[index].selected = selected
        }
    }

    func applyPresetToSelected(_ preset: RangePreset) {
        for index in rows.indices where rows[index].selected {
            rows[index].preset = preset
        }
    }

    func refreshBackups() {
        let backups = BackupLocator.findBackups()
        var choices: [SourceChoice] = [.mac]
        choices.append(contentsOf: backups.map { SourceChoice.backup($0) })
        if case .backup(let current) = source, !backups.contains(current) {
            choices.append(source)
        }
        sources = choices
    }

    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an iPhone backup folder (it contains a file named Manifest.db)."
        panel.prompt = "Use This Backup"
        panel.directoryURL = BackupLocator.defaultRoot()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let info = BackupLocator.info(for: url) else {
            errorMessage = "That folder isn't an iPhone backup. Look for a folder that contains Manifest.db."
            return
        }
        if !sources.contains(.backup(info)) { sources.append(.backup(info)) }
        source = .backup(info)
        load()
    }

    func load() {
        isLoading = true
        errorMessage = nil
        needsFullDiskAccess = false
        status = "Reading messages…"
        rows = []
        let choice = source

        Task {
            do {
                let (store, conversations) = try await Task.detached(priority: .userInitiated) {
                    let store = try MessageStore.open(choice.messageSource)
                    return (store, try store.loadConversations())
                }.value

                status = "Looking up contact names…"
                let directory = await MacContacts.load()
                if case .backup(let info) = choice {
                    let fromBackup = await Task.detached { ContactDirectory.fromBackup(info.url) }.value
                    fromBackup.merge(directory)
                    self.contacts = fromBackup
                } else {
                    self.contacts = directory
                }

                self.store = store
                self.rows = MessageStore.applyContacts(contacts, to: conversations).map(ConversationRow.init)
                let total = conversations.reduce(0) { $0 + $1.messageCount }
                status = "\(conversations.count) conversations, \(total.formatted()) messages"
                    + (contacts.isEmpty ? ". Contact names unavailable (allow Contacts access in System Settings to see names)." : "")
            } catch MessageStoreError.needsFullDiskAccess {
                needsFullDiskAccess = true
                status = ""
            } catch {
                errorMessage = error.localizedDescription
                status = ""
            }
            isLoading = false
        }
    }

    func export() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to save the export. A new folder will be created inside it."
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let now = Date()
        let requests = rows.filter(\.selected).map { row -> ExportRequest in
            let range = row.range(now: now)
            return ExportRequest(conversation: row.conversation, start: range.start, end: range.end)
        }
        let options = ExportOptions(
            writeCSV: writeCSV, writeJSON: writeJSON,
            attachments: copyAttachments ? .copy : .typeOnly
        )
        let contacts = self.contacts

        isExporting = true
        progress = 0
        errorMessage = nil
        lastExportFolder = nil

        Task {
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try Exporter.export(
                        requests: requests, store: store, contacts: contacts,
                        options: options, into: parent, now: now
                    ) { fraction, message in
                        Task { @MainActor in
                            self.progress = fraction
                            self.status = message
                        }
                    }
                }.value
                lastExportFolder = summary.folder
                var message = "Exported \(summary.messages.formatted()) messages from \(summary.conversations) conversations."
                if options.attachments == .copy {
                    message += " Copied \(summary.attachmentsCopied) attachments"
                    message += summary.attachmentsMissing > 0
                        ? "; \(summary.attachmentsMissing) weren't on this computer (often stored only in iCloud)."
                        : "."
                }
                status = message
                progress = 1
            } catch {
                errorMessage = "Export failed: \(error.localizedDescription)"
                status = ""
            }
            isExporting = false
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealExport() {
        if let folder = lastExportFolder {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
