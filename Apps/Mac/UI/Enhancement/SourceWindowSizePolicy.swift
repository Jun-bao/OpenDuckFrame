import CoreGraphics

// Geometry only. AX identity, permissions and frame capture remain separate checks.
enum SourceWindowSizePolicy {
    static func frame(frame: CGRect, capture: CGRect, display: CGRect, pixels: CGSize, scale: CGFloat) -> CGRect? {
        let values = [frame.minX, frame.minY, frame.width, frame.height, capture.minX, capture.minY, capture.width, capture.height,
                      display.minX, display.minY, display.width, display.height, pixels.width, pixels.height, scale]
        guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0, capture.width > 0, capture.height > 0,
              display.width > 0, display.height > 0, pixels.width > 0, pixels.height > 0, scale >= 1, scale <= 4,
              frame.insetBy(dx: -2, dy: -2).contains(capture), display.intersects(frame) else { return nil }
        let extraW=frame.width-capture.width, extraH=frame.height-capture.height
        guard extraW >= -2, extraH >= -2, extraW <= 256, extraH <= 256 else { return nil }
        let width=pixels.width/scale + max(0,extraW), height=pixels.height/scale + max(0,extraH)
        guard width <= display.width, height <= display.height else { return nil }
        return CGRect(x:min(max(frame.minX,display.minX),display.maxX-width),
                      y:min(max(frame.minY,display.minY),display.maxY-height),width:width,height:height)
    }
    static func freshFrame(host: UInt64, after: UInt64, frameGeneration: UInt64, currentGeneration: UInt64, frameWindow: UInt32, targetWindow: UInt32) -> Bool {
        after > 0 && host > after && currentGeneration > 0 && frameGeneration == currentGeneration && frameWindow == targetWindow && targetWindow != 0
    }
}
