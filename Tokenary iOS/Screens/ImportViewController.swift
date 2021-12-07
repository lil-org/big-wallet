// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class ImportViewController: UIViewController {
    
    @IBOutlet weak var pasteButton: UIButton!
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var textView: UITextView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        textView.becomeFirstResponder()
        navigationItem.title = Strings.importAccount
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissAnimated))
        
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    @IBAction func pasteButtonTapped(_ sender: Any) {
        
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        
    }
    
}
