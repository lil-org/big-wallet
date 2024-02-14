// ∅ 2024 lil org

import UIKit
import MobileCoreServices
import UniformTypeIdentifiers

class ActionViewController: UIViewController {
    
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var imageView: UIImageView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        for item in self.extensionContext!.inputItems as! [NSExtensionItem] {
            for provider in item.attachments! {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil, completionHandler: { [weak self] (imageURL, error) in
                        DispatchQueue.main.async {
                            if let imageURL = imageURL as? URL {
                                self?.imageView.image = UIImage(data: try! Data(contentsOf: imageURL))
                                self?.statusLabel.text = imageURL.mimeType
                            }
                        }
                    })
                    return
                }
            }
        }
    }
    
    // TODO: cleanup
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
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  error == nil,
                  let ipfsResponse = try? JSONDecoder().decode(IPFSResponse.self, from: data),
                  let url = URL(string: "https://zora.co/create?image=ipfs://\(ipfsResponse.hash)") else { return }
            
            DispatchQueue.main.async {
                // TODO: redirect
                self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
        task.resume()
    }
    
    // TODO: cleanup
    @IBAction func done() {
        guard let customURL = URL(string: "https://google.com") else { return }
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(customURL)
                break
            }
            responder = responder?.next
        }
        extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }
    
}
