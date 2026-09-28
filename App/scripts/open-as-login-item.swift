// Opens the app the way macOS does at login, with keyAELaunchedAsLogInItem in its open event, so that
// starting at login can be tried without logging out.
//
//   swift App/scripts/open-as-login-item.swift path/to/Flatlink.app
//
// Quit Flatlink first: an app that is already running is only brought forward.
import AppKit
let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
let config = NSWorkspace.OpenConfiguration()
config.appleEvent = event
config.activates = false
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: config) { app, error in
    print(app.map { "launched pid \($0.processIdentifier)" } ?? "failed: \(String(describing: error))")
    done.signal()
}
done.wait()
