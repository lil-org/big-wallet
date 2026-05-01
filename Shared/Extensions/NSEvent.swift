// ∅ 2026 lil org

#if os(macOS)
import AppKit

extension NSEvent {

    static func addCommandQShortcutMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        return addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.isCommandQShortcut else { return event }
            return handler(event)
        }
    }

    var isCommandQShortcut: Bool {
        let ignoredFlags: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function]
        let flags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(ignoredFlags)

        return flags == .command && charactersIgnoringModifiers?.lowercased() == "q"
    }

}
#endif
