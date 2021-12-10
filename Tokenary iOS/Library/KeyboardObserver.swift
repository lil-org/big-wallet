// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

protocol KeyboardObserver: UIResponder {
    func keyboardWill(show: Bool, height: CGFloat, animtaionOptions: UIView.AnimationOptions, duration: Double)
}

extension KeyboardObserver {
    
    func observeKeyboard() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    
    fileprivate func didReceiveKeyboardNotification(_ notification: Notification, willShow: Bool) {
        let height = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as AnyObject).cgRectValue.size.height
        let animtaionOptions: UIView.AnimationOptions
        let duration: Double
        
        if let animationCurve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
            animtaionOptions = UIView.AnimationOptions(rawValue: UInt(animationCurve.intValue << 16))
        } else {
            animtaionOptions = UIView.AnimationOptions()
        }
        
        if let animationDuration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber {
            duration = animationDuration.doubleValue
        } else {
            duration = 0
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.keyboardWill(show: willShow, height: height, animtaionOptions: animtaionOptions, duration: duration)
        }
    }
    
}

fileprivate extension UIResponder {
    
    @objc func keyboardWillShow(notification: Notification) {
        (self as? KeyboardObserver)?.didReceiveKeyboardNotification(notification, willShow: true)
    }
    
    @objc func keyboardWillHide(notification: Notification) {
        (self as? KeyboardObserver)?.didReceiveKeyboardNotification(notification, willShow: false)
    }
    
}
