import MessagesCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceBar
            if model.needsFullDiskAccess {
                FullDiskAccessHelp()
            } else if model.rows.isEmpty {
                emptyState
            } else {
                selectionBar
                conversationTable
            }
            Divider()
            exportBar
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            model.refreshBackups()
            model.load()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sourceBar: some View {
        HStack {
            Picker("Read messages from", selection: $model.source) {
                ForEach(model.sources, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .frame(maxWidth: 460)
            .onChange(of: model.source) { _ in model.load() }

            Button("Choose iPhone Backup…") { model.chooseBackupFolder() }
            Button {
                model.refreshBackups()
                model.load()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if model.isLoading {
                Text("Reading your messages…").foregroundStyle(.secondary)
            } else {
                Text("No conversations to show.").font(.headline)
                Text("For iPhone messages that aren't on this Mac, connect your iPhone, back it up in Finder, then choose the backup above.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var selectionBar: some View {
        HStack {
            TextField("Search conversations", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Button("Select All") { model.setSelection(true) }
            Button("Select None") { model.setSelection(false) }
            Menu("Set Range for Selected") {
                ForEach(RangePreset.allCases) { preset in
                    Button(preset.rawValue) { model.applyPresetToSelected(preset) }
                }
            }
            .frame(maxWidth: 200)
            .disabled(model.selectedCount == 0)
            Spacer()
            Text("\(model.selectedCount) selected").foregroundStyle(.secondary)
        }
    }

    private var conversationTable: some View {
        Table(model.visibleRows) {
            TableColumn("Export") { row in
                Toggle("", isOn: model.binding(for: row.id).selected)
                    .labelsHidden()
            }
            .width(50)

            TableColumn("Conversation") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.conversation.title).lineLimit(1)
                    Text(row.conversation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 200, ideal: 280)

            TableColumn("Messages") { row in
                Text(row.conversation.messageCount.formatted()).monospacedDigit()
            }
            .width(70)

            TableColumn("First") { row in
                Text(row.conversation.firstDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
            }
            .width(100)

            TableColumn("Last") { row in
                Text(row.conversation.lastDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
            }
            .width(100)

            TableColumn("Date range to export") { row in
                RangeEditor(row: model.binding(for: row.id))
            }
            .width(min: 320, ideal: 380)
        }
    }

    private var exportBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Toggle("CSV (opens in Excel/Sheets)", isOn: $model.writeCSV)
                Toggle("JSON (for analysis)", isOn: $model.writeJSON)
                Toggle("Copy attachments", isOn: $model.copyAttachments)
                    .help("When off, the export records only each attachment's file type.")
                Spacer()
                if model.lastExportFolder != nil {
                    Button("Show in Finder") { model.revealExport() }
                }
                Button("Export…") { model.export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport)
            }
            if model.isExporting {
                ProgressView(value: model.progress)
            }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

struct RangeEditor: View {
    @Binding var row: ConversationRow

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $row.preset) {
                ForEach(RangePreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            if row.preset == .custom {
                DatePicker("", selection: $row.customStart, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Text("to").foregroundStyle(.secondary)
                DatePicker("", selection: $row.customEnd, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        }
    }
}

struct FullDiskAccessHelp: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One-time setup: allow access to your messages").font(.title3).bold()
            Text("macOS protects your Messages history. To let this app read it:")
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click Open System Settings below.")
                Text("2. Turn on the switch next to Download My Messages. If it isn't listed, click +, and choose the app from where you saved it.")
                Text("3. If macOS asks, quit and reopen this app.")
            }
            Text("Your messages stay on this computer. The app never uploads anything.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open System Settings") { model.openFullDiskAccessSettings() }
                    .keyboardShortcut(.defaultAction)
                Button("I've Done This, Try Again") { model.load() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
    }
}
