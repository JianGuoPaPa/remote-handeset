import Foundation
import Security

enum SecureCredentialStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case randomGeneration
    case invalidCredential
    case tokenExport

    var errorDescription: String? {
        switch self {
        case .keychain:
            return "无法访问登录钥匙串"
        case .randomGeneration:
            return "无法生成本机凭据"
        case .invalidCredential:
            return "本机凭据格式无效"
        case .tokenExport:
            return "无法准备本机桥接凭据"
        }
    }
}

final class SecureCredentialStore: @unchecked Sendable {
    private enum Account {
        static let bridgeToken = "bridge-token"
        static let vncPassword = "vnc-password"
        static let captureDeviceUniqueID = "capture-device-unique-id"
    }

    private let service = "local.iphone.usbconsole.credentials"
    private let tokenFileURL: URL

    init(tokenFileURL: URL) {
        self.tokenFileURL = tokenFileURL
    }

    func loadOrCreateBridgeToken() throws -> String {
        if let existing = try read(account: Account.bridgeToken),
           Self.isValidBridgeToken(existing) {
            try exportBridgeToken(existing)
            return existing
        }

        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            random.withUnsafeMutableBytes { IUSCSecureZeroBuffer($0.baseAddress, $0.count) }
            throw SecureCredentialStoreError.randomGeneration
        }
        defer {
            random.withUnsafeMutableBytes { IUSCSecureZeroBuffer($0.baseAddress, $0.count) }
        }
        let token = Data(random)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try write(token, account: Account.bridgeToken)
        try exportBridgeToken(token)
        return token
    }

    func loadVNCPassword() throws -> String? {
        guard let value = try read(account: Account.vncPassword) else { return nil }
        guard Self.isValidVNCPassword(value) else {
            throw SecureCredentialStoreError.invalidCredential
        }
        return value
    }

    func saveVNCPassword(_ password: String) throws {
        guard Self.isValidVNCPassword(password) else {
            throw SecureCredentialStoreError.invalidCredential
        }
        try write(password, account: Account.vncPassword)
    }

    func loadCaptureDeviceUniqueID() throws -> String? {
        guard let value = try read(account: Account.captureDeviceUniqueID) else { return nil }
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SecureCredentialStoreError.invalidCredential }
        return value
    }

    func saveCaptureDeviceUniqueID(_ uniqueID: String) throws {
        guard !uniqueID.isEmpty, uniqueID.utf8.count <= 1_024,
              !uniqueID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SecureCredentialStoreError.invalidCredential }
        try write(uniqueID, account: Account.captureDeviceUniqueID)
    }

    static func isValidVNCPassword(_ password: String) -> Bool {
        let bytes = Array(password.utf8)
        return !bytes.isEmpty && bytes.count <= 8 && bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
    }

    private static func isValidBridgeToken(_ token: String) -> Bool {
        (40...128).contains(token.count) && token.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    private func read(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw SecureCredentialStoreError.keychain(status)
        }
        return value
    }

    private func write(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureCredentialStoreError.invalidCredential
        }
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SecureCredentialStoreError.keychain(updateStatus)
        }
        var add = lookup
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecureCredentialStoreError.keychain(addStatus)
        }
    }

    private func exportBridgeToken(_ token: String) throws {
        let directory = tokenFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let data = (token + "\n").data(using: .utf8) else {
                throw SecureCredentialStoreError.tokenExport
            }
            try data.write(to: tokenFileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tokenFileURL.path
            )
        } catch {
            throw SecureCredentialStoreError.tokenExport
        }
    }
}
