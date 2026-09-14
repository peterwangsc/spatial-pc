import XCTest
@testable import PairingCore

final class PairedHostStoreTests:XCTestCase {
    private enum StorageFailure:Error { case unavailable }
    private static func host(_ id:String) -> SavedHost {
        SavedHost(id:id,deviceID:id,name:"Test PC",address:"localhost",serviceName:nil,serviceDomain:nil,
                  port:47991,serverName:"test.invalid",serverCertificate:Data(),clientCertificate:Data(),
                  caCertificate:Data(),keyTag:"test-unused-"+id,pairedAt:Date(timeIntervalSince1970:0))
    }
    func testUnavailableArchiveCannotBeOverwrittenAndRecoversAfterReload() async throws {
        try await MainActor.run {
            let original = Self.host("original"), added = Self.host("added")
            struct Archive:Encodable { let hosts:[SavedHost]; let selectedID:String }
            var persisted = try JSONEncoder().encode(Archive(hosts:[original],selectedID:original.id))
            let originalBytes = persisted
            var readable = false, writes = 0, cleanups = 0
            let store = PairedHostStore(load:{
                guard readable else { throw StorageFailure.unavailable }
                return persisted
            },save:{ persisted = $0; writes += 1 },cleanAbandoned:{ _ in cleanups += 1 })

            XCTAssertNotNil(store.error)
            XCTAssertThrowsError(try store.add(added))
            XCTAssertEqual(persisted,originalBytes)
            XCTAssertEqual(writes,0)
            XCTAssertEqual(cleanups,0)

            readable = true; store.reload()
            XCTAssertNil(store.error)
            XCTAssertEqual(store.selected,original)
            try store.add(added)
            XCTAssertEqual(store.hosts,[original,added])
            XCTAssertEqual(writes,1)
        }
    }
    func testFailedSavePreservesLoadedDevices() async throws {
        try await MainActor.run {
            let original = Self.host("original")
            struct Archive:Encodable { let hosts:[SavedHost]; let selectedID:String }
            let data = try JSONEncoder().encode(Archive(hosts:[original],selectedID:original.id))
            let store = PairedHostStore(load:{ data },save:{ _ in throw StorageFailure.unavailable },cleanAbandoned:{ _ in })
            XCTAssertThrowsError(try store.add(Self.host("added")))
            XCTAssertEqual(store.hosts,[original])
            XCTAssertEqual(store.selected,original)
        }
    }
}
