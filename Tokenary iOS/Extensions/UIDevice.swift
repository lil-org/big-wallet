// Copyright © 2022 Tokenary. All rights reserved.

import UIKit
import AVFoundation

extension UIDevice {
    
    private static var deviceModels: [String: String] = [
        // Simulators
        "i386": "iPhone Simulator",
        "x86_64": "iPhone Simulator",
        "arm64": "iPhone Simulator",
        // iPhones
        "iPhone1,1": "iPhone",
        "iPhone1,2": "iPhone 3G",
        "iPhone2,1": "iPhone 3GS",
        "iPhone3,1": "iPhone 4",
        "iPhone3,2": "iPhone 4 GSM Rev A",
        "iPhone3,3": "iPhone 4 CDMA",
        "iPhone4,1": "iPhone 4S",
        "iPhone5,1": "iPhone 5 (GSM)",
        "iPhone5,2": "iPhone 5 (GSM+CDMA)",
        "iPhone5,3": "iPhone 5C (GSM)",
        "iPhone5,4": "iPhone 5C (Global)",
        "iPhone6,1": "iPhone 5S (GSM)",
        "iPhone6,2": "iPhone 5S (Global)",
        "iPhone7,1": "iPhone 6 Plus",
        "iPhone7,2": "iPhone 6",
        "iPhone8,1": "iPhone 6s",
        "iPhone8,2": "iPhone 6s Plus",
        "iPhone8,4": "iPhone SE (GSM)",
        "iPhone9,1": "iPhone 7",
        "iPhone9,2": "iPhone 7 Plus",
        "iPhone9,3": "iPhone 7",
        "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X Global",
        "iPhone10,4": "iPhone 8",
        "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,6": "iPhone X GSM",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max Global",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE 2nd Gen",
        "iPhone13,1": "iPhone 12 Mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        // iPods
        "iPod1,1": "1st Gen iPod",
        "iPod2,1": "2nd Gen iPod",
        "iPod3,1": "3rd Gen iPod",
        "iPod4,1": "4th Gen iPod",
        "iPod5,1": "5th Gen iPod",
        "iPod7,1": "6th Gen iPod",
        "iPod9,1": "7th Gen iPod",
        // iPads
        "iPad1,1": "iPad",
        "iPad1,2": "iPad 3G",
        "iPad2,1": "2nd Gen iPad",
        "iPad2,2": "2nd Gen iPad GSM",
        "iPad2,3": "2nd Gen iPad CDMA",
        "iPad2,4": "2nd Gen iPad New Revision",
        "iPad3,1": "3rd Gen iPad",
        "iPad3,2": "3rd Gen iPad CDMA",
        "iPad3,3": "3rd Gen iPad GSM",
        "iPad2,5": "iPad mini",
        "iPad2,6": "iPad mini GSM+LTE",
        "iPad2,7": "iPad mini CDMA+LTE",
        "iPad3,4": "4th Gen iPad",
        "iPad3,5": "4th Gen iPad GSM+LTE",
        "iPad3,6": "4th Gen iPad CDMA+LTE",
        "iPad4,1": "iPad Air (WiFi)",
        "iPad4,2": "iPad Air (GSM+CDMA)",
        "iPad4,3": "1st Gen iPad Air (China)",
        "iPad4,4": "iPad mini Retina (WiFi)",
        "iPad4,5": "iPad mini Retina (GSM+CDMA)",
        "iPad4,6": "iPad mini Retina (China)",
        "iPad4,7": "iPad mini 3 (WiFi)",
        "iPad4,8": "iPad mini 3 (GSM+CDMA)",
        "iPad4,9": "iPad Mini 3 (China)",
        "iPad5,1": "iPad mini 4 (WiFi)",
        "iPad5,2": "4th Gen iPad mini (WiFi+Cellular)",
        "iPad5,3": "iPad Air 2 (WiFi)",
        "iPad5,4": "iPad Air 2 (Cellular)",
        "iPad6,3": "iPad Pro (9.7 inch, WiFi)",
        "iPad6,4": "iPad Pro (9.7 inch, WiFi+LTE)",
        "iPad6,7": "iPad Pro (12.9 inch, WiFi)",
        "iPad6,8": "iPad Pro (12.9 inch, WiFi+LTE)",
        "iPad6,11": "iPad (2017)",
        "iPad6,12": "iPad (2017)",
        "iPad7,1": "iPad Pro 2nd Gen (WiFi)",
        "iPad7,2": "iPad Pro 2nd Gen (WiFi+Cellular)",
        "iPad7,3": "iPad Pro 10.5-inch",
        "iPad7,4": "iPad Pro 10.5-inch",
        "iPad7,5": "iPad 6th Gen (WiFi)",
        "iPad7,6": "iPad 6th Gen (WiFi+Cellular)",
        "iPad7,11": "iPad 7th Gen 10.2-inch (WiFi)",
        "iPad7,12": "iPad 7th Gen 10.2-inch (WiFi+Cellular)",
        "iPad8,1": "iPad Pro 11 inch 3rd Gen (WiFi)",
        "iPad8,2": "iPad Pro 11 inch 3rd Gen (1TB, WiFi)",
        "iPad8,3": "iPad Pro 11 inch 3rd Gen (WiFi+Cellular)",
        "iPad8,4": "iPad Pro 11 inch 3rd Gen (1TB, WiFi+Cellular)",
        "iPad8,5": "iPad Pro 12.9 inch 3rd Gen (WiFi)",
        "iPad8,6": "iPad Pro 12.9 inch 3rd Gen (1TB, WiFi)",
        "iPad8,7": "iPad Pro 12.9 inch 3rd Gen (WiFi+Cellular)",
        "iPad8,8": "iPad Pro 12.9 inch 3rd Gen (1TB, WiFi+Cellular)",
        "iPad8,9": "iPad Pro 11 inch 4th Gen (WiFi)",
        "iPad8,10": "iPad Pro 11 inch 4th Gen (WiFi+Cellular)",
        "iPad8,11": "iPad Pro 12.9 inch 4th Gen (WiFi)",
        "iPad8,12": "iPad Pro 12.9 inch 4th Gen (WiFi+Cellular)",
        "iPad11,1": "iPad mini 5th Gen (WiFi)",
        "iPad11,2": "iPad mini 5th Gen",
        "iPad11,3": "iPad Air 3rd Gen (WiFi)",
        "iPad11,4": "iPad Air 3rd Gen",
        "iPad11,6": "iPad 8th Gen (WiFi)",
        "iPad11,7": "iPad 8th Gen (WiFi+Cellular)",
        "iPad13,1": "iPad air 4th Gen (WiFi)",
        "iPad13,2": "iPad air 4th Gen (WiFi+Cellular)",
        // Apple Watches
        "Watch1,1": "Apple Watch 38mm case",
        "Watch1,2": "Apple Watch 42mm case",
        "Watch2,6": "Apple Watch Series 1 38mm case",
        "Watch2,7": "Apple Watch Series 1 42mm case",
        "Watch2,3": "Apple Watch Series 2 38mm case",
        "Watch2,4": "Apple Watch Series 2 42mm case",
        "Watch3,1": "Apple Watch Series 3 38mm case (GPS+Cellular)",
        "Watch3,2": "Apple Watch Series 3 42mm case (GPS+Cellular)",
        "Watch3,3": "Apple Watch Series 3 38mm case (GPS)",
        "Watch3,4": "Apple Watch Series 3 42mm case (GPS)",
        "Watch4,1": "Apple Watch Series 4 40mm case (GPS)",
        "Watch4,2": "Apple Watch Series 4 44mm case (GPS)",
        "Watch4,3": "Apple Watch Series 4 40mm case (GPS+Cellular)",
        "Watch4,4": "Apple Watch Series 4 44mm case (GPS+Cellular)",
        "Watch5,1": "Apple Watch Series 5 40mm case (GPS)",
        "Watch5,2": "Apple Watch Series 5 44mm case (GPS)",
        "Watch5,3": "Apple Watch Series 5 40mm case (GPS+Cellular)",
        "Watch5,4": "Apple Watch Series 5 44mm case (GPS+Cellular)",
        "Watch5,9": "Apple Watch SE 40mm case (GPS)",
        "Watch5,10": "Apple Watch SE 44mm case (GPS)",
        "Watch5,11": "Apple Watch SE 40mm case (GPS+Cellular)",
        "Watch5,12": "Apple Watch SE 44mm case (GPS+Cellular)",
        "Watch6,1": "Apple Watch Series 6 40mm case (GPS)",
        "Watch6,2": "Apple Watch Series 6 44mm case (GPS)",
        "Watch6,3": "Apple Watch Series 6 40mm case (GPS+Cellular)",
        "Watch6,4": "Apple Watch Series 6 44mm case (GPS+Cellular)",
        // Apple TVs
        "AppleTV2,1": "Apple TV 2",
        "AppleTV3,1": "Apple TV 3",
        "AppleTV3,2": "Apple TV 3",
        "AppleTV5,3": "Apple TV 4",
        "AppleTV6,2": "Apple TV 4K"
    ]
    
    private static var iPhoneXHeights: [CGFloat] = [
        2436, // iPhoneX
        1792, // iPhoneXR
        2688, // iPhoneXMax
        2340, // iPhone12Mini
        2532, // iPhone12Pro
        2778  // iPhone12ProMax
    ]
    
    static var avCaptureVideoOrientation: AVCaptureVideoOrientation {
        switch current.orientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
    
    static let isBoundlessIphone: Bool = {
        let screenSize = UIScreen.main.bounds.size
        return current.userInterfaceIdiom == .phone && (
                max(screenSize.width, screenSize.height) == 812.0 ||
                max(screenSize.width, screenSize.height) == 896.0
            )
    }()
    
    static var isPhoneX: Bool { isPhone && iPhoneXHeights.contains(UIScreen.main.nativeBounds.size.height) }
    
    static let modelName: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard
                let value = element.value as? Int8,
                value != 0
            else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        let model = deviceModels[identifier]
        return model ?? identifier
    }()
    
    static let isPad: Bool = { current.userInterfaceIdiom == .pad }()
    static let isPhone: Bool = { current.userInterfaceIdiom == .phone }()
    static let isSimulator: Bool = {
        #if targetEnvironment(simulator) || (arch(i386) || arch(x86_64)) && (os(iOS) || os(watchOS) || os(tvOS))
        return true
        #else
        return false
        #endif
    }()
        
    static let hasTopNotch: Bool = {
        if #available(iOS 11.0, *) {
            // safeAreaInsets.top on device
            //  - with notch: 44.0 (iPhone X, XS, XR, etc.)
            //  - without notch: 24.0 (iPad Pro 12.9" 3rd generation), 20.0 (iPhone 6/7/8/etc)
            let top = UIApplication.activeWindow.safeAreaInsets.top
            return top > 24
        }
        return false
    }()
    
    static func systemVersionLessThan(version: String) -> Bool {
        UIDevice.current.systemVersion.compare(version, options: .numeric) == ComparisonResult.orderedAscending
    }
    
    enum DeviceType {
        case iPhoneOld
        case iPhoneNew
        case iPadSmall
        case iPadLarge
    }
    
    static var deviceType: DeviceType { return .iPhoneNew }
    
    static var statusBarSize: CGFloat {
        switch deviceType {
        case .iPhoneOld: return 22
        case .iPhoneNew: return 44
        case .iPadSmall, .iPadLarge: return 24
        }
    }
    
    static var tabBarSize: CGFloat {
        switch deviceType {
        case .iPhoneOld: return 49
        case .iPhoneNew: return 83
        case .iPadSmall: return 50
        case .iPadLarge: return 70
        }
    }
    
    static var snapshotTolerance: CGFloat {
        switch deviceType {
        case .iPhoneOld: return 0.002
        case .iPhoneNew: return 0.005
        case .iPadSmall: return 0.007
        case .iPadLarge: return 0.010
        }
    }
}
