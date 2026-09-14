// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SpatialPCValidation", platforms: [.macOS(.v15)], targets: [
    .target(name:"StreamCore", path:"visionos/SpatialPC/Streaming", sources:["StreamWire.swift", "H264Decoder.swift", "VideoColorConversion.swift","InputWire.swift"]),
    .target(name:"PairingCore",path:"visionos/SpatialPC/Pairing",exclude:["PairingClient.swift"],sources:["PairingWire.swift","PairedHostStore.swift"]),
    .testTarget(name:"PairingCoreTests",dependencies:["PairingCore"],path:"tests/PairingCoreTests",resources:[.copy("pairing-v1-test-vector.json")]),
    .testTarget(name:"StreamCoreTests", dependencies:["StreamCore"], path:"tests/StreamCoreTests")
])
