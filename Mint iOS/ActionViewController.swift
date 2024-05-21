// ∅ 2024 lil org

import UIKit
import MobileCoreServices
import UniformTypeIdentifiers

class ActionViewController: UIViewController {
    
    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var statusLabel: UILabel! {
        didSet {
            statusLabel.text = Strings.uploading
        }
    }
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem?.title = Strings.cancel
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil, completionHandler: { [weak self] (imageURL, error) in
                        DispatchQueue.main.async {
                            if let imageURL = imageURL as? URL, let data = try? Data(contentsOf: imageURL) {
                                self?.imageView.image = UIImage(data: data)
                                self?.uploadImage(data: data, type: imageURL.mimeType)
                            }
                        }
                    })
                    return
                }
            }
        }
    }
    
    private func uploadImage(data: Data, type: String) {
        let boundary = "----WebKitFormBoundaryn3JBuHDuzWcHa9BR"
        var request = URLRequest(url: URL(string: "https://ipfs-uploader.zora.co/api/v0/add?stream-channels=true&cid-version=1&progress=false")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"fresh\"\r\n".utf8))
        body.append(Data("Content-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let task = URLSession.shared.dataTask(with: request) { [weak self] responseData, response, error in
            guard let responseData = responseData,
                  error == nil,
                  let ipfsResponse = try? JSONDecoder().decode(IpfsResponse.self, from: responseData),
                  let url = URL(string: "https://zora.co/create?image=ipfs://\(ipfsResponse.cid)") else {
                DispatchQueue.main.async { self?.suggestRetry(data: data, type: type) }
                return
            }
            DispatchQueue.main.async {
                self?.openURL(url)
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
        task.resume()
    }
    
    private func suggestRetry(data: Data, type: String) {
        statusLabel.isHidden = true
        activityIndicator.stopAnimating()
        let alert = UIAlertController(title: Strings.somethingWentWrong, message: nil, preferredStyle: .alert)
        let cancel = UIAlertAction(title: Strings.cancel, style: .cancel) { [weak self] _ in
            self?.allDone()
        }
        let retry = UIAlertAction(title: Strings.retry, style: .default) { [weak self] _ in
            self?.statusLabel.isHidden = false
            self?.activityIndicator.startAnimating()
            self?.uploadImage(data: data, type: type)
        }
        alert.addAction(cancel)
        alert.addAction(retry)
        present(alert, animated: true)
    }
    
    private func allDone() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    @IBAction func done() {
        allDone()
    }
    
    private func openURL(_ url: URL) {
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url)
                break
            }
            responder = responder?.next
        }
    }
    
}
