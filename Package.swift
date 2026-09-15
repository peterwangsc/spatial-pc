// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
let dependencyPath = (try? String(contentsOf:root.appendingPathComponent(".local/pairing/source-path.txt"),encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? root.appendingPathComponent(".local/dependencies/boringssl").path
let package = Package(name: "SpatialPCValidation", platforms: [.macOS(.v15)], targets: [
    .target(name:"XRCore",path:"visionos/SpatialPC/XR",exclude:["XRFocusSession.swift","Focus.entitlements"],sources:["XRConnectionGate.swift"]),
    .testTarget(name:"XRCoreTests",dependencies:["XRCore"],path:"tests/XRCoreTests"),
    .target(name:"SpatialPake",path:"shared/pairing",exclude:["boringssl.lock.json","BORINGSSL-LICENSE","README.md"],sources:["spatial_pake.c"],publicHeadersPath:"include",
        cSettings:[.unsafeFlags(["-I",dependencyPath+"/include","-DBORINGSSL_PREFIX=SPATIALPC_BSSL"])],
        linkerSettings:[.linkedLibrary("c++"),.unsafeFlags([root.appendingPathComponent(".local/pairing/macosx/libcrypto.a").path])]),
    .target(name:"StreamCore", path:"visionos/SpatialPC/Streaming", sources:["ExactStreamReader.swift","StreamWire.swift", "H264Decoder.swift", "VideoColorConversion.swift","InputWire.swift"]),
    .target(name:"PairingCore",dependencies:["SpatialPake"],path:"visionos/SpatialPC/Pairing",exclude:["PairingClient.swift"],sources:["PairingWire.swift","PairedHostStore.swift","PairingPAKE.swift","PairingV2Wire.swift","PairingAttemptBudget.swift"]),
    .testTarget(name:"PairingCoreTests",dependencies:["PairingCore"],path:"tests/PairingCoreTests",resources:[.copy("pairing-v1-test-vector.json"),.copy("pairing-v2-test-vector.json")]),
    .testTarget(name:"StreamCoreTests", dependencies:["StreamCore"], path:"tests/StreamCoreTests")
])
