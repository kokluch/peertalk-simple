import Peertalk
import UIKit

class ManualViewController: UIViewController {
    // Outlets
    @IBOutlet var label: UILabel!
    @IBOutlet var addButton: UIButton!
    @IBOutlet var imageButton: UIButton!
    @IBOutlet var imageView: UIImageView!
    @IBOutlet var statusLabel: UILabel!

    // Properties
    weak var serverChannel: PTChannel?
    weak var peerChannel: PTChannel?
    let imagePicker = UIImagePickerController()

    // UI Setup
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        addButton.layer.cornerRadius = addButton.frame.height / 2
        imageButton.layer.cornerRadius = imageButton.frame.height / 2
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create a channel and start listening
        let channel = PTChannel(protocol: nil, delegate: self)

        // Create a custom port number that the connection will use. I have declared it in the Helper.swift file
        // Make sure the Mac app uses the same number. Any 4 digit integer will work fine.
        channel.listen(on: in_port_t(PORT_NUMBER), IPv4Address: INADDR_LOOPBACK, callback: { error in
            if error != nil {
                print("ERROR (Listening to post): \(error?.localizedDescription ?? "-1")")
            } else {
                self.serverChannel = channel
            }
        })

        // Setup imagge picker
        imagePicker.delegate = self
        imagePicker.allowsEditing = false
        imagePicker.sourceType = .photoLibrary
    }

    // Add 1 to our counter label and send the data if the device is connected
    @IBAction func addButtonTapped(_: UIButton) {
        if isConnected() {
            // Get the new counter number
            var num = "\(Int(label.text!)! + 1)"
            label.text = num

            let data = Data(bytes: &num, count: MemoryLayout<Int>.size)
            sendData(data: data, type: PTType.number)
        }
    }

    // Present the image picker if the device is connected
    @IBAction func imageButtonTapped(_: UIButton) {
        if isConnected() {
            present(imagePicker, animated: true, completion: nil)
        }
    }

    /** Checks if the device is connected, and presents an alert view if it is not */
    func isConnected() -> Bool {
        if peerChannel == nil {
            let alert = UIAlertController(title: "Disconnected", message: "Please connect to a device first", preferredStyle: UIAlertControllerStyle.alert)
            alert.addAction(UIAlertAction(title: "OK", style: UIAlertActionStyle.default, handler: nil))
            present(alert, animated: true, completion: nil)
        }
        return peerChannel != nil
    }

    /** Closes the USB connectin */
    func closeConnection() {
        serverChannel?.close()
    }

    /** Sends data to the connected device */
    func sendData(data: Data, type: PTType) {
        if peerChannel != nil {
            peerChannel?.sendFrame(type: type.rawValue, tag: PTFrameNoTag, payload: data, callback: { error in
                print(error?.localizedDescription ?? "Sent data")
            })
        }
    }
}

// MARK: - Channel Delegate

extension ManualViewController: PTChannelDelegate {
    func channel(_ channel: PTChannel, shouldAcceptFrame _: UInt32, tag _: UInt32, payloadSize _: UInt32) -> Bool {
        // Check if the channel is our connected channel; otherwise ignore it
        // Optional: Check the frame type and optionally reject it
        if channel != peerChannel {
            return false
        } else {
            return true
        }
    }

    func channel(_: PTChannel, didRecieveFrame type: UInt32, tag _: UInt32, payload: Data?) {
        guard let data = payload else { return }

        // Check frame type
        if type == PTType.number.rawValue {
            let count = data.withUnsafeBytes { $0.load(as: Int.self) }

            // Update the UI
            label.text = "\(count)"

        } else if type == PTType.image.rawValue {
            // Conver the image and update the UI
            let image = UIImage(data: data)
            imageView.image = image
        }
    }

    func channelDidEnd(_: PTChannel, error: Error?) {
        print("ERROR (Connection ended): \(String(describing: error?.localizedDescription))")
        statusLabel.text = "Status: Disconnected"
    }

    func channel(_: PTChannel, didAcceptConnection otherChannel: PTChannel, from address: PTAddress) {
        // Cancel any existing connections
        if peerChannel != nil {
            peerChannel?.cancel()
        }

        // Update the peer channel and information
        peerChannel = otherChannel
        peerChannel?.userInfo = address
        print("SUCCESS (Connected to channel)")
        statusLabel.text = "Status: Connected"
    }
}

// MARK: - Image Picker Delegate

extension ManualViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    // Get the image and send it
    func imagePickerController(_: UIImagePickerController, didFinishPickingMediaWithInfo info: [String: Any]) {
        // Get the picked image
        let image = info[UIImagePickerControllerOriginalImage] as! UIImage

        // Update our UI on the main thread
        imageView.image = image

        // Send the data on the background thread to make sure the UI does not freeze
        DispatchQueue.global(qos: .background).async {
            // Convert the data using the second universal method
            let data = UIImageJPEGRepresentation(image, 1.0)!
            self.sendData(data: data, type: PTType.image)
        }

        // Dismiss the image picker
        dismiss(animated: true, completion: nil)
    }

    // Dismiss the view
    func imagePickerControllerDidCancel(_: UIImagePickerController) {
        dismiss(animated: true, completion: nil)
    }
}
