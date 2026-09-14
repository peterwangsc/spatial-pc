// Compile alongside StreamWire, H264Decoder and VideoColorConversion. Reads a
// synthetic SPC1 fixture, compares the production GPU path with VideoToolbox BGRA,
// and reports errors only. No pixel data is written.
import Foundation
import Metal
import CoreVideo

@main struct VideoColorProbe {
    enum Failure: Error { case missing, mismatch }
    static func exact(_ count:Int) throws -> Data {
        var data=Data()
        while data.count<count {
            guard let more=try FileHandle.standardInput.read(upToCount:count-data.count),!more.isEmpty else {throw Failure.missing}
            data.append(more)
        }
        return data
    }
    static func main() throws {
        let caps=try StreamWire.capabilities(exact(StreamWire.helloLength(exact(8))))
        let nv12=H264Decoder(width:caps.width,height:caps.height)
        let bgra=H264Decoder(width:caps.width,height:caps.height,outputFormat:kCVPixelFormatType_32BGRA)
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {throw Failure.missing}
        let source=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
        let library=try device.makeLibrary(source:source,options:nil)
        let compute=try device.makeComputePipelineState(function:library.makeFunction(name:"videoToBGRA")!)
        let renderDescriptor=MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction=library.makeFunction(name:"desktopVertex")
        renderDescriptor.fragmentFunction=library.makeFunction(name:"desktopFragment")
        renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let render=try device.makeRenderPipelineState(descriptor:renderDescriptor)
        var cache:CVMetalTextureCache?;CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:caps.width,height:caps.height,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = [.shaderWrite,.shaderRead,.renderTarget]
        let computed=device.makeTexture(descriptor:descriptor)!,rendered=device.makeTexture(descriptor:descriptor)!
        var differences=[Int](),pathDifferences=[Int](),scalarDifferences=[Int](),flatDifferences=[Int]()
        var gpuMS=[Double]()
        for _ in 0..<3 {
            let header=try StreamWire.frameHeader(exact(16));let payload=try exact(header.length)
            guard let yuv=try nv12.decode(payload,timestamp:header.timestamp),let rgb=try bgra.decode(payload,timestamp:header.timestamp) else {continue}
            var references=[CVMetalTexture]()
            func map(_ plane:Int,_ format:MTLPixelFormat)->MTLTexture {
                var value:CVMetalTexture?
                let code=CVMetalTextureCacheCreateTextureFromImage(nil,cache!,yuv.pixel,nil,format,
                    CVPixelBufferGetWidthOfPlane(yuv.pixel,plane),CVPixelBufferGetHeightOfPlane(yuv.pixel,plane),plane,&value)
                precondition(code==kCVReturnSuccess);references.append(value!);return CVMetalTextureGetTexture(value!)!
            }
            let luma=map(0,.r8Unorm),chroma=map(1,.rg8Unorm)
            var conversion=VideoColorConversion(pixel:yuv.pixel)

            let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(compute)
            encoder.setTexture(luma,index:0);encoder.setTexture(chroma,index:1);encoder.setTexture(computed,index:2)
            encoder.setBytes(&conversion,length:MemoryLayout<VideoColorConversion>.stride,index:0)
            encoder.dispatchThreads(MTLSize(width:caps.width,height:caps.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
            encoder.endEncoding()
            let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=rendered
            pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
            let drawing=command.makeRenderCommandEncoder(descriptor:pass)!
            drawing.setRenderPipelineState(render);drawing.setFragmentTexture(luma,index:0);drawing.setFragmentTexture(chroma,index:1)
            drawing.setFragmentBytes(&conversion,length:MemoryLayout<VideoColorConversion>.stride,index:0)
            drawing.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);drawing.endEncoding()
            command.commit();command.waitUntilCompleted();withExtendedLifetime(references) {}
            guard command.status == .completed else {throw Failure.mismatch}
            gpuMS.append((command.gpuEndTime-command.gpuStartTime)*1000)
            var a=[UInt8](repeating:0,count:caps.width*caps.height*4),b=a
            let region=MTLRegionMake2D(0,0,caps.width,caps.height)
            computed.getBytes(&a,bytesPerRow:caps.width*4,from:region,mipmapLevel:0)
            rendered.getBytes(&b,bytesPerRow:caps.width*4,from:region,mipmapLevel:0)
            CVPixelBufferLockBaseAddress(rgb.pixel,.readOnly)
            let reference=CVPixelBufferGetBaseAddress(rgb.pixel)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(rgb.pixel)
            CVPixelBufferLockBaseAddress(yuv.pixel,.readOnly)
            let yBase=CVPixelBufferGetBaseAddressOfPlane(yuv.pixel,0)!.assumingMemoryBound(to:UInt8.self)
            let cBase=CVPixelBufferGetBaseAddressOfPlane(yuv.pixel,1)!.assumingMemoryBound(to:UInt8.self)
            let yStride=CVPixelBufferGetBytesPerRowOfPlane(yuv.pixel,0),cStride=CVPixelBufferGetBytesPerRowOfPlane(yuv.pixel,1)
            let cw=CVPixelBufferGetWidthOfPlane(yuv.pixel,1),ch=CVPixelBufferGetHeightOfPlane(yuv.pixel,1)
            // Independent scalar BT.709 video-range reference. This fixture must
            // have progressive Left chroma: horizontally co-sited, vertically centered.
            guard (CVBufferCopyAttachment(yuv.pixel,kCVImageBufferChromaLocationTopFieldKey,nil) as? String) == (kCVImageBufferChromaLocation_Left as String),
                  (CVBufferCopyAttachment(yuv.pixel,kCVImageBufferYCbCrMatrixKey,nil) as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) else { throw Failure.mismatch }
            func sampleChroma(_ x:Double,_ y:Double,_ c:Int)->Double {
                let left=Int(floor(x)),top=Int(floor(y)),fx=x-floor(x),fy=y-floor(y)
                func pixel(_ x:Int,_ y:Int)->Double { Double(cBase[min(ch-1,max(0,y))*cStride+min(cw-1,max(0,x))*2+c]) }
                return (pixel(left,top)*(1-fx)+pixel(left+1,top)*fx)*(1-fy)+(pixel(left,top+1)*(1-fx)+pixel(left+1,top+1)*fx)*fy
            }
            // Sample a grid across the complete image, including colored edges.
            for y in Swift.stride(from:8,to:caps.height-8,by:17) {
                for x in Swift.stride(from:8,to:caps.width-8,by:17) {
                    let yy=(Double(yBase[y*yStride+x])-16)/219
                    let cb=(sampleChroma(Double(x)/2,Double(y)/2-0.25,0)-128)/224
                    let cr=(sampleChroma(Double(x)/2,Double(y)/2-0.25,1)-128)/224
                    let scalar=[yy+1.8556*cb,yy-0.1873242729306488*cb-0.46812427293064884*cr,yy+1.5748*cr]
                    let flat=(0..<2).allSatisfy { c in
                        let values=[sampleChroma(Double(x)/2,Double(y)/2-0.25,c),sampleChroma(Double(x)/2,Double(y)/2,c)]
                        return abs(values[0]-values[1])<0.001
                    }
                    for c in 0..<3 {
                        let index=(y*caps.width+x)*4+c
                        let error=abs(Int(a[index])-Int(reference[y*stride+x*4+c]))
                        differences.append(error)
                        if flat {flatDifferences.append(error)}
                        scalarDifferences.append(abs(Int(a[index])-Int((min(1,max(0,scalar[c]))*255).rounded())))
                        pathDifferences.append(abs(Int(a[index])-Int(b[index])))
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(rgb.pixel,.readOnly)
            CVPixelBufferUnlockBaseAddress(yuv.pixel,.readOnly)
        }
        guard !differences.isEmpty else {throw Failure.missing}
        differences.sort();pathDifferences.sort();scalarDifferences.sort();flatDifferences.sort()
        let p99=differences[differences.count*99/100],pathMax=pathDifferences.last!
        print("BGRA reference samples=\(differences.count) mean=\(Double(differences.reduce(0,+))/Double(differences.count)) p99=\(p99) max=\(differences.last!) window-vs-focus-max=\(pathMax)")
        print("scalar reference max=\(scalarDifferences.last!) flat BGRA samples=\(flatDifferences.count) p99=\(flatDifferences[flatDifferences.count*99/100]) max=\(flatDifferences.last!)")
        print("combined compute+window GPU milliseconds=\(gpuMS)")
        fflush(stdout)
        guard scalarDifferences.last!<=2,flatDifferences[flatDifferences.count*99/100]<=3,pathMax<=1 else {throw Failure.mismatch}
    }
}
