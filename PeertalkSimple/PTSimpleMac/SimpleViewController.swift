import Cocoa
import PeertalkManager

class SimpleViewController: NSViewController {
    // MARK: - Outlets

    @IBOutlet var label: NSTextField!
    @IBOutlet var imageView: NSImageView!
    @IBOutlet var statusLabel: NSTextField!

    // MARK: - Properties

    let ptManager = PTManager.shared
    var panel = NSOpenPanel()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Setup the PTManager
        ptManager.delegate = self
        ptManager.connect(portNumber: PORT_NUMBER)

        // Setup file chooser
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = NSImage.imageTypes
    }

    @IBAction func addButtonTapped(_: Any) {
        if ptManager.isConnected {
            var num = Int(label.stringValue)! + 1
            label.stringValue = "\(num)"
            let data = Data(bytes: &num, count: MemoryLayout<Int>.size)
            ptManager.send(data: data, type: PTType.number.rawValue)
        }
    }

    @IBAction func imageButtonTapped(_: Any) {
        if ptManager.isConnected {
            // Show the file chooser panel
            let opened = panel.runModal()

            // If the user selected an image, update the UI and send the image
            if opened.rawValue == NSFileHandlingPanelOKButton {
                let url = panel.url!
                let image = NSImage(byReferencing: url)
                imageView.image = image
                let data = try! Data(contentsOf: url)
                ptManager.send(data: data, type: PTType.image.rawValue)
            }
        }
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
            label.stringValue = "\(count)"
        } else if type == PTType.image.rawValue {
            let image = NSImage(data: data)
            imageView.image = image
        }
    }

    func peertalk(didChangeConnection connected: Bool) {
        print("Connection: \(connected)")
        statusLabel.stringValue = connected ? "Connected" : "Disconnected"
    }
}
