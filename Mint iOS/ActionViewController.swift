// ∅ 2024 lil org

import UIKit
import MobileCoreServices
import UniformTypeIdentifiers

class ActionViewController: UIViewController {

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
                            }
                        }
                    })
                    return
                }
            }
        }
    }

    @IBAction func done() {
        extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }

}
