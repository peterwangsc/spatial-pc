import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// One synchronous decode at a time. Network receive waits until this finishes,
/// bounding app decode work; TCP backpressure is an M1 latency limitation.
// The owner submits exclusively on one serial decode queue and awaits completion.
final class H264Decoder: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        // Immutable decoded image; renderer only reads it and retains through GPU completion.
        let pixel: CVPixelBuffer
        let decodeMS: Double
        let hardware: Bool
    }
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var configuredSPS: Data?
    private var configuredPPS: Data?
    private let width: Int
    private let height: Int
    private(set) var hardware = false
    private var needsIDR = true
    private(set) var lastDecodeMS = 0.0

    enum Failure: Error { case osStatus(OSStatus), dimensions, noHardware }
    init(width: Int, height: Int) { self.width = width; self.height = height }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.osStatus(status) }
    }
    private func configure() throws {
        guard let sps, let pps else { return }
        if configuredSPS == sps && configuredPPS == pps { return }
        if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
        let status = sps.withUnsafeBytes { a in pps.withUnsafeBytes { b in
            let pointers = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }}
        try check(status)
        guard let format else { throw Failure.dimensions }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == width, dimensions.height == height else { throw Failure.dimensions }
        #if targetEnvironment(simulator)
        let specification: [String: Any] = [:]
        #else
        let specification: [String: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true]
        #endif
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: specification as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session))
        guard let session else { throw Failure.noHardware }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var value: Unmanaged<CFTypeRef>?
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &value)
        hardware = (value?.takeRetainedValue() as? Bool) == true
        #if !targetEnvironment(simulator)
        guard hardware else { throw Failure.noHardware }
        #endif
        configuredSPS = sps; configuredPPS = pps; needsIDR = true
    }
    func decode(_ data: Data, timestamp: Int64) throws -> Frame? {
        let begin = CFAbsoluteTimeGetCurrent()
        let units = try StreamWire.annexBUnits(data)
        for unit in units {
            if unit.first! & 31 == 7 { sps = unit }
            if unit.first! & 31 == 8 { pps = unit }
        }
        try configure()
        guard let session, let format else { return nil }
        let slices = units.filter { (1...5).contains($0.first! & 31) }
        guard !slices.isEmpty else { return nil }
        if needsIDR && !slices.contains(where: { $0.first! & 31 == 5 }) { return nil }
        needsIDR = false
        let avcc = StreamWire.avcc(slices)
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault, memoryBlock:nil,
            blockLength:avcc.count, blockAllocator:kCFAllocatorDefault, customBlockSource:nil,
            offsetToData:0, dataLength:avcc.count, flags:0, blockBufferOut:&block))
        guard let block else { return nil }
        try avcc.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(with:bytes.baseAddress!, blockBuffer:block,
                offsetIntoDestination:0, dataLength:avcc.count))
        }
        var timing = CMSampleTimingInfo(duration:.invalid, presentationTimeStamp:CMTime(value:timestamp,timescale:10_000_000), decodeTimeStamp:.invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault, dataBuffer:block,
            formatDescription:format, sampleCount:1, sampleTimingEntryCount:1,
            sampleTimingArray:&timing, sampleSizeEntryCount:1, sampleSizeArray:&size, sampleBufferOut:&sample))
        guard let sample else { return nil }
        // The flags omit asynchronous decoding. Wait still covers codecs that defer output.
        final class Output: @unchecked Sendable {
            let lock = NSLock()
            var pixel: CVPixelBuffer?
            var status: OSStatus = noErr
        }
        let result = Output()
        try check(VTDecompressionSessionDecodeFrame(session, sampleBuffer:sample, flags:[], infoFlagsOut:nil) { status, _, pixel, _, _ in
            result.lock.lock(); defer { result.lock.unlock() }
            result.status = status; result.pixel = pixel
        })
        try check(VTDecompressionSessionWaitForAsynchronousFrames(session))
        try check(result.status)
        lastDecodeMS = (CFAbsoluteTimeGetCurrent()-begin)*1000
        return result.pixel.map { Frame(pixel:$0,decodeMS:lastDecodeMS,hardware:hardware) }
    }
}
