import Foundation

public enum Exporter {
    static let reactionNames: [Int64: String] = [
        0: "loved", 1: "liked", 2: "disliked", 3: "laughed", 4: "emphasized", 5: "questioned", 6: "emoji", 7: "sticker",
    ]

    /// Writes one CSV and/or JSON file per conversation into a new folder inside `parent`.
    public static func export(
        requests: [ExportRequest],
        store: MessageStore,
        contacts: ContactDirectory,
        options: ExportOptions,
        into parent: URL,
        now: Date = Date(),
        progress: @escaping (Double, String) -> Void = { _, _ in }
    ) throws -> ExportSummary {
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        let folder = uniqueURL(parent.appendingPathComponent("Messages Export \(stamp.string(from: now))", isDirectory: true))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]

        var usedNames = Set<String>()
        var summary = ExportSummary(folder: folder, conversations: 0, messages: 0, attachmentsCopied: 0, attachmentsMissing: 0)
        var index: [[String: Any]] = []

        for (position, request) in requests.enumerated() {
            let conversation = request.conversation
            progress(Double(position) / Double(max(requests.count, 1)), "Exporting \(conversation.title)…")

            let baseName = uniqueName(safeFileName(conversation.title), used: &usedNames)
            let (rawMessages, rawReactions) = try store.fetchMessages(
                chatIDs: conversation.chatIDs, start: request.start, end: request.end
            )
            let attachmentsByMessage = try store.fetchAttachments(chatIDs: conversation.chatIDs)
            let reactions = collectReactions(rawReactions, contacts: contacts)

            var exported: [ExportedMessage] = []
            exported.reserveCapacity(rawMessages.count)
            for raw in rawMessages {
                let text = cleanText(raw.text)
                var attachments: [ExportedAttachment] = []
                for (n, attachment) in (attachmentsByMessage[raw.rowID] ?? []).enumerated() {
                    let type = attachmentType(attachment)
                    switch options.attachments {
                    case .typeOnly:
                        attachments.append(ExportedAttachment(type: type))
                    case .copy:
                        let original = attachment.transferName
                            ?? attachment.storedPath.map { ($0 as NSString).lastPathComponent }
                            ?? "attachment"
                        let fileName = "\(raw.rowID)-\(n + 1)-\(safeFileName(original))"
                        let relative = "attachments/\(baseName)/\(fileName)"
                        if let source = store.fileURL(for: attachment), fm.fileExists(atPath: source.path) {
                            let destination = folder.appendingPathComponent(relative)
                            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            if !fm.fileExists(atPath: destination.path) {
                                try fm.copyItem(at: source, to: destination)
                            }
                            summary.attachmentsCopied += 1
                            attachments.append(ExportedAttachment(type: type, filename: original, path: relative))
                        } else {
                            summary.attachmentsMissing += 1
                            attachments.append(ExportedAttachment(type: type, filename: original, missing: true))
                        }
                    }
                }
                if text.isEmpty && attachments.isEmpty { continue }

                let sender: String
                if raw.isFromMe {
                    sender = "Me"
                } else if let handle = raw.handle {
                    sender = contacts.name(for: handle) ?? handle
                } else {
                    sender = conversation.isGroup ? "Unknown" : conversation.title
                }

                exported.append(ExportedMessage(
                    id: raw.guid,
                    timestamp: iso.string(from: raw.date),
                    sender: sender,
                    senderHandle: raw.isFromMe ? nil : (raw.handle ?? (conversation.isGroup ? nil : conversation.handles.first)),
                    isFromMe: raw.isFromMe,
                    text: text,
                    service: raw.service,
                    attachments: attachments,
                    reactions: reactions[raw.guid] ?? [],
                    replyTo: raw.threadOriginatorGUID,
                    edited: raw.edited
                ))
            }

            let rangeStart = request.start.map { iso.string(from: $0) }
            let rangeEnd = request.end.map { iso.string(from: $0) }

            if options.writeJSON {
                let document = ExportedConversation(
                    conversation: conversation.title,
                    isGroup: conversation.isGroup,
                    participants: conversation.handles.map {
                        ExportedParticipant(handle: $0, name: contacts.name(for: $0))
                    },
                    rangeStart: rangeStart,
                    rangeEnd: rangeEnd,
                    exportedAt: iso.string(from: now),
                    messageCount: exported.count,
                    messages: exported
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                try encoder.encode(document).write(to: folder.appendingPathComponent("\(baseName).json"))
            }
            if options.writeCSV {
                try csv(for: exported, conversation: conversation.title)
                    .write(to: folder.appendingPathComponent("\(baseName).csv"), atomically: true, encoding: .utf8)
            }

            index.append([
                "conversation": conversation.title,
                "file": baseName,
                "rangeStart": rangeStart ?? "all",
                "rangeEnd": rangeEnd ?? "all",
                "messages": exported.count,
            ])
            summary.conversations += 1
            summary.messages += exported.count
        }

        let summaryJSON: [String: Any] = [
            "exportedAt": iso.string(from: now),
            "attachments": options.attachments == .copy ? "copied" : "type only",
            "conversations": index,
        ]
        let data = try JSONSerialization.data(withJSONObject: summaryJSON, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("export-summary.json"))

        progress(1, "Done")
        return summary
    }

    // MARK: Helpers

    /// Applies tapbacks in time order, honoring removals (types 3000+).
    static func collectReactions(_ raw: [RawMessage], contacts: ContactDirectory) -> [String: [ExportedReaction]] {
        var state: [String: [(key: String, reaction: ExportedReaction)]] = [:]
        for message in raw.sorted(by: { $0.date < $1.date }) {
            guard let target = message.associatedGUID.map(targetGUID) else { continue }
            let type = message.associatedType
            let sender = message.isFromMe ? "Me" : (message.handle.flatMap { contacts.name(for: $0) } ?? message.handle ?? "Unknown")
            if (2000...2007).contains(type) {
                let kind = type - 2000
                var name = reactionNames[kind] ?? "reacted"
                if kind == 6, let emoji = message.emoji, !emoji.isEmpty { name = emoji }
                let key = "\(sender)|\(kind)"
                var list = state[target] ?? []
                list.removeAll { $0.key == key }
                list.append((key, ExportedReaction(sender: sender, reaction: name)))
                state[target] = list
            } else if (3000...3007).contains(type) {
                let key = "\(sender)|\(type - 3000)"
                state[target]?.removeAll { $0.key == key }
            }
        }
        return state.mapValues { $0.map(\.reaction) }
    }

    /// associated_message_guid looks like "p:0/GUID" or "bp:GUID".
    static func targetGUID(_ raw: String) -> String {
        if raw.hasPrefix("bp:") { return String(raw.dropFirst(3)) }
        if let slash = raw.firstIndex(of: "/") { return String(raw[raw.index(after: slash)...]) }
        return raw
    }

    static func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attachmentType(_ attachment: RawAttachment) -> String {
        if let mime = attachment.mimeType, !mime.isEmpty { return mime }
        let name = attachment.transferName ?? attachment.storedPath ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        if let uti = attachment.uti, !uti.isEmpty { return uti }
        return "unknown"
    }

    static func csv(for messages: [ExportedMessage], conversation: String) -> String {
        let header = ["conversation", "timestamp", "sender", "sender_handle", "is_from_me", "text",
                      "attachments", "reactions", "reply_to", "edited", "service", "message_id"]
        // Byte-order mark so Excel opens emoji and accents correctly.
        var out = "\u{FEFF}" + header.joined(separator: ",") + "\r\n"
        for m in messages {
            let attachments = m.attachments.map { $0.path ?? ($0.filename.map { "\($0) (missing)" } ?? $0.type) }
            let fields = [
                conversation, m.timestamp, m.sender, m.senderHandle ?? "", m.isFromMe ? "1" : "0", m.text,
                attachments.joined(separator: "; "),
                m.reactions.map { "\($0.sender): \($0.reaction)" }.joined(separator: "; "),
                m.replyTo ?? "", m.edited ? "1" : "0", m.service ?? "", m.id,
            ]
            out += fields.map(csvField).joined(separator: ",") + "\r\n"
        }
        return out
    }

    static func csvField(_ value: String) -> String {
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var cleaned = name.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix(".") { cleaned = "_" + cleaned.dropFirst() }
        if cleaned.isEmpty { cleaned = "conversation" }
        return String(cleaned.prefix(100))
    }

    static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var n = 2
        while used.contains(name.lowercased()) {
            name = "\(base) (\(n))"
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }

    static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
