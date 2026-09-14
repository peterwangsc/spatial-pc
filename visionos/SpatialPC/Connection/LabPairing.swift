import Foundation
import Security

#if DEBUG
struct LabPairing: Codable {
    let host: String
    let port: UInt16
    let serverName: String
    let serverSHA256: String
    let rootDER: Data
    let identityPKCS12: Data
    let password: String

    enum Failure: Error { case keychain(OSStatus) }
    private static var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,
        kSecAttrService as String:"com.golfcore.spatialpc.lab-pair", kSecAttrAccount as String:"peer"] }
    static func load() throws -> LabPairing? {
        let inbox = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("lab-pair.json")
        if FileManager.default.fileExists(atPath:inbox.path) {
            let data = try Data(contentsOf:inbox)
            guard data.count < 64*1024 else { throw CocoaError(.fileReadTooLarge) }
            _ = try JSONDecoder().decode(Self.self,from:data)
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary,nil)
            if status == errSecDuplicateItem {
                let update = [kSecValueData as String:data]
                let changed = SecItemUpdate(query as CFDictionary,update as CFDictionary)
                guard changed == errSecSuccess else { throw Failure.keychain(changed) }
            } else if status != errSecSuccess { throw Failure.keychain(status) }
            try FileManager.default.removeItem(at:inbox)
        }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return try JSONDecoder().decode(Self.self,from:data)
    }
    func identity() throws -> sec_identity_t {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String:password]
        guard SecPKCS12Import(identityPKCS12 as CFData,options as CFDictionary,&items) == errSecSuccess,
              let first = (items as? [[String:Any]])?.first,
              let reference = first[kSecImportItemIdentity as String] else { throw CocoaError(.fileReadCorruptFile) }
        let identity = reference as! SecIdentity
        guard let result = sec_identity_create(identity) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
#endif
