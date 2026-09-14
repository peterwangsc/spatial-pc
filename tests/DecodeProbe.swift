import Foundation
@main struct Probe {
 static func exact(_ count:Int) throws -> Data {
  var data=Data()
  while data.count<count { guard let more=try FileHandle.standardInput.read(upToCount:count-data.count),!more.isEmpty else {throw CocoaError(.fileReadUnknown)};data.append(more) }
  return data
 }
 static func main() throws {
  let count=try StreamWire.helloLength(exact(8))
  let caps=try StreamWire.capabilities(exact(count))
  let decoder=H264Decoder(width:caps.width,height:caps.height)
  var decoded=0;var milliseconds=[Double]();let start=Date()
  for _ in 0..<120 {
   let head=try StreamWire.frameHeader(exact(16))
   if let frame=try decoder.decode(exact(head.length),timestamp:head.timestamp) {decoded+=1;milliseconds.append(frame.decodeMS)}
  }
  milliseconds.sort()
  print("decoded=\(decoded) hardware=\(decoder.hardware) elapsed_s=\(Date().timeIntervalSince(start)) median_decode_ms=\(milliseconds[milliseconds.count/2])")
 }
}
