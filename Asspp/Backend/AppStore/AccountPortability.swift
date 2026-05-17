//
//  AccountPortability.swift
//  Asspp
//
//  Encrypted import / export of accounts so an authenticated session
//  (including its bound device identifier) can be moved between devices
//  without re-authenticating against Apple — which avoids the account
//  level rate limit (HTTP 429) on the legacy auth endpoint.
//

import ApplePackage
import CommonCrypto
import CryptoKit
import Foundation
import Security

extension AppStore {
    enum PortabilityError: LocalizedError {
        case emptyAccounts
        case emptyPassphrase
        case unsupportedVersion(Int)
        case decryptionFailed
        case malformedFile
        case randomFailure

        var errorDescription: String? {
            switch self {
            case .emptyAccounts:
                String(localized: "There are no accounts to export.")
            case .emptyPassphrase:
                String(localized: "Please enter a password.")
            case let .unsupportedVersion(version):
                String(localized: "Unsupported backup version (\(version)). Update Asspp and try again.")
            case .decryptionFailed:
                String(localized: "Wrong password, or the backup file is corrupted.")
            case .malformedFile:
                String(localized: "This file is not a valid Asspp account backup.")
            case .randomFailure:
                String(localized: "Failed to generate secure random data.")
            }
        }
    }

    /// Sensitive content that gets encrypted. The device identifier always
    /// travels with the accounts because Apple binds the session token to it.
    private struct PortablePayload: Codable {
        var deviceIdentifier: String
        var accounts: [UserAccount]
        var exportedAt: Date
    }

    /// On-disk container. Only non-sensitive KDF parameters are in clear text;
    /// every credential, token, cookie and the GUID live inside `combined`.
    struct AccountBackupFile: Codable {
        var v: Int
        var kdfSalt: Data
        var kdfIterations: Int
        var combined: Data // AES-GCM nonce || ciphertext || tag
    }

    struct ImportResult {
        var importedCount: Int
        var deviceIdentifierChanged: Bool
    }

    static let portabilityVersion = 1
    static let portabilityKDFIterations = 210_000

    // MARK: - Export

    /// - Parameter ids: specific accounts to export, or `nil` for all.
    @MainActor
    func exportAccounts(ids: [UserAccount.ID]?, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw PortabilityError.emptyPassphrase }

        let selected: [UserAccount] = if let ids {
            accounts.filter { ids.contains($0.id) }
        } else {
            accounts
        }
        guard !selected.isEmpty else { throw PortabilityError.emptyAccounts }

        let payload = PortablePayload(
            deviceIdentifier: deviceIdentifier,
            accounts: selected,
            exportedAt: Date(),
        )
        let plaintext = try JSONEncoder().encode(payload)

        let salt = try Self.secureRandomData(count: 16)
        let key = try Self.deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: Self.portabilityKDFIterations,
        )

        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw PortabilityError.randomFailure
        }

        let file = AccountBackupFile(
            v: Self.portabilityVersion,
            kdfSalt: salt,
            kdfIterations: Self.portabilityKDFIterations,
            combined: combined,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    // MARK: - Import

    @MainActor
    @discardableResult
    func importAccounts(from data: Data, passphrase: String) throws -> ImportResult {
        guard !passphrase.isEmpty else { throw PortabilityError.emptyPassphrase }

        let file: AccountBackupFile
        do {
            file = try JSONDecoder().decode(AccountBackupFile.self, from: data)
        } catch {
            throw PortabilityError.malformedFile
        }
        guard file.v == Self.portabilityVersion else {
            throw PortabilityError.unsupportedVersion(file.v)
        }
        // Reject out-of-range iteration counts: a negative / huge value would
        // either trap on UInt32 conversion, hang the app (DoS), or silently
        // weaken the KDF below our security floor.
        guard (100_000 ... 4_000_000).contains(file.kdfIterations) else {
            throw PortabilityError.malformedFile
        }

        let key = try Self.deriveKey(
            passphrase: passphrase,
            salt: file.kdfSalt,
            iterations: file.kdfIterations,
        )

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: file.combined)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            // Wrong passphrase or tampered ciphertext both land here.
            throw PortabilityError.decryptionFailed
        }

        let payload: PortablePayload
        do {
            payload = try JSONDecoder().decode(PortablePayload.self, from: plaintext)
        } catch {
            throw PortabilityError.malformedFile
        }
        guard !payload.accounts.isEmpty else { throw PortabilityError.malformedFile }
        // A valid Asspp backup always carries the device identifier the
        // sessions were bound to. An empty one means a corrupt/foreign file;
        // importing those tokens without the matching GUID would just produce
        // unusable accounts, so reject it outright.
        let newGUID = payload.deviceIdentifier
        guard !newGUID.isEmpty else { throw PortabilityError.malformedFile }

        let guidChanged = newGUID != deviceIdentifier
        if guidChanged {
            deviceIdentifier = newGUID
            // Update the live value too, otherwise the running session keeps
            // using the old GUID and the imported tokens would be rejected.
            ApplePackage.Configuration.deviceIdentifier = newGUID
        }

        // Imported accounts win on email collision (their token matches the
        // GUID we just adopted; any local same-email token is now stale).
        var merged = accounts
        for incoming in payload.accounts {
            merged.removeAll { $0.account.email == incoming.account.email }
            merged.append(incoming)
        }
        accounts = merged.sorted { $0.account.email < $1.account.email }

        return ImportResult(
            importedCount: payload.accounts.count,
            deviceIdentifierChanged: guidChanged,
        )
    }

    // MARK: - Crypto helpers

    private static func secureRandomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw PortabilityError.randomFailure }
        return Data(bytes)
    }

    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: Int,
    ) throws -> SymmetricKey {
        let passBytes = Array(passphrase.utf8).map { Int8(bitPattern: $0) }
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)

        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passBytes, passBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &derived, derived.count,
        )
        // CCKeyDerivationPBKDF returns Int32; success is 0. Compare to the
        // literal to avoid any kCCSuccess (Int) vs Int32 typing ambiguity.
        guard status == 0 else { throw PortabilityError.decryptionFailed }
        return SymmetricKey(data: Data(derived))
    }
}
