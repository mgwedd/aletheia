import Foundation

// Entry point of the bundled network helper (an XPC service). The delegate is
// held by this top-level binding for the life of the process.
let listenerDelegate = HelperListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = listenerDelegate
listener.resume()
