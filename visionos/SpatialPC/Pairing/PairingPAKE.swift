import Foundation
import CryptoKit
import SpatialPake

/// Single-use ownership of the pinned native SPAKE2 primitive. No network IO.
final class PairingPAKE {
    private var state: OpaquePointer?
    let message: Data
    init(pin: Data, clientName: Data, serverName: Data, client: Bool = true) throws {
        guard pin.count == 4 else { throw PairingWire.Failure.invalidCode }
        var message = Data(count: 32)
        let local = client ? clientName : serverName
        let peer = client ? serverName : clientName
        let created = pin.withUnsafeBytes { pinBytes in
            local.withUnsafeBytes { localBytes in
                peer.withUnsafeBytes { peerBytes in
                    message.withUnsafeMutableBytes { output in
                        spatial_pake_create(client ? 0 : 1,
                            pinBytes.bindMemory(to: UInt8.self).baseAddress, pin.count,
                            localBytes.bindMemory(to: UInt8.self).baseAddress, local.count,
                            peerBytes.bindMemory(to: UInt8.self).baseAddress, peer.count,
                            output.bindMemory(to: UInt8.self).baseAddress, output.count)
                    }
                }
            }
        }
        guard let created else { throw PairingWire.Failure.authentication }
        state = created
        self.message = message
    }
    deinit { if let state { spatial_pake_destroy(state) } }
    func confirmationKey(peerMessage: Data, transcript: Data) throws -> SymmetricKey {
        guard let current = state else { throw PairingWire.Failure.authentication }
        state = nil
        defer { spatial_pake_destroy(current) }
        var raw = Data(count: 64)
        defer {
            raw.withUnsafeMutableBytes { bytes in
                spatial_pake_cleanse(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        }
        let ok = peerMessage.withUnsafeBytes { peer in
            raw.withUnsafeMutableBytes { key in
                spatial_pake_finish(current, peer.bindMemory(to: UInt8.self).baseAddress, peer.count,
                    key.bindMemory(to: UInt8.self).baseAddress, key.count)
            }
        }
        guard ok == 1 else { throw PairingWire.Failure.authentication }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw),
            salt: Data(SHA256.hash(data: transcript)),
            info: Data("SpatialPC-Pair-v2/confirm\0".utf8), outputByteCount: 32)
    }
}
