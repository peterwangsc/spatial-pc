// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SpatialPCValidation", platforms: [.macOS(.v15)], targets: [
    .target(name:"StreamCore", path:"visionos/SpatialPC/Streaming", sources:["StreamWire.swift", "H264Decoder.swift"]),
    .testTarget(name:"StreamCoreTests", dependencies:["StreamCore"], path:"tests/StreamCoreTests")
])
