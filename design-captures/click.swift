// Posts a real mouse click at a screen point, in points, for `capture.sh`.
//
//     swiftc -O design-captures/click.swift -o .build/click && .build/click 438 252
//
// Written because there is no other clicker here that the sidebar can see.
// `System Events click at {x, y}` resolves the accessibility element under the
// point and presses it, which a custom-drawn view answering `mouseDown` does not
// implement, so the call succeeds, returns the element it found, and nothing
// happens. The sidebar is custom-drawn precisely because it must take no first
// responder, so this is not a detail a redesign can remove.
//
// Posting needs Accessibility permission for whatever runs it, the same grant
// the AppleScript keystrokes already rely on.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: click <x> <y>\n".utf8))
    exit(2)
}

let point = CGPoint(x: x, y: y)
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
down?.post(tap: .cghidEventTap)
usleep(60_000)
up?.post(tap: .cghidEventTap)
