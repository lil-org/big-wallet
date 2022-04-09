// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

class LifecycleObservableViewController: UIViewController {
    private var observer: LifecycleObserver?
    
    var output: LifecycleObserver? {
        get {
            return observer ?? findValue(for: "presenter", in: Mirror(reflecting: self)) as? LifecycleObserver
        }
        set {
            self.observer = newValue
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.output?.viewDidLoad()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.output?.viewDidLayoutSubviews()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.output?.viewWillAppear()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.output?.viewDidAppear()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.output?.viewWillDisappear()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.output?.viewDidDisappear()
    }
    
    // MARK: - Private methods
    
    private func findValue(for propertyName: String, in mirror: Mirror) -> Any? {
        for property in mirror.children where property.label! == propertyName {
            return property.value
        }

        if let superclassMirror = mirror.superclassMirror {
            return findValue(for: propertyName, in: superclassMirror)
        }

        return nil
    }
}
