// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

protocol LifecycleObserver: AnyObject {
    func viewDidLoad()
    func viewDidLayoutSubviews()
    func viewWillAppear()
    func viewDidAppear()
    func viewWillDisappear()
    func viewDidDisappear()
}

extension LifecycleObserver {
    func viewDidLoad() {}
    func viewDidLayoutSubviews() {}
    func viewWillAppear() {}
    func viewDidAppear() {}
    func viewWillDisappear() {}
    func viewDidDisappear() {}
}
