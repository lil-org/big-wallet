// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class ImportViewController: UIViewController {
    
    var completion: ((Bool) -> Void)?
    private let walletsManager = WalletsManager.shared
    
    @IBOutlet weak var placeholderLabel: UILabel! {
        didSet {
            placeholderLabel.text = Strings.importAccountTextFieldPlaceholder
        }
    }
    @IBOutlet weak var pasteButton: UIButton!
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var textView: UITextView! {
        didSet {
            textView.delegate = self
            textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
            textView.layer.cornerRadius = 5
            textView.layer.borderWidth = CGFloat.pixel
            textView.layer.borderColor = UIColor.separator.cgColor
        }
    }
    
    private var isWaiting = false
    private var inputValidationResult = WalletsManager.InputValidationResult.invalid
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.title = Strings.importAccount
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissAnimated))
        
        okButton.configurationUpdateHandler = { [weak self] button in
            let isWaiting = self?.isWaiting == true
            button.configuration?.title = isWaiting ? "" : Strings.ok
            button.configuration?.showsActivityIndicator = isWaiting
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
            self?.textView.becomeFirstResponder()
        }
    }
    
    @IBAction func pasteButtonTapped(_ sender: Any) {
        if let text = UIPasteboard.general.string {
            textView.text = text
            validateInput(proceedIfValid: false)
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        attemptImportWithCurrentInput()
    }
    
    private func attemptImportWithCurrentInput() {
        if inputValidationResult == .requiresPassword {
            askPassword()
        } else {
            importWith(input: textView.text, password: nil)
        }
    }
    
    private func askPassword() {
        showPasswordAlert(title: Strings.enterKeystorePassword, message: nil) { [weak self] password in
            guard let password = password else { return }
            self?.setWaiting(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                self?.importWith(input: self?.textView.text ?? "", password: password)
            }
        }
    }
    
    private func importWith(input: String, password: String?) {
        do {
            _ = try walletsManager.addWallet(input: input, inputPassword: password)
            completion?(true)
            dismissAnimated()
        } catch {
            setWaiting(false)
            showMessageAlert(text: Strings.failedToImportAccount)
        }
    }
    
    private func setWaiting(_ waiting: Bool) {
        guard waiting != self.isWaiting else { return }
        self.isWaiting = waiting
        view.isUserInteractionEnabled = !waiting
        isModalInPresentation = waiting
        navigationItem.leftBarButtonItem?.isEnabled = !waiting
        okButton.setNeedsUpdateConfiguration()
    }
    
    private func validateInput(proceedIfValid: Bool) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        inputValidationResult = walletsManager.validateWalletInput(textView.text)
        let isValid = inputValidationResult != .invalid
        okButton.isEnabled = isValid
        if isValid && proceedIfValid {
            attemptImportWithCurrentInput()
        }
    }
    
}

extension ImportViewController: UITextViewDelegate {
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            validateInput(proceedIfValid: true)
            return false
        } else {
            return true
        }
    }
    
    func textViewDidChange(_ textView: UITextView) {
        validateInput(proceedIfValid: false)
    }
    
}
