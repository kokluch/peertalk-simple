import PeertalkManager
import UIKit

class SimpleViewController: UIViewController {
    // Outlets
    @IBOutlet var label: UILabel!
    @IBOutlet var addButton: UIButton!
    @IBOutlet var imageButton: UIButton!
    @IBOutlet var imageView: UIImageView!
    @IBOutlet var statusLabel: UILabel!

    // Properties
    let ptManager = PTManager.shared
    let imagePicker = UIImagePickerController()

    // UI Setup
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        addButton.layer.cornerRadius = addButton.frame.height / 2
        imageButton.layer.cornerRadius = imageButton.frame.height / 2
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Setup the PTManager
        ptManager.delegate = self
        ptManager.connect(portNumber: PORT_NUMBER)

        // Setup imagge picker
        imagePicker.delegate = self
        imagePicker.allowsEditing = false
        imagePicker.sourceType = .photoLibrary
    }

    @IBAction func addButtonTapped(_: UIButton) {
        if ptManager.isConnected {
            var num = Int(label.text!)! + 1
            label.text = "\(num)"
            let data = Data(bytes: &num, count: MemoryLayout<Int>.size)
            ptManager.send(data: data, type: PTType.number.rawValue)
        } else {
            showAlert()
        }
    }

    @IBAction func imageButtonTapped(_: UIButton) {
        if ptManager.isConnected {
            present(imagePicker, animated: true, completion: nil)
        } else {
            showAlert()
        }
    }

    func showAlert() {
        let alert = UIAlertController(title: "Disconnected", message: "Please connect to a device first", preferredStyle: UIAlertControllerStyle.alert)
        alert.addAction(UIAlertAction(title: "OK", style: UIAlertActionStyle.default, handler: nil))
        present(alert, animated: true, completion: nil)
    }
}

extension SimpleViewController: PTManagerDelegate {
    func peertalk(shouldAcceptDataOfType _: UInt32) -> Bool {
        return true
    }

    func peertalk(didReceiveData data: Data?, ofType type: UInt32) {
        guard let data = data else { return }
        if type == PTType.number.rawValue {
            let count = data.withUnsafeBytes { $0.load(as: Int.self) }
            label.text = "\(count)"
        } else if type == PTType.image.rawValue {
            let image = UIImage(data: data)
            imageView.image = image
        }
    }

    func peertalk(didChangeConnection connected: Bool) {
        print("Connection: \(connected)")
        statusLabel.text = connected ? "Connected" : "Disconnected"
    }
}

extension SimpleViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_: UIImagePickerController, didFinishPickingMediaWithInfo info: [String: Any]) {
        let image = info[UIImagePickerControllerOriginalImage] as! UIImage
        imageView.image = image

        DispatchQueue.global(qos: .background).async {
            let data = UIImageJPEGRepresentation(image, 1.0)!
            self.ptManager.send(data: data, type: PTType.image.rawValue, completion: nil)
        }

        dismiss(animated: true, completion: nil)
    }

    func imagePickerControllerDidCancel(_: UIImagePickerController) {
        dismiss(animated: true, completion: nil)
    }
}
