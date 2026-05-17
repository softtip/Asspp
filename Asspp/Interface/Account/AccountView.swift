//
//  AccountView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import SwiftUI
import UniformTypeIdentifiers

struct AccountView: View {
    @State private var vm = AppStore.this
    @State private var addAccount = false
    @State private var selectedID: AppStore.UserAccount.ID?
    @State private var navigationPath = NavigationPath()

    @State private var portabilityMode: AccountPortabilityMode?
    @State private var showImporter = false
    @State private var importError: String?

    @ViewBuilder
    private var portabilityMenu: some View {
        Menu {
            Button {
                portabilityMode = .exportAll
            } label: {
                Label("Export All Accounts", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.accounts.isEmpty)

            Button {
                showImporter = true
            } label: {
                Label("Import Accounts", systemImage: "square.and.arrow.down")
            }
        } label: {
            Label("Backup", systemImage: "ellipsis.circle")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else {
                importError = String(localized: "No file was selected.")
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                portabilityMode = .importData(data)
            } catch {
                importError = error.localizedDescription
            }
        case let .failure(error):
            importError = error.localizedDescription
        }
    }

    private func shareBackupFile(_ url: URL) {
        // Present after the sheet has fully dismissed so the activity
        // controller attaches to this view, not the disappearing sheet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !AirDrop(items: [url]) {
                importError = String(localized: "Could not open the share sheet. The backup file was created — please try exporting again.")
            }
        }
    }

    @ViewBuilder
    private func portabilityModifiers(_ content: some View) -> some View {
        content
            .sheet(item: $portabilityMode) { mode in
                AccountPortabilitySheet(mode: mode, onExportFile: { shareBackupFile($0) })
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false,
            ) { result in
                handleImport(result)
            }
            .alert("Error", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } },
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
    }

    var body: some View {
        #if os(macOS)
            macOSBody
        #else
            iOSBody
        #endif
    }

    #if os(macOS)
        private var macOSBody: some View {
            portabilityModifiers(
                NavigationStack(path: $navigationPath) {
                    accountsTable
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .navigationTitle("Accounts")
                        .toolbar { macToolbar }
                }
                .sheet(isPresented: $addAccount) {
                    AddAccountView()
                        .frame(minWidth: 480, idealWidth: 520, minHeight: 340, idealHeight: 380)
                }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar),
            )
        }

        private var accountsTable: some View {
            Table(vm.accounts, selection: $selectedID) {
                TableColumn("Email") { account in
                    Text(account.account.email)
                        .redacted(reason: .placeholder, isEnabled: vm.demoMode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TableColumn("Region") { account in
                    Text(account.account.store)
                }
                .width(min: 40, ideal: 60, max: 80)

                TableColumn("Storefront") { account in
                    Text(ApplePackage.Configuration.countryCode(for: account.account.store) ?? String(localized: "Unknown"))
                }
                .width(min: 60, ideal: 80, max: 120)

                TableColumn("") { account in
                    Button {
                        navigationPath.append(account.id)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .width(32)
            }
            .contextMenu(forSelectionType: AppStore.UserAccount.ID.self) { ids in
                if let id = ids.first {
                    Button("View Details") {
                        navigationPath.append(id)
                    }
                }
            }
            .navigationDestination(for: AppStore.UserAccount.ID.self) { id in
                AccountDetailView(accountId: id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if vm.accounts.isEmpty {
                    ContentUnavailableView(
                        label: {
                            Label("No Accounts", systemImage: "person.crop.circle.badge.questionmark")
                        },
                        description: {
                            Text("Add an Apple ID to start downloading IPA packages.")
                        },
                        actions: {
                            Button("Add Account") { addAccount.toggle() }
                        },
                    )
                    .padding()
                }
            }
        }

        private var footer: some View {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title3)
                Text("Accounts are stored securely in your Keychain and can be removed at any time from the detail view.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        @ToolbarContentBuilder
        private var macToolbar: some ToolbarContent {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addAccount.toggle()
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                portabilityMenu
            }
        }
    #endif

    #if !os(macOS)
        private var iOSBody: some View {
            portabilityModifiers(iOSContent)
        }

        private var iOSContent: some View {
            NavigationStack(path: $navigationPath) {
                Group {
                    if vm.accounts.isEmpty {
                        ContentUnavailableView(
                            label: {
                                Label("No Accounts", systemImage: "person.crop.circle.badge.questionmark")
                            },
                            description: {
                                Text("Add an Apple ID to start downloading IPA packages.")
                            },
                            actions: {
                                Button("Add Account") { addAccount.toggle() }
                            },
                        )
                    } else {
                        Form {
                            Section {
                                ForEach(vm.accounts) { account in
                                    NavigationLink(value: account.id) {
                                        HStack {
                                            Text(account.account.email)
                                                .redacted(reason: .placeholder, isEnabled: vm.demoMode)
                                            Spacer()
                                        }
                                        .badge(ApplePackage.Configuration.countryCode(for: account.account.store) ?? account.account.store)
                                    }
                                }
                            } header: {
                                Text("Apple IDs")
                            } footer: {
                                Text("Your accounts are saved in your Keychain and will be synced across devices with the same iCloud account signed in.")
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
                .navigationDestination(for: AppStore.UserAccount.ID.self) { id in
                    AccountDetailView(accountId: id)
                }
                .navigationTitle("Accounts")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            addAccount.toggle()
                        } label: {
                            Label("Add Account", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        portabilityMenu
                    }
                }
            }
            .sheet(isPresented: $addAccount) {
                NavigationStack {
                    AddAccountView()
                }
            }
        }
    #endif
}
