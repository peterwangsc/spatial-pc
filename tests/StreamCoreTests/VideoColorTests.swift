import XCTest
import CoreVideo
import simd
@testable import StreamCore

final class VideoColorTests: XCTestCase {
    func testVideoRangePrimariesAndNeutralLevels() {
        let conversion = VideoColorConversion(matrix:.bt709,fullRange:false)
        func rgb(_ y: Float, _ cb: Float, _ cr: Float) -> SIMD3<Float> {
            let v = conversion.transform * SIMD4<Float>(y/255,cb/255,cr/255,1)
            return SIMD3(v.x,v.y,v.z)
        }
        for (actual, expected) in [(rgb(16,128,128),SIMD3<Float>.zero),
                                    (rgb(235,128,128),SIMD3<Float>(repeating:1)),
                                    (rgb(63,102,240),SIMD3<Float>(1,0,0)),
                                    (rgb(173,42,26),SIMD3<Float>(0,1,0)),
                                    (rgb(32,240,118),SIMD3<Float>(0,0,1))] {
            for i in 0..<3 { XCTAssertEqual(actual[i],expected[i],accuracy:0.01) }
        }
    }
    func testFullRangeAndShaderLayout() {
        XCTAssertEqual(MemoryLayout<VideoColorConversion>.stride,96)
        let conversion = VideoColorConversion(matrix:.bt601,fullRange:true)
        for level: Float in [0,0.5,1] {
            let v = conversion.transform * SIMD4<Float>(level,128/255,128/255,1)
            XCTAssertEqual(v.x,level,accuracy:0.00001)
            XCTAssertEqual(v.y,level,accuracy:0.00001)
            XCTAssertEqual(v.z,level,accuracy:0.00001)
        }
    }
    func testMetadataOverridesResolutionAndHonorsChromaLocation() {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,640,480,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nil,&buffer),kCVReturnSuccess)
        let pixel = buffer!
        CVBufferSetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(pixel,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Left,.shouldPropagate)
        let actual = VideoColorConversion(pixel:pixel)
        let expected = VideoColorConversion(matrix:.bt709,fullRange:false)
        XCTAssertEqual(actual.transform,expected.transform)
        XCTAssertEqual(actual.chromaOffset.x,0.5/640,accuracy:0.000001)
        XCTAssertEqual(actual.chromaOffset.y,0)
    }
}
