import Foundation
import ConnectIQ

/// Bridge between the iOS app and the Garmin Fenix 8 watch via the Connect IQ Companion SDK.
///
/// The Connect IQ iOS SDK works as follows:
/// 1. Initialize with a URL scheme (e.g., "fenixnavi://")
/// 2. Call `showConnectIQDeviceSelection()` — this opens Garmin Connect Mobile
/// 3. User selects which devices to share in GCM
/// 4. GCM returns to our app via the URL scheme
/// 5. We parse the URL with `parseDeviceSelectionResponseFromURL:` to get devices
/// 6. Create an `IQApp` for our watch app and send messages
///
/// Setup:
/// 1. Add ConnectIQ.xcframework to the Xcode project ✅
/// 2. Register URL scheme "fenixnavi" in Info.plist
/// 3. Handle URL in app's onOpenURL to call parseDeviceSelectionResponseFromURL
class GarminBridge: NSObject {

    // MARK: - Configuration

    // App UUID matching the watch app's manifest.xml
    static let watchAppUUID = "21e5ae0f-a40e-4145-b95b-9d9b3ff77711"

    // URL scheme for GCM to return to our app
    static let urlScheme = "fenixnavi"

    // MARK: - State

    private var currentDevice: IQDevice?
    private var currentApp: IQApp?
    private(set) var isConnected = false
    private var connectionCallback: ((Bool) -> Void)?
    private var pendingMessages: [[String: Any]] = []
    private var pendingOpenApp = false
    private var pendingOpenAppCompletion: ((Bool) -> Void)?
    private var lastStatus: IQDeviceStatus = .invalidDevice

    // MARK: - Public API

    /// Initialize the Connect IQ SDK. Call once at app startup.
    func initialize() {
        ConnectIQ.sharedInstance().initialize(
            withUrlScheme: Self.urlScheme,
            uiOverrideDelegate: nil  // Use default SDK UI
        )
        print("FenixNavi: ConnectIQ initialized with scheme '\(Self.urlScheme)://'")
    }

    /// Open Garmin Connect Mobile to let the user select which devices to share.
    /// After the user selects devices, GCM will return to our app via the URL scheme.
    func showDeviceSelection() {
        ConnectIQ.sharedInstance().showDeviceSelection()
    }

    /// Call this from your app delegate when receiving a URL from Garmin Connect Mobile.
    /// - Parameter url: The URL that GCM opened to return to our app.
    /// - Returns: Array of IQDevice objects the user selected.
    func handleOpenURL(_ url: URL) -> [IQDevice] {
        let devices = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url)
        if let devices = devices as? [IQDevice], let device = devices.first {
            currentDevice = device
            setupDevice(device)

            // Register for device status events
            ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)

            // The user selected this device in GCM, so we consider it connected
            isConnected = true
            connectionCallback?(true)
        }
        return (devices as? [IQDevice]) ?? []
    }

    /// Send a navigation message to the watch.
    /// - Parameter message: Dictionary with navigation data (sent as NSDictionary).
    func sendMessage(_ message: [String: Any]) {
        guard let app = currentApp else {
            // No app configured yet - buffer the message so it isn't lost.
            // It will be flushed once the device is configured.
            pendingMessages.append(message)
            print("FenixNavi: Buffered message (\(pendingMessages.count) pending)")
            return
        }

        print("FenixNavi: Sending message: \(message["type"] ?? "?")")
        ConnectIQ.sharedInstance().sendMessage(
            message as NSDictionary,
            to: app,
            progress: nil
        ) { result in
            if result != IQSendMessageResult.success {
                print("FenixNavi: Send failed: \(result.rawValue)")
            }
        }
    }

    /// Open the FenixNavi app on the watch once the device is connected.
    /// If the device isn't connected yet (BLE still pairing), the request is
    /// deferred until deviceStatusChanged reports Connected.
    /// - Parameter completion: Called with true if the request was sent successfully.
    func openAppWhenReady(completion: @escaping (Bool) -> Void) {
        if lastStatus == .connected {
            openApp(completion: completion)
        } else {
            pendingOpenApp = true
            pendingOpenAppCompletion = completion
        }
    }

    /// Open the FenixNavi app on the watch.
    /// - Parameter completion: Called with true if the request was sent successfully.
    func openApp(completion: @escaping (Bool) -> Void) {
        guard let app = currentApp else {
            print("FenixNavi: No app to open")
            completion(false)
            return
        }

        ConnectIQ.sharedInstance().openAppRequest(app) { result in
            let success = result == IQSendMessageResult.success
            print("FenixNavi: Open app result: \(result.rawValue)")
            completion(success)
        }
    }

    // MARK: - Private

    private func setupDevice(_ device: IQDevice) {
        self.currentDevice = device

        guard let uuid = UUID(uuidString: Self.watchAppUUID) else {
            print("FenixNavi: Invalid app UUID")
            return
        }

        let app = IQApp(
            uuid: uuid,
            store: nil,  // nil during development
            device: device
        )
        self.currentApp = app

        print("FenixNavi: Setup device '\(device.friendlyName)' (UUID: \(device.uuid))")

        // Flush any buffered messages now that the app is configured
        flushPendingMessages()
    }

    /// Send any messages that were buffered before the device was configured.
    private func flushPendingMessages() {
        guard let app = currentApp, !pendingMessages.isEmpty else { return }
        let buffered = pendingMessages
        pendingMessages = []
        print("FenixNavi: Flushing \(buffered.count) buffered messages")
        for message in buffered {
            ConnectIQ.sharedInstance().sendMessage(
                message as NSDictionary,
                to: app,
                progress: nil
            ) { result in
                if result != IQSendMessageResult.success {
                    print("FenixNavi: Flush send failed: \(result.rawValue)")
                }
            }
        }
    }
}

// MARK: - IQDeviceEventDelegate

extension GarminBridge: IQDeviceEventDelegate {

    func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        lastStatus = status
        print("FenixNavi: Device status: \(status.rawValue)")
        switch status {
        case .connected:
            isConnected = true
            // The device is now ready - fire any deferred open-app request.
            if pendingOpenApp {
                pendingOpenApp = false
                let completion = pendingOpenAppCompletion
                pendingOpenAppCompletion = nil
                openApp(completion: completion ?? { _ in })
            }
        case .notConnected, .invalidDevice:
            isConnected = false
        @unknown default:
            break
        }
    }
}
