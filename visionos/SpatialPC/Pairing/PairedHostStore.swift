import Foundation
import Security
import Network
import CryptoKit
import Observation

struct SavedHost: Codable, Identifiable, Equatable {
    let id: String
    let deviceID: String
    var name: String
    var address: String
    let serviceName: String?
    let serviceDomain: String?
    let port: UInt16
    let serverName: String
    let serverCertificate: Data
    let clientCertificate: Data
    let caCertificate: Data
    let keyTag: String
    let pairedAt: Date
    var serverSHA256: String { SHA256.hash(data:serverCertificate).map { String(format:"%02x",$0) }.joined() }
    var endpoint: NWEndpoint {
        if let serviceName,let serviceDomain { return .service(name:serviceName,type:"_spatialpc._tcp",domain:serviceDomain,interface:nil) }
        return .hostPort(host:.init(address),port:.init(rawValue:port)!)
    }
}

/// Certificates and paired-PC metadata live in this app's device-only Keychain.
/// Private keys are separate permanent Keychain items and never exported.
@MainActor @Observable final class PairedHostStore {
    private(set) var hosts:[SavedHost] = []
    private(set) var selectedID:String?
    private(set) var error:String?
    var selected:SavedHost? { hosts.first { $0.id == selectedID } }
    private struct Archive:Codable { var hosts:[SavedHost]; var selectedID:String? }
    private static let service = "com.golfcore.spatialpc.paired-hosts.v1"
    init() {
        reload()
        if error == nil { DeviceKeychain.removeAbandonedEnrollments(keeping:Set(hosts.map(\.keyTag))) }
    }
    func reload() {
        do {
            guard let data = try DeviceKeychain.data(service:Self.service,account:"hosts") else { hosts = []; selectedID = nil; error = nil; return }
            guard data.count <= 1_048_576 else { throw PairingWire.Failure.oversized }
            let archive = try JSONDecoder().decode(Archive.self,from:data)
            guard Set(archive.hosts.map(\.id)).count == archive.hosts.count else { throw PairingWire.Failure.invalidMessage }
            hosts = archive.hosts; selectedID = archive.selectedID; error = nil
        } catch { self.error = "Saved devices could not be loaded. Unlock the headset and try again." }
    }
    private func save(_ hosts:[SavedHost],selected:String?) throws {
        let data = try JSONEncoder().encode(Archive(hosts:hosts,selectedID:selected))
        guard data.count <= 1_048_576 else { throw PairingWire.Failure.oversized }
        try DeviceKeychain.save(data,service:Self.service,account:"hosts")
        self.hosts = hosts; selectedID = selected; error = nil
    }
    func select(_ host:SavedHost) throws {
        guard hosts.contains(where:{ $0.id == host.id }) else { throw PairingWire.Failure.invalidMessage }
        try save(hosts,selected:host.id)
    }
    func add(_ host:SavedHost) throws {
        // Re-enrollment replaces an identity only after the user has forgotten it.
        guard !hosts.contains(where:{ $0.id == host.id }) else { throw PairingWire.Failure.authentication }
        try save(hosts+[host],selected:host.id)
    }
    func forget(_ host:SavedHost) throws {
        let remaining = hosts.filter { $0.id != host.id }
        try save(remaining,selected:selectedID == host.id ? remaining.first?.id : selectedID)
        DeviceKeychain.removeIdentity(keyTag:host.keyTag,certificate:host.clientCertificate)
    }
}

enum DeviceKeychain {
    enum Failure:Error { case status(OSStatus), invalidIdentity }
    static func data(service:String,account:String) throws -> Data? {
        let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var value:CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary,&value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,let result = value as? Data else { throw Failure.status(status) }; return result
    }
    static func save(_ data:Data,service:String,account:String) throws {
        let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        let update:[String:Any] = [kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary,update as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(update) { _,new in new } as CFDictionary,nil) }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }
    struct PendingIdentity {
        let key:SecKey
        let tag:String
        let publicPoint:Data
        func sign(_ data:Data) throws -> Data {
            var error:Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key,.ecdsaSignatureMessageX962SHA256,data as CFData,&error) else {
                throw error?.takeRetainedValue() ?? Failure.invalidIdentity as Error
            }
            return signature as Data
        }
    }
    static func createIdentity() throws -> PendingIdentity {
        let tag = "com.golfcore.spatialpc.peer."+UUID().uuidString.lowercased()
        let attributes:[String:Any] = [kSecAttrKeyType as String:kSecAttrKeyTypeECSECPrimeRandom,kSecAttrKeySizeInBits as String:256,
            kSecPrivateKeyAttrs as String:[kSecAttrIsPermanent as String:true,kSecAttrApplicationTag as String:Data(tag.utf8),kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]]
        var error:Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary,&error) else { throw error?.takeRetainedValue() ?? Failure.invalidIdentity as Error }
        guard let publicKey = SecKeyCopyPublicKey(key),let point = SecKeyCopyExternalRepresentation(publicKey,&error) as Data?,point.count == 65 else {
            removeIdentity(keyTag:tag,certificate:nil); throw Failure.invalidIdentity
        }
        return PendingIdentity(key:key,tag:tag,publicPoint:point)
    }
    static func identity(for host:SavedHost) throws -> sec_identity_t {
        let query:[String:Any] = [kSecClass as String:kSecClassIdentity,kSecReturnRef as String:true,kSecMatchLimit as String:kSecMatchLimitAll]
        var result:CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        guard status == errSecSuccess,let identities = result as? [SecIdentity] else { throw Failure.status(status) }
        for identity in identities {
            var certificate:SecCertificate?
            guard SecIdentityCopyCertificate(identity,&certificate) == errSecSuccess,let certificate,
                  SecCertificateCopyData(certificate) as Data == host.clientCertificate else { continue }
            guard let wrapped = sec_identity_create(identity) else { throw Failure.invalidIdentity }; return wrapped
        }
        throw Failure.invalidIdentity
    }
    static func installCertificate(_ data:Data,identity:PendingIdentity,ca:Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil,data as CFData),let root = SecCertificateCreateWithData(nil,ca as CFData),
              let publicKey = SecCertificateCopyKey(certificate),
              SecKeyCopyExternalRepresentation(publicKey,nil) as Data? == identity.publicPoint else { throw Failure.invalidIdentity }
        guard let before = SecCertificateCopyNotValidBeforeDate(certificate) as Date?,
              let after = SecCertificateCopyNotValidAfterDate(certificate) as Date?,
              after.timeIntervalSince(before) > 0, after.timeIntervalSince(before) <= 365*86400+600 else { throw Failure.invalidIdentity }
        var trust:SecTrust?
        guard SecTrustCreateWithCertificates(certificate,SecPolicyCreateSSL(false,nil),&trust) == errSecSuccess,let trust,
              SecTrustSetAnchorCertificates(trust,[root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust,true) == errSecSuccess,
              SecTrustEvaluateWithError(trust,nil) else { throw Failure.invalidIdentity }
        let attributes:[String:Any] = [kSecClass as String:kSecClassCertificate,kSecValueRef as String:certificate,kSecAttrLabel as String:identity.tag]
        let status = SecItemAdd(attributes as CFDictionary,nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }
    /// Called only at cold initialization, after the saved-host archive loads.
    /// A terminated enrollment can leave a permanent key before host persistence.
    /// Never remove keys if that archive was unavailable (for example, locked).
    static func removeAbandonedEnrollments(keeping:Set<String>) {
        for itemClass in [kSecClassKey,kSecClassCertificate] {
            let query:[String:Any] = [kSecClass as String:itemClass,kSecReturnAttributes as String:true,kSecMatchLimit as String:kSecMatchLimitAll]
            var result:CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,
                  let items = result as? [[String:Any]] else { continue }
            for item in items {
                let tag:String?
                if itemClass == kSecClassKey,let data = item[kSecAttrApplicationTag as String] as? Data {
                    tag = String(data:data,encoding:.utf8)
                } else { tag = item[kSecAttrLabel as String] as? String }
                guard let tag,tag.hasPrefix("com.golfcore.spatialpc.peer."),!keeping.contains(tag) else { continue }
                removeIdentity(keyTag:tag,certificate:nil)
            }
        }
    }
    static func removeIdentity(keyTag:String,certificate:Data?) {
        let key:[String:Any] = [kSecClass as String:kSecClassKey,kSecAttrApplicationTag as String:Data(keyTag.utf8)]
        SecItemDelete(key as CFDictionary)
        // Delete only the certificate created with this enrollment key tag.
        let cert:[String:Any] = [kSecClass as String:kSecClassCertificate,kSecAttrLabel as String:keyTag]
        SecItemDelete(cert as CFDictionary)
    }
}
