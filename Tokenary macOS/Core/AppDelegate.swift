// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa
import Carbon

extension String {
  /// This converts string to UInt as a fourCharCode
  public var fourCharCodeValue: Int {
    var result: Int = 0
    if let data = self.data(using: String.Encoding.macOSRoman) {
      data.withUnsafeBytes({ (rawBytes) in
        let bytes = rawBytes.bindMemory(to: UInt8.self)
        for i in 0 ..< data.count {
          result = result << 8 + Int(bytes[i])
        }
      })
    }
    return result
  }
}

class HotkeySolution {
  static
  func getCarbonFlagsFromCocoaFlags(cocoaFlags: NSEvent.ModifierFlags) -> UInt32 {
    let flags = cocoaFlags.rawValue
    var newFlags: Int = 0

    if ((flags & NSEvent.ModifierFlags.control.rawValue) > 0) {
      newFlags |= controlKey
    }

    if ((flags & NSEvent.ModifierFlags.command.rawValue) > 0) {
      newFlags |= cmdKey
    }

    if ((flags & NSEvent.ModifierFlags.shift.rawValue) > 0) {
      newFlags |= shiftKey;
    }

    if ((flags & NSEvent.ModifierFlags.option.rawValue) > 0) {
      newFlags |= optionKey
    }

    if ((flags & NSEvent.ModifierFlags.capsLock.rawValue) > 0) {
      newFlags |= alphaLock
    }

    return UInt32(newFlags);
  }

  static func register() {
    var hotKeyRef: EventHotKeyRef?
    let modifierFlags: UInt32 =
      getCarbonFlagsFromCocoaFlags(cocoaFlags: [NSEvent.ModifierFlags.command, NSEvent.ModifierFlags.option])

    let keyCode = kVK_ANSI_T
    var gMyHotKeyID = EventHotKeyID()

    gMyHotKeyID.id = UInt32(keyCode)

    // Not sure what "swat" vs "htk1" do.
    gMyHotKeyID.signature = OSType("swat".fourCharCodeValue)
    // gMyHotKeyID.signature = OSType("htk1".fourCharCodeValue)

    var eventType = EventTypeSpec()
    eventType.eventClass = OSType(kEventClassKeyboard)
    eventType.eventKind = OSType(kEventHotKeyReleased)

    // Install handler.
    InstallEventHandler(GetApplicationEventTarget(), { (nextHanlder, theEvent, userData) -> OSStatus in
      // var hkCom = EventHotKeyID()

      // GetEventParameter(theEvent,
      //                   EventParamName(kEventParamDirectObject),
      //                   EventParamType(typeEventHotKeyID),
      //                   nil,
      //                   MemoryLayout<EventHotKeyID>.size,
      //                   nil,
      //                   &hkCom)

//        if let currentWindow = Window.current?.window {
//            if currentWindow.isVisible, currentWindow.occlusionState.contains(.visible) {
//                NSApplication.shared.activate(ignoringOtherApps: true)
//                currentWindow.makeKey()
//            } else {
//                currentWindow.close()
//            }
//        } else {
//            Agent.shared.reopen()
//        }
        NSLog("Command + R Released!")
        

      return noErr
      /// Check that hkCom in indeed your hotkey ID and handle it.
    }, 1, &eventType, nil, nil)

    // Register hotkey.
    let status = RegisterEventHotKey(UInt32(keyCode),
                                     modifierFlags,
                                     gMyHotKeyID,
                                     GetApplicationEventTarget(),
                                     0,
                                     &hotKeyRef)
    assert(status == noErr)
  }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    private let networkMonitor = ServiceLayer.services.networkMonitor
    private let walletsManager = WalletsManager.shared
    private let walletConnect = WalletConnect.shared
    
    private var didFinishLaunching = false
    private var initialExternalRequest: Agent.ExternalRequest?
    
    override init() {
        super.init()
        HotkeySolution.register()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(self.getUrl(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    
    @objc private func getUrl(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        processInput(url: event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        walletsManager.migrateFromLegacyIfNeeded()
        
        agent.start()
        gasService.start()
        priceService.start()
        networkMonitor.start()
        walletsManager.start()
        
        didFinishLaunching = true
        
        if let externalRequest = initialExternalRequest {
            initialExternalRequest = nil
            agent.showInitialScreen(externalRequest: externalRequest)
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agent.reopen()
        return true
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        processInput(url: userActivity.webpageURL?.absoluteString)
        return true
    }
    
    private func processInput(url: String?) {
        guard let url = url else { return }
        
        for scheme in ["https://tokenary.io/wc?uri=", "tokenary://wc?uri="] {
            if url.hasPrefix(scheme), let link = url.dropFirst(scheme.count).removingPercentEncoding, let session = walletConnect.sessionWithLink(link) {
                processExternalRequest(.wcSession(session))
                return
            }
        }
        
        let safariPrefix = "tokenary://safari?request="
        if url.hasPrefix(safariPrefix), let request = SafariRequest(query: String(url.dropFirst(safariPrefix.count))) {
            processExternalRequest(.safari(request))
        }
    }
    
    private func processExternalRequest(_ externalRequest: Agent.ExternalRequest) {
        if didFinishLaunching {
            agent.showInitialScreen(externalRequest: externalRequest)
        } else {
            initialExternalRequest = externalRequest
        }
    }
}
