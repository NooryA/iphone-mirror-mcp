import Darwin
import CoreGraphics
import Foundation
import ApplicationServices

/// Private WindowServer entry points. GUIWeave's iPhone Mirroring daemon uses
/// the same set: SLEventPostToPid + CGEventSetWindowLocation + SLPSPostEventRecordTo.
enum SkyLight {
    typealias EventPostToPid = @convention(c) (pid_t, CGEvent?) -> Void
    typealias SetWindowLocation = @convention(c) (CGEvent?, Double, Double) -> Void
    typealias PostEventRecordTo = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    typealias GetFrontProcess = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW | RTLD_GLOBAL
        )
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        _ = handle
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(raw, to: T.self)
    }

    private static let postFn: EventPostToPid? = symbol("SLEventPostToPid", as: EventPostToPid.self)
    private static let setWindowLocationFn: SetWindowLocation? = symbol(
        "CGEventSetWindowLocation",
        as: SetWindowLocation.self
    )
    private static let postRecordFn: PostEventRecordTo? = symbol(
        "SLPSPostEventRecordTo",
        as: PostEventRecordTo.self
    )
    private static let getFrontFn: GetFrontProcess? = symbol(
        "_SLPSGetFrontProcess",
        as: GetFrontProcess.self
    )
    private static let getPidPsnFn: GetProcessForPID? = symbol(
        "GetProcessForPID",
        as: GetProcessForPID.self
    )

    static var isAvailable: Bool { postFn != nil }

    static func address(_ event: CGEvent, win: MirrorWindow, at global: CGPoint) {
        address(
            event,
            win: win,
            global: global,
            localTopLeft: CGPoint(x: global.x - win.x, y: global.y - win.y)
        )
    }

    static func address(_ event: CGEvent, win: MirrorWindow, global: CGPoint, localTopLeft: CGPoint) {
        event.location = global
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(win.pid))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(win.pid))
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointer,
            value: Int64(win.windowId)
        )
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: Int64(win.windowId)
        )
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        if let setWindowLocationFn {
            setWindowLocationFn(event, localTopLeft.x, localTopLeft.y)
        }
    }

    static func post(_ event: CGEvent, to pid: pid_t) throws {
        guard let postFn else {
            throw MirrorError.invalidArgs("SkyLight SLEventPostToPid is not available")
        }
        postFn(pid, event)
    }

    /// yabai / cua-driver: make the target AppKit-key without raising or Space-follow.
    @discardableResult
    static func focusWithoutRaise(pid: pid_t, windowId: UInt32) -> Bool {
        guard let postRecordFn, let getFrontFn, let getPidPsnFn else { return false }
        var front = [UInt8](repeating: 0, count: 8)
        var target = [UInt8](repeating: 0, count: 8)
        let frontOk = front.withUnsafeMutableBytes { getFrontFn($0.baseAddress!) } == 0
        let targetOk = target.withUnsafeMutableBytes { getPidPsnFn(pid, $0.baseAddress!) } == 0
        guard frontOk, targetOk else { return false }

        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x08] = 0x0D
        let wid = windowId.littleEndian
        withUnsafeBytes(of: wid) { raw in
            for i in 0..<4 { bytes[0x3C + i] = raw[i] }
        }

        bytes[0x8A] = 0x02
        _ = front.withUnsafeBytes { fp in
            bytes.withUnsafeBytes { bp in
                postRecordFn(fp.baseAddress!, bp.baseAddress!)
            }
        }
        usleep(40_000)
        bytes[0x8A] = 0x01
        _ = target.withUnsafeBytes { tp in
            bytes.withUnsafeBytes { bp in
                postRecordFn(tp.baseAddress!, bp.baseAddress!)
            }
        }
        return true
    }
}
