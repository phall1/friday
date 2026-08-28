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

func modifier(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
    event.type = .flagsChanged
    event.flags = down ? flags : []
    event.post(tap: .cghidEventTap)
}

let arguments = CommandLine.arguments
precondition(arguments.count >= 2)
switch arguments[1] {
case "modifier-double":
    let keyCode = CGKeyCode(UInt16(arguments[2])!)
    let eventFlags = flags(arguments[3])
    let gap = useconds_t((UInt32(arguments[4]) ?? 120) * 1_000)
    modifier(keyCode, down: true, flags: eventFlags)
    usleep(40_000)
    modifier(keyCode, down: false, flags: [])
    usleep(gap)
    modifier(keyCode, down: true, flags: eventFlags)
    usleep(40_000)
    modifier(keyCode, down: false, flags: [])
case "modifier-hold":
    let keyCode = CGKeyCode(UInt16(arguments[2])!)
    let eventFlags = flags(arguments[3])
    let duration = useconds_t((UInt32(arguments[4]) ?? 450) * 1_000)
    modifier(keyCode, down: true, flags: eventFlags)
    usleep(duration)
    modifier(keyCode, down: false, flags: [])
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
