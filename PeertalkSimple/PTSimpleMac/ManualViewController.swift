import Cocoa
import Peertalk
import Quartz

// MARK: - Main Class

class ManualViewController: NSViewController {
    // MARK: Outlets

    @IBOutlet var label: NSTextField!
    @IBOutlet var imageView: NSImageView!
    @IBOutlet var statusLabel: NSTextField!
    var panel = NSOpenPanel()

    // MARK: Constants

    /** The interval for rechecking whether or not an iOS device is connected */
    let PTAppReconnectDelay: TimeInterval = 1.0

    // MARK: Properties

    var connectingToDeviceID: NSNumber!
    var connectedDeviceID: NSNumber!
    var connectedDeviceProperties: NSDictionary?

    var notConnectedQueue = DispatchQueue(label: "PTExample.notConnectedQueue")
    var notConnectedQueueSuspended: Bool = false

    var connectedChannel: PTChannel? {
        didSet {
            // Toggle the notConnectedQueue depending on if we are connected or not
            if connectedChannel == nil, notConnectedQueueSuspended {
                notConnectedQueue.resume()
                notConnectedQueueSuspended = false
            } else if connectedChannel != nil, !notConnectedQueueSuspended {
                notConnectedQueue.suspend()
                notConnectedQueueSuspended = true
            }

            // Reconnect to the device if we were originally connecting to one
            if connectedChannel == nil, connectingToDeviceID != nil {
                self.enqueueConnectToUSBDevice()
            }
        }
    }

    // MARK: Methods

    override func viewDidLoad() {
        super.viewDidLoad()

        // Start the peertalk service
        startListeningForDevices()
        enqueueConnectToLocalIPv4Port()

        // Setup file chooser
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = NSImage.imageTypes
    }

    // Add 1 to our counter label and send the data if the device is connected
    @IBAction func addButtonPressed(_: NSButton) {
        if isConnected() {
            var num = Int(label.stringValue)! + 1
            label.stringValue = "\(num)"

            let data = Data(bytes: &num, count: MemoryLayout<Int>.size)
            sendData(data: data, type: PTType.number)
        }
    }

    // Present the image picker if the device is connected
    @IBAction func imageButtonPressed(_: NSButton) {
        if isConnected() {
            // Show the file chooser panel
            let opened = panel.runModal()

            // If the user selected an image, update the UI and send the image
            if opened.rawValue == NSFileHandlingPanelOKButton {
                let url = panel.url!
                let image = NSImage(byReferencing: url)
                imageView.image = image

                let data = try! Data(contentsOf: url)
                sendData(data: data, type: PTType.image)
            }
        }
    }

    /** Whether or not the device is connected */
    func isConnected() -> Bool {
        return connectedChannel != nil
    }

    /** Sends data to the connected device */
    func sendData(data: Data, type: PTType) {
        connectedChannel?.sendFrame(type: type.rawValue, tag: PTFrameNoTag, payload: data, callback: { error in
            print(error ?? "Sent")
        })
    }
}

// MARK: - PTChannel Delegate

extension ManualViewController: PTChannelDelegate {
    // Decide whether or not to accept the frame
    func channel(_: PTChannel, shouldAcceptFrame _: UInt32, tag _: UInt32, payloadSize _: UInt32) -> Bool {
        // Optional: Check the frame type and reject specific ones it
        return true
    }

    // Receive the frame data
    func channel(_: PTChannel, didRecieveFrame type: UInt32, tag _: UInt32, payload: Data?) {
        guard let data = payload else { return }
        // Check frame type and get the corresponding data
        if type == PTType.number.rawValue {
            let count = data.withUnsafeBytes { $0.load(as: Int.self) }
            label.stringValue = "\(count)"
        } else if type == PTType.image.rawValue {
            let image = NSImage(data: data)
            imageView.image = image
        }
    }

    // Connection was ended
    func channelDidEnd(_ channel: PTChannel, error _: Error?) {
        // Check that the disconnected device is the current device
        if connectedDeviceID != nil, connectedDeviceID.isEqual(to: channel.userInfo) {
            didDisconnect(fromDevice: connectedDeviceID)
        }

        // Check that the disconnected channel is the current one
        if connectedChannel == channel {
            print("Disconnected from \(channel.userInfo)")
            connectedChannel = nil
        }
    }
}

// MARK: - Helper methods

extension ManualViewController {
    func startListeningForDevices() {
        // Grab the notification center instance
        let nc = NotificationCenter.default

        // Add an observer for when the device attaches
        nc.addObserver(forName: .deviceDidAttach, object: PTUSBHub.shared(), queue: nil) { note in

            // Grab the device ID from the user info
            let deviceID = note.userInfo!["DeviceID"] as! NSNumber
            print("Attached to device: \(deviceID)")

            // Update our properties on our thread
            self.notConnectedQueue.async { () -> Void in
                if self.connectingToDeviceID == nil || !deviceID.isEqual(to: self.connectingToDeviceID) {
                    self.disconnectFromCurrentChannel()
                    self.connectingToDeviceID = deviceID
                    self.connectedDeviceProperties = (note.userInfo?["Properties"] as? NSDictionary)
                    self.enqueueConnectToUSBDevice()
                }
            }
        }

        // Add an observer for when the device detaches
        nc.addObserver(forName: .deviceDidDetach, object: PTUSBHub.shared(), queue: nil) { note in

            // Grab the device ID from the user info
            let deviceID = note.userInfo!["DeviceID"] as! NSNumber
            print("Detached from device: \(deviceID)")

            // Update our properties on our thread
            if self.connectingToDeviceID.isEqual(to: deviceID) {
                self.connectedDeviceProperties = nil
                self.connectingToDeviceID = nil
                if self.connectedChannel != nil {
                    self.connectedChannel?.close()
                }
            }
        }
    }

    // Runs when the device disconnects
    func didDisconnect(fromDevice deviceID: NSNumber) {
        print("Disconnected from device")
        statusLabel.stringValue = "Status: Disconnected"

        // Notify the class that the device has changed
        if connectedDeviceID.isEqual(to: deviceID) {
            willChangeValue(forKey: "connectedDeviceID")
            connectedDeviceID = nil
            didChangeValue(forKey: "connectedDeviceID")
        }
    }

    /** Disconnects from the connected channel */
    func disconnectFromCurrentChannel() {
        if connectedDeviceID != nil, connectedChannel != nil {
            connectedChannel?.close()
            connectedChannel = nil
        }
    }

    @objc func enqueueConnectToLocalIPv4Port() {
        notConnectedQueue.async { () -> Void in
            DispatchQueue.main.async { () -> Void in
                self.connectToLocalIPv4Port()
            }
        }
    }

    func connectToLocalIPv4Port() {
        let channel = PTChannel(protocol: nil, delegate: self)
        channel.userInfo = "127.0.0.1:\(PORT_NUMBER)"

        channel.connect(to: in_port_t(PORT_NUMBER), IPv4Address: INADDR_LOOPBACK, callback: { error, address in
            if error == nil {
                // Update to new channel
                self.disconnectFromCurrentChannel()
                self.connectedChannel = channel
                channel.userInfo = address!
            } else {
                print(error!)
            }

            self.perform(#selector(self.enqueueConnectToLocalIPv4Port), with: nil, afterDelay: self.PTAppReconnectDelay)
        })
    }

    @objc func enqueueConnectToUSBDevice() {
        notConnectedQueue.async { () -> Void in
            DispatchQueue.main.async { () -> Void in
                self.connectToUSBDevice()
            }
        }
    }

    func connectToUSBDevice() {
        // Create the new channel
        let channel = PTChannel(protocol: nil, delegate: self)
        channel.userInfo = connectingToDeviceID
        channel.delegate = self

        // Connect to the device
        channel.connect(to: Int32(PORT_NUMBER), over: PTUSBHub.shared(), deviceID: connectingToDeviceID, callback: { error in
            if error != nil {
                print(error!)
                // Reconnet to the device
                if (channel.userInfo as! NSNumber).isEqual(to: self.connectingToDeviceID) {
                    self.perform(#selector(self.enqueueConnectToUSBDevice), with: nil, afterDelay: self.PTAppReconnectDelay)
                }
            } else {
                // Update connected device properties
                self.connectedDeviceID = self.connectingToDeviceID
                self.connectedChannel = channel
                self.statusLabel.stringValue = "Status: Connected"
                // Check the device properties
                print(self.connectedDeviceProperties!)
            }
        })
    }
}
