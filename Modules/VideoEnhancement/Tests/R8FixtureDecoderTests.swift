@main struct R8FixtureDecoderTests {
 static func motion(_ format: OSType, _ phase: Int) -> [String: Any] {
  var buffer: CVPixelBuffer?
  precondition(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, format, nil, &buffer) == kCVReturnSuccess)
  let frame = buffer!; let planar = format != kCVPixelFormatType_32BGRA
  CVPixelBufferLockBaseAddress(frame, [])
  let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(frame, 0) : CVPixelBufferGetBaseAddress(frame))!.assumingMemoryBound(to: UInt8.self)
  let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(frame, 0) : CVPixelBufferGetBytesPerRow(frame)
  memset(base, planar ? 32 : 20, stride * 720)
  if planar {
   let uv = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt8.self)
   let uvStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
   memset(uv, 128, uvStride * 360)
   if phase >= 0 {
    for y in 140..<170 { for cx in 150...250 {
     let full = phase == 2 ? (cx >= 151 && cx <= 250) : (cx >= 150 && cx < 250)
     let half = phase == 1 && (cx == 150 || cx == 250)
     if full || half { let i = y * uvStride + cx * 2; uv[i] = half ? 96 : 64; uv[i+1] = half ? 160 : 192 }
    }}
    for y in 280..<340 { memset(base + y * stride + 300, 150, 202) }
   }
  } else if phase >= 0 {
   for y in 280..<340 { for x in 300...500 {
    let full = phase == 2 ? (x >= 301 && x <= 500) : (x >= 300 && x < 500)
    let half = phase == 1 && (x == 300 || x == 500)
    if full || half { let i=y*stride+x*4; base[i]=20; base[i+1]=half ? 85 : 150; base[i+2]=half ? 130 : 240; base[i+3]=255 }
   }}
  }
  if phase == -2 {
   var random: UInt32 = 0x12345678
   func byte() -> UInt8 { random = random &* 1664525 &+ 1013904223; return UInt8((random >> 16) & 255) }
   if planar {
    let uv = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt8.self)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
    for y in [295, 309, 324] { memset(base + y * stride, 128, 1280); for x in 0..<640 { let i=(y/2)*uvStride+x*2; uv[i]=byte(); uv[i+1]=byte() } }
   } else {
    for y in [295, 309, 324] { for x in 0..<1280 { let i=y*stride+x*4; base[i]=byte(); base[i+1]=byte(); base[i+2]=byte() } }
   }
  }
  CVPixelBufferUnlockBaseAddress(frame, [])
  return R8FixtureMotionProbe.sample(frame)
 }
 static func main() {
  for format: OSType in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
   var buffer: CVPixelBuffer?
   precondition(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, format, nil, &buffer) == kCVReturnSuccess)
   let frame = buffer!
   CVPixelBufferLockBaseAddress(frame, [])
   let planar = format != kCVPixelFormatType_32BGRA
   let ptr = (planar ? CVPixelBufferGetBaseAddressOfPlane(frame, 0) : CVPixelBufferGetBaseAddress(frame))!.assumingMemoryBound(to: UInt8.self)
   let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(frame, 0) : CVPixelBufferGetBytesPerRow(frame)
   memset(ptr, 0, rowBytes * 720)
   let marker = [true,true,false,true,false,false,true,true]
   let expected: UInt32 = 0x48a621
   let payload = (0..<24).map { ((expected >> (23 - $0)) & 1) == 1 }
   let bits = marker + payload + payload.map { !$0 } + marker.reversed()
   for y in 80..<120 { for x in 0..<1280 {
    let normalized = (Double(x) / 1280 - 0.08) / 0.84
    let col = Int(floor(normalized * 64))
    if col >= 0 && col < 64 && bits[col] {
      let i = y * rowBytes + x * (planar ? 1 : 4)
      if planar { ptr[i] = 235 } else { ptr[i] = 255; ptr[i+1] = 255; ptr[i+2] = 255; ptr[i+3] = 255 }
    }
   }}
   CVPixelBufferUnlockBaseAddress(frame, [])
   precondition(R8FixtureDecoder.decode(frame) == expected)
   CVPixelBufferLockBaseAddress(frame, [])
   memset(ptr, 0, rowBytes * 720)
   CVPixelBufferUnlockBaseAddress(frame, [])
   precondition(R8FixtureDecoder.decode(frame) == nil)
   let blank = motion(format, -1), noise = motion(format, -2), first = motion(format, 0), same = motion(format, 0)
   let middle = motion(format, 1), next = motion(format, 2)
   precondition((blank["valid"] as? Bool) == false && (noise["valid"] as? Bool) == false)
   for result in [first, same, middle, next] { precondition((result["valid"] as? Bool) == true) }
   let a = first["centroidX"] as! Double, b = same["centroidX"] as! Double
   let c = middle["centroidX"] as! Double, d = next["centroidX"] as! Double
   precondition(abs(a - 399.5) < 0.05 && a == b && c > a && d > c && abs((c - a) - (d - c)) < 0.05)
   precondition(abs((d - a) - (format == kCVPixelFormatType_32BGRA ? 1.0 : 2.0)) < 0.05)
   precondition((first["sampleDurationNs"] as! Double) > 0)
  }
  print("R8 fixture decoder and motion: BGRA/NV12 blank and incoherent noise unknown, repeat stable, translation and interpolated midpoint distinct")
 }
}
