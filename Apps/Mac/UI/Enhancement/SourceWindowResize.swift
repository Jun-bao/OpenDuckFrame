import AppKit
@preconcurrency import ApplicationServices
import Darwin

// Only this experimental source-window feature uses this undocumented SPI.
// No geometry-only fallback is permitted, and this is unavailable in App Store builds.
enum SourceWindowResize {
    struct Selected: @unchecked Sendable { let element: AXUIElement; let id: CGWindowID; let pid: pid_t }
    enum Failure: Error { case denied, unavailable, windowMissing, ambiguous, notResizable, geometry, failed }
    #if !SP_APP_STORE
    private typealias GetWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static func id(_ element: AXUIElement) -> CGWindowID? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        let fn = unsafeBitCast(symbol, to: GetWindowID.self); var result: CGWindowID = 0
        return fn(element, &result) == .success && result != 0 ? result : nil
    }
    #endif
    static func find(pid: pid_t, windowID: CGWindowID) -> Result<Selected, Failure> {
        #if SP_APP_STORE
        return .failure(.unavailable)
        #else
        guard AXIsProcessTrusted() else { return .failure(.denied) }
        guard dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") != nil else { return .failure(.unavailable) }
        let app = AXUIElementCreateApplication(pid); _ = AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return .failure(.windowMissing) }
        var matches: [AXUIElement] = []
        for window in windows {
            _ = AXUIElementSetMessagingTimeout(window, 0.2)
            var owner: pid_t = 0
            if AXUIElementGetPid(window, &owner) == .success && owner == pid && id(window) == windowID { matches.append(window) }
        }
        guard matches.count == 1, let window = matches.first else { return .failure(matches.isEmpty ? .windowMissing : .ambiguous) }
        return .success(Selected(element: window, id: windowID, pid: pid))
        #endif
    }
    private static func bounds(_ selected: Selected) -> CGRect? {
        var pValue: CFTypeRef?, sValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(selected.element, kAXPositionAttribute as CFString, &pValue) == .success,
              AXUIElementCopyAttributeValue(selected.element, kAXSizeAttribute as CFString, &sValue) == .success,
              let pValue, let sValue, CFGetTypeID(pValue) == AXValueGetTypeID(), CFGetTypeID(sValue) == AXValueGetTypeID() else { return nil }
        var point=CGPoint.zero, size=CGSize.zero
        guard AXValueGetValue(unsafeDowncast(pValue, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeDowncast(sValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func verify(_ selected: Selected, captureRect: CGRect, scale: CGFloat, target: CGSize, cgBounds: CGRect) -> Bool {
        #if SP_APP_STORE
        return false
        #else
        var owner: pid_t = 0
        guard AXIsProcessTrusted(), id(selected.element) == selected.id,
              AXUIElementGetPid(selected.element, &owner) == .success, owner == selected.pid,
              let frame = bounds(selected), P1AXInvestigation.rectMatches(frame, cgBounds),
              frame.insetBy(dx:-2,dy:-2).contains(captureRect), scale.isFinite, scale >= 1, scale <= 4 else { return false }
        return abs(captureRect.width*scale-target.width) <= 1 && abs(captureRect.height*scale-target.height) <= 1
        #endif
    }
    static func setSize(_ selected: Selected, target: CGSize, screenRect: CGRect, scale: CGFloat, expectedBounds: CGRect, displayBounds: CGRect) -> Result<Void, Failure> {
        #if SP_APP_STORE
        return .failure(.unavailable)
        #else
        guard AXIsProcessTrusted() else { return .failure(.denied) }
        guard id(selected.element) == selected.id else { return .failure(.windowMissing) }
        var owner: pid_t = 0; guard AXUIElementGetPid(selected.element, &owner) == .success, owner == selected.pid else { return .failure(.windowMissing) }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(selected.element, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue else { return .failure(.notResizable) }
        guard let frame = bounds(selected), P1AXInvestigation.rectMatches(frame, expectedBounds),
              scale.isFinite, scale >= 1, scale <= 4, expectedBounds.insetBy(dx: -2, dy: -2).contains(screenRect),
              !displayBounds.isNull, displayBounds.width > 0, displayBounds.height > 0 else { return .failure(.geometry) }
        guard let planned = SourceWindowSizePolicy.frame(frame: frame, capture: screenRect, display: displayBounds, pixels: target, scale: scale) else { return .failure(.geometry) }
        var wanted = planned.size
        var position = planned.origin
        let mustMove = abs(position.x-frame.minX) > 0.5 || abs(position.y-frame.minY) > 0.5
        if mustMove {
            var movable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(selected.element, kAXPositionAttribute as CFString, &movable) == .success, movable.boolValue else { return .failure(.notResizable) }
        }
        guard let sizeValue = AXValueCreate(.cgSize, &wanted), AXUIElementSetAttributeValue(selected.element, kAXSizeAttribute as CFString, sizeValue) == .success else { return .failure(.failed) }
        if mustMove {
            guard let positionValue=AXValueCreate(.cgPoint, &position), AXUIElementSetAttributeValue(selected.element, kAXPositionAttribute as CFString, positionValue) == .success else { return .failure(.failed) }
        }
        return .success(())
        #endif
    }
}
