import CoreVideo
import simd

/// Matches VideoColorConversion in Desktop.metal. SIMD vectors keep CPU/GPU layout identical.
struct VideoColorConversion: Sendable {
    var transform = matrix_identity_float4x4
    var options = SIMD4<UInt32>(repeating:0)
    var chromaOffset = SIMD4<Float>(repeating:0)

    enum Matrix { case bt601, bt709, bt2020 }
    init() {}
    init(matrix: Matrix, fullRange: Bool) {
        let kr: Float, kb: Float
        switch matrix {
        case .bt601: kr = 0.299; kb = 0.114
        case .bt709: kr = 0.2126; kb = 0.0722
        case .bt2020: kr = 0.2627; kb = 0.0593
        }
        let kg = 1-kr-kb
        let yScale: Float = fullRange ? 1 : 255/219
        let cScale: Float = fullRange ? 1 : 255/224
        let yOffset: Float = fullRange ? 0 : 16/255
        let cOffset: Float = 128/255
        let y = SIMD4<Float>(yScale,yScale,yScale,0)
        let cb = SIMD4<Float>(0,-2*kb*(1-kb)/kg*cScale,2*(1-kb)*cScale,0)
        let cr = SIMD4<Float>(2*(1-kr)*cScale,-2*kr*(1-kr)/kg*cScale,0,0)
        let offset = -y*yOffset - cb*cOffset - cr*cOffset + SIMD4<Float>(0,0,0,1)
        transform = simd_float4x4(columns:(y,cb,cr,offset))
        options.x = 1
    }
    init(pixel: CVPixelBuffer) {
        let type = CVPixelBufferGetPixelFormatType(pixel)
        guard type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            self.init(); return
        }
        let key = CVBufferCopyAttachment(pixel,kCVImageBufferYCbCrMatrixKey,nil) as? String
        let matrix: Matrix
        if key == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { matrix = .bt601 }
        else if key == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String { matrix = .bt709 }
        else if key == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { matrix = .bt2020 }
        else { matrix = CVPixelBufferGetHeight(pixel) >= 720 ? .bt709 : .bt601 }
        self.init(matrix:matrix,fullRange:type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let location = CVBufferCopyAttachment(pixel,kCVImageBufferChromaLocationTopFieldKey,nil) as? String
        let x = 0.5/Float(CVPixelBufferGetWidth(pixel)), y = 0.5/Float(CVPixelBufferGetHeight(pixel))
        if location == kCVImageBufferChromaLocation_Left as String { chromaOffset.x = x }
        else if location == kCVImageBufferChromaLocation_TopLeft as String { chromaOffset.x = x; chromaOffset.y = y }
        else if location == kCVImageBufferChromaLocation_Top as String { chromaOffset.y = y }
        else if location == kCVImageBufferChromaLocation_BottomLeft as String { chromaOffset.x = x; chromaOffset.y = -y }
        else if location == kCVImageBufferChromaLocation_Bottom as String { chromaOffset.y = -y }
    }
}
