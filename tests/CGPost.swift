import CoreGraphics
import Foundation

func flags(_ value: String) -> CGEventFlags {
    var result = CGEventFlags()
    for component in value.split(separator: ",") {
        switch component {
        case "command": result.insert(.maskCommand)
        case "shift": result.insert(.maskShift)
        case "control": result.insert(.maskControl)
        case "option": result.insert(.maskAlternate)
        default: break
        }
    }
    return result
}

func chord(_ desired: CGEventFlags, down: Bool) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: down)!
    event.flags = down ? desired : []
    event.post(tap: .cghidEventTap)
}

let arguments = CommandLine.arguments
precondition(arguments.count >= 2)
let postAccess = CGPreflightPostEventAccess()
fputs("CGEvent post access: \(postAccess)\n", stderr)
switch arguments[1] {
case "modifier-double":
    _ = CGKeyCode(UInt16(arguments[2])!)
    let eventFlags = flags(arguments[3])
    let gap = useconds_t((UInt32(arguments[4]) ?? 120) * 1_000)
    chord(eventFlags, down: true)
    usleep(40_000)
    chord(eventFlags, down: false)
    usleep(gap)
    chord(eventFlags, down: true)
    usleep(40_000)
    chord(eventFlags, down: false)
case "modifier-hold":
    _ = CGKeyCode(UInt16(arguments[2])!)
    let eventFlags = flags(arguments[3])
    let duration = useconds_t((UInt32(arguments[4]) ?? 450) * 1_000)
    chord(eventFlags, down: true)
    usleep(duration)
    chord(eventFlags, down: false)
case "click-appkit":
    let x = Double(arguments[2])!
    let appKitY = Double(arguments[3])!
    let point = CGPoint(x: x, y: appKitY)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
default:
    fatalError("unknown mode")
}
