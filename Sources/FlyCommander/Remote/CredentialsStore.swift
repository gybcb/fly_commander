import Foundation
import Security

/// Keychain 抽象（单测注入 fake，避免真机弹授权框）。
protocol KeychainLike {
    func set(_ value: String, account: String) throws
    func get(account: String) throws -> String?
    func delete(account: String) throws
}

/// 真 Keychain 实现：generic password，service = "FlyCommander.sftp"，
/// account = host:port:username（见 SFTPConnectionConfig.credentialAccount）。
/// 密码/passphrase 仅此一处落盘；连接记录（最近连接）不含密钥。
final class KeychainCredentialsStore: KeychainLike {
    let service: String

    init(service: String = "FlyCommander.sftp") { self.service = service }

    func set(_ value: String, account: String) throws {
        // 先删旧值（SecItemAdd 在已存在时报 errDuplicateItem）。
        try? delete(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = value.data(using: .utf8)!
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(code: status) }
    }

    func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(code: status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound { return }   // 幂等
        guard status == errSecSuccess else { throw KeychainError(code: status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Keychain 操作错误（携带 OSStatus 便于诊断）。
struct KeychainError: Error, Equatable {
    let code: OSStatus
    var message: String { "Keychain 操作失败（OSStatus \(code)）" }
}

/// 面向应用的凭据门面：把 KeychainLike 收敛到"按连接配置存取"。
final class CredentialsStore {
    private let keychain: KeychainLike

    init(keychain: KeychainLike = KeychainCredentialsStore()) {
        self.keychain = keychain
    }

    /// 勾选"记住"时调用；存密码或密钥 passphrase。
    func save(_ secret: String, for config: SFTPConnectionConfig) throws {
        try keychain.set(secret, account: config.credentialAccount)
    }

    /// 取回已记住的密码/passphrase；未记住 → nil。
    func load(for config: SFTPConnectionConfig) throws -> String? {
        try keychain.get(account: config.credentialAccount)
    }

    /// 取消"记住"（或连接后不想再存）。
    func forget(for config: SFTPConnectionConfig) throws {
        try keychain.delete(account: config.credentialAccount)
    }
}

/// SMB 凭据门面：Keychain service 独立为 "FlyCommander.smb"（与 SFTP 不串）。
final class SMBCredentialsStore {
    let keychain: KeychainLike   // internal：单测断言默认 service 用
    init(keychain: KeychainLike = KeychainCredentialsStore(service: "FlyCommander.smb")) {
        self.keychain = keychain
    }
    func save(_ secret: String, for config: SMBConnectionConfig) throws {
        try keychain.set(secret, account: config.credentialAccount)
    }
    func load(for config: SMBConnectionConfig) throws -> String? {
        try keychain.get(account: config.credentialAccount)
    }
    func forget(for config: SMBConnectionConfig) throws {
        try keychain.delete(account: config.credentialAccount)
    }
}
