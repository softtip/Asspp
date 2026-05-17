//
//  AccountDetailView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import ButtonKit
import SwiftUI

struct AccountDetailView: View {
    let accountId: AppStore.UserAccount.ID

    @State private var vm = AppStore.this
    @Environment(\.dismiss) var dismiss

    private var account: AppStore.UserAccount? {
        vm.accounts.first { $0.id == accountId }
    }

    @State private var rotatingHint = ""
    @State private var exportMode: AccountPortabilityMode?
    @State private var shareError: String?

    private func shareBackupFile(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !AirDrop(items: [url]) {
                shareError = String(localized: "Could not open the share sheet. The backup file was created — please try exporting again.")
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Button { copyToClipboard(account?.account.email) } label: {
                    Text(account?.account.email ?? "")
                }
                .foregroundStyle(.primary)
                .redacted(reason: .placeholder, isEnabled: vm.demoMode)
            } header: {
                Text("Apple ID")
            } footer: {
                Text("This email is used to sign in to Apple services.")
            }
            Section {
                Button { copyToClipboard(account?.account.store) } label: {
                    Text("\(account?.account.store ?? "") - \(ApplePackage.Configuration.countryCode(for: account?.account.store ?? "") ?? "Unknown")")
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Country Code")
            } footer: {
                Text("App Store requires this country code to identify your package region.")
            }
            Section {
                Button { copyToClipboard(account?.account.directoryServicesIdentifier) } label: {
                    Text(account?.account.directoryServicesIdentifier ?? "")
                        .font(.system(.body, design: .monospaced))
                }
                .foregroundStyle(.primary)
                .redacted(reason: .placeholder, isEnabled: vm.demoMode)
            } header: {
                Text("Directory Services ID")
            } footer: {
                Text("This ID, combined with a random seed generated on this device, can be used to download packages from the App Store.")
            }
            Section {
                SecureField(text: .constant(account?.account.passwordToken ?? "")) {
                    Text("Password Token")
                }
                AsyncButton {
                    do {
                        try await vm.rotate(id: account?.id ?? "")
                        rotatingHint = String(localized: "Success")
                    } catch {
                        rotatingHint = error.localizedDescription
                        throw error
                    }
                } label: {
                    Text("Rotate Token")
                }
                .disabledWhenLoading()
            } header: {
                Text("Password Token")
            } footer: {
                if rotatingHint.isEmpty {
                    Text("If you fail to acquire a license for a product, rotating the password token may help. This will use the initial password to authenticate with the App Store again.")
                } else {
                    Text(rotatingHint)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    if let id = account?.id { exportMode = .exportSingle(id) }
                } label: {
                    Label("Export This Account", systemImage: "square.and.arrow.up")
                }
                .disabled(account == nil)
            } footer: {
                Text("Export this account (with its device identifier) as an encrypted file you can import on another device without signing in again.")
            }
            Section {
                Button("Delete") {
                    vm.delete(id: account?.id ?? "")
                    dismiss()
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account Details")
        .sheet(item: $exportMode) { mode in
            AccountPortabilitySheet(mode: mode, onExportFile: { shareBackupFile($0) })
        }
        .alert("Error", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } },
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
    }
}
