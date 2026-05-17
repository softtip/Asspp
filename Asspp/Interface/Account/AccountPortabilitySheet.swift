//
//  AccountPortabilitySheet.swift
//  Asspp
//
//  Passphrase entry + warning + share for encrypted account backup,
//  and passphrase entry for restoring one.
//

import ApplePackage
import SwiftUI

enum AccountPortabilityMode: Identifiable {
    case exportAll
    case exportSingle(AppStore.UserAccount.ID)
    case importData(Data)

    var id: String {
        switch self {
        case .exportAll: "exportAll"
        case let .exportSingle(id): "exportSingle:\(id)"
        case .importData: "importData"
        }
    }

    var isExport: Bool {
        switch self {
        case .exportAll, .exportSingle: true
        case .importData: false
        }
    }
}

struct AccountPortabilitySheet: View {
    let mode: AccountPortabilityMode
    /// Called after the sheet dismisses with the written backup file, so the
    /// presenter (not this disappearing sheet) owns the share presentation.
    var onExportFile: ((URL) -> Void)? = nil

    @State private var vm = AppStore.this
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var exportIDs: [AppStore.UserAccount.ID]? {
        switch mode {
        case .exportAll: nil
        case let .exportSingle(id): [id]
        case .importData: nil
        }
    }

    private var canSubmit: Bool {
        if working { return false }
        if passphrase.isEmpty { return false }
        if mode.isExport, passphrase != confirmPassphrase { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode.isExport {
                    exportSection
                } else {
                    importSection
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            if working { ProgressView().controlSize(.small) }
                            Text(mode.isExport ? "Encrypt & Share" : "Import")
                        }
                    }
                    .disabled(!canSubmit)
                } footer: {
                    if mode.isExport, !passphrase.isEmpty, passphrase != confirmPassphrase {
                        Text("The two passwords do not match.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(mode.isExport ? "Export Accounts" : "Import Accounts")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(working)
                    }
                }
                .interactiveDismissDisabled(working)
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } },
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
                .alert("Done", isPresented: Binding(
                    get: { successMessage != nil },
                    set: { if !$0 { successMessage = nil } },
                )) {
                    Button("OK", role: .cancel) { dismiss() }
                } message: {
                    Text(successMessage ?? "")
                }
                .frame(minWidth: 380, minHeight: 320)
        }
    }

    private var exportSection: some View {
        Group {
            Section {
                Label {
                    Text("This backup contains your Apple ID password, session token and cookies. Anyone who obtains both the file and the password gains full control of these accounts. Set a strong password, transfer it over a trusted channel, and delete the file when done.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
            }
            Section {
                SecureField("Password", text: $passphrase)
                SecureField("Confirm Password", text: $confirmPassphrase)
            } header: {
                Text("Encryption Password")
            } footer: {
                let count = (exportIDs?.count) ?? vm.accounts.count
                Text("\(count) account(s) and this device identifier will be encrypted into one file.")
            }
        }
    }

    private var importSection: some View {
        Group {
            Section {
                Label {
                    Text("Importing replaces this device's identifier with the one from the backup so the imported sessions stay valid. Accounts already on this device that were signed in under a different identifier may need to be added again.")
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
                .font(.footnote)
            }
            Section {
                SecureField("Password", text: $passphrase)
            } header: {
                Text("Backup Password")
            } footer: {
                Text("Enter the password that was set when this backup was exported.")
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        working = true
        // Crypto is light for a handful of accounts; AppStore is @MainActor.
        Task { @MainActor in
            defer { working = false }
            do {
                switch mode {
                case .exportAll, .exportSingle:
                    let data = try vm.exportAccounts(ids: exportIDs, passphrase: passphrase)
                    let url = try writeTempBackup(data)
                    dismiss()
                    onExportFile?(url)
                case let .importData(data):
                    let result = try vm.importAccounts(from: data, passphrase: passphrase)
                    var msg = String(localized: "Imported \(result.importedCount) account(s).")
                    if result.deviceIdentifierChanged {
                        msg += "\n" + String(localized: "The device identifier was updated from the backup.")
                    }
                    successMessage = msg
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func writeTempBackup(_ data: Data) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Asspp-Accounts-\(formatter.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }
}
