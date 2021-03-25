import Foundation
import Peertalk

// MARK: - Delegate

public protocol PTManagerDelegate: class {
    /** Return whether or not you want to accept the specified data type */
    func peertalk(shouldAcceptDataOfType type: UInt32) -> Bool

    /** Runs when the device has received data */
    func peertalk(didReceiveData data: Data?, ofType type: UInt32)

    /** Runs when the connection has changed */
    func peertalk(didChangeConnection connected: Bool)
}

public protocol PTManagerProtocol {
    var delegate: PTManagerDelegate? { get set }
    var isConnected: Bool { get }
    func connect(portNumber: Int)
    func disconnect()
    func send(data: Data, type: UInt32, completion: ((Bool) -> Void)?)
}

#if os(iOS)

// MARK: - iOS

public class PTManager: NSObject, PTManagerProtocol {
    public static let shared = PTManager()

    // MARK: Properties

    weak public var delegate: PTManagerDelegate?
    var portNumber: Int?
    weak var serverChannel: PTChannel?
    weak var peerChannel: PTChannel?

    /** Prints out all errors and status updates */
    var debugMode = false

    // MARK: Methods

    /** Prints only if in debug mode */
    fileprivate func printDebug(_ string: String) {
        if debugMode {
            print(string)
        }
    }

    /** Begins to look for a device and connects when it finds one */
    public func connect(portNumber: Int) {
        if !isConnected {
            self.portNumber = portNumber
            let channel = PTChannel(protocol: nil, delegate: self)
            channel.listen(on: in_port_t(portNumber), IPv4Address: INADDR_LOOPBACK, callback: { error in
                if error == nil {
                    self.serverChannel = channel
                }
            })
        }
    }

    /** Whether or not the device is connected */
    public var isConnected: Bool {
        return peerChannel != nil
    }

    /** Closes the USB connection */
    public func disconnect() {
        serverChannel?.close()
        peerChannel?.close()
        peerChannel = nil
        serverChannel = nil
    }

    /** Sends data to the connected device */
    public func send(data: Data, type: UInt32, completion: ((_ success: Bool) -> Void)? = nil) {
        if let channel = peerChannel {
            channel.sendFrame(type: type, tag: PTFrameNoTag, payload: data) { _ in
                completion?(true)
            }
        } else {
            completion?(false)
        }
    }
}

// MARK: - Channel Delegate

extension PTManager: PTChannelDelegate {
    public func channel(_ channel: PTChannel, shouldAcceptFrame type: UInt32, tag _: UInt32, payloadSize _: UInt32) -> Bool {
        // Check if the channel is our connected channel; otherwise ignore it
        if channel != peerChannel {
            return false
        } else {
            return delegate?.peertalk(shouldAcceptDataOfType: type) ?? true
        }
    }

    public func channel(_: PTChannel, didRecieveFrame type: UInt32, tag _: UInt32, payload: Data?) {
        delegate?.peertalk(didReceiveData: payload, ofType: type)
    }

    public func channel(_: PTChannel, didEndWithError error: Error?) {
        printDebug("ERROR (Connection ended): \(String(describing: error?.localizedDescription))")
        peerChannel = nil
        serverChannel = nil
        delegate?.peertalk(didChangeConnection: false)
    }

    public func channel(_: PTChannel, didAcceptConnection otherChannel: PTChannel, from address: PTAddress) {
        // Cancel any existing connections
        peerChannel?.cancel()

        // Update the peer channel and information
        peerChannel = otherChannel
        peerChannel?.userInfo = address
        printDebug("SUCCESS (Connected to channel)")
        delegate?.peertalk(didChangeConnection: true)
    }
}

#elseif os(OSX)

// MARK: - OS X

public class PTManager: NSObject, PTManagerProtocol {
    public static var shared = PTManager()

    // MARK: Properties

    weak public var delegate: PTManagerDelegate?
    fileprivate var portNumber: Int?
    var connectingToDeviceID: NSNumber?
    var connectedDeviceID: NSNumber?
    var connectedDeviceProperties: NSDictionary?

    fileprivate var notConnectedQueue = DispatchQueue(label: "PTExample.notConnectedQueue")
    fileprivate var notConnectedQueueSuspended: Bool = false

    /** Prints out all errors and status updates */
    var debugMode = false

    /** The interval for rechecking whether or not an iOS device is connected */
    let reconnectDelay: TimeInterval = 1.0

    fileprivate var connectedChannel: PTChannel? {
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
                enqueueConnectToUSBDevice()
            }
        }
    }

    // MARK: Methods

    /** Prints only if in debug mode */
    fileprivate func printDebug(_ string: String) {
        if debugMode {
            print(string)
        }
    }

    /** Begins to look for a device and connects when it finds one */
    public func connect(portNumber: Int) {
        self.portNumber = portNumber
        startListeningForDevices()
        enqueueConnectToLocalIPv4Port()
    }

    /** Whether or not the device is connected */
    public var isConnected: Bool {
        return connectedChannel != nil
    }

    /** Closes the USB connection */
    public func disconnect() {
        connectedChannel?.close()
        connectedChannel = nil
    }

    /** Sends data to the connected device */
    public func send(data: Data, type: UInt32, completion: ((_ success: Bool) -> Void)? = nil) {
        if let channel = connectedChannel {
            channel.sendFrame(type: type, tag: PTFrameNoTag, payload: data) { _ in
                completion?(true)
            }
        } else {
            completion?(false)
        }
    }
}

// MARK: - Channel Delegate

extension PTManager: PTChannelDelegate {
    // Decide whether or not to accept the frame
    public func channel(_: PTChannel, shouldAcceptFrame type: UInt32, tag _: UInt32, payloadSize _: UInt32) -> Bool {
        return delegate?.peertalk(shouldAcceptDataOfType: type) ?? false
    }

    // Receive the frame data
    public func channel(_: PTChannel, didRecieveFrame type: UInt32, tag _: UInt32, payload: Data?) {
        delegate?.peertalk(didReceiveData: payload, ofType: type)
    }

    // Connection was ended
    public func channelDidEnd(_ channel: PTChannel, error _: Error?) {
        // Check that the disconnected device is the current device
        if let deviceID = connectedDeviceID, deviceID.isEqual(to: channel.userInfo) {
            didDisconnect(fromDevice: deviceID)
        }

        // Check that the disconnected channel is the current one
        if connectedChannel == channel {
            printDebug("Disconnected from \(channel.userInfo)")
            connectedChannel = nil
        }
    }
}

// MARK: - Helper methods

fileprivate extension PTManager {
    func startListeningForDevices() {
        // Grab the notification center instance
        let nc = NotificationCenter.default

        // Add an observer for when the device attaches
        nc.addObserver(forName: .deviceDidAttach, object: PTUSBHub.shared(), queue: nil) { note in

            // Grab the device ID from the user info
            let deviceID = note.userInfo!["DeviceID"] as! NSNumber
            self.printDebug("Attached to device: \(deviceID)")

            // Update our properties on our thread
            self.notConnectedQueue.async { () -> Void in
                if self.connectingToDeviceID == nil || !deviceID.isEqual(to: self.connectingToDeviceID) {
                    self.disconnect()
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
            self.printDebug("Detached from device: \(deviceID)")

            // Update our properties on our thread
            if let connectingToDeviceID = self.connectingToDeviceID, connectingToDeviceID.isEqual(to: deviceID) {
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
        printDebug("Disconnected from device")
        delegate?.peertalk(didChangeConnection: false)

        // Notify the class that the device has changed
        if let connectedDeviceID = self.connectedDeviceID, connectedDeviceID.isEqual(to: deviceID) {
            willChangeValue(forKey: "connectedDeviceID")
            self.connectedDeviceID = nil
            didChangeValue(forKey: "connectedDeviceID")
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
        guard let portNumber = self.portNumber else { return }
        let channel = PTChannel(protocol: nil, delegate: self)
        channel.userInfo = "127.0.0.1:\(portNumber)"

        channel.connect(to: in_port_t(portNumber), IPv4Address: INADDR_LOOPBACK, callback: { error, address in
            if let error = error {
                self.printDebug(error.localizedDescription)
            } else {
                // Update to new channel
                self.disconnect()
                self.connectedChannel = channel
                channel.userInfo = address!
            }

            self.perform(#selector(self.enqueueConnectToLocalIPv4Port), with: nil, afterDelay: self.reconnectDelay)
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
        guard let portNumber = self.portNumber,
              let connectingToDeviceID = self.connectingToDeviceID else { return }

        // Create the new channel
        let channel = PTChannel(protocol: nil, delegate: self)
        channel.userInfo = connectingToDeviceID
        channel.delegate = self

        // Connect to the device
        channel.connect(to: Int32(portNumber), over: PTUSBHub.shared(), deviceID: connectingToDeviceID, callback: { error in
            if let error = error {
                self.printDebug(error.localizedDescription)
                // Reconnet to the device
                if let deviceID = channel.userInfo as? NSNumber, deviceID.isEqual(to: self.connectingToDeviceID) {
                    self.perform(#selector(self.enqueueConnectToUSBDevice), with: nil, afterDelay: self.reconnectDelay)
                }
            } else {
                // Update connected device properties
                self.connectedDeviceID = self.connectingToDeviceID
                self.connectedChannel = channel
                self.delegate?.peertalk(didChangeConnection: true)
                // Check the device properties
                self.printDebug("\(self.connectedDeviceProperties!)")
            }
        })
    }
}

#endif
