import Foundation
import AVFoundation
import MediaPlayer
#if USE_VANILLA
import WhisperVanilla
#endif
#if USE_ORCHID
import WhisperOrchid
#endif

class DeviceManager : NSObject {
    static let SelfInfoChanged = NSNotification.Name("kNotificationSelfInfoChanged")
    static let DeviceListChanged = NSNotification.Name("kNotificationDeviceListChanged")
    static let DeviceStatusChanged = NSNotification.Name("kNotificationDeviceStatusChanged")
    
// MARK: - Singleton
    @objc(sharedInstance)
    static let sharedInstance = DeviceManager()
    
// MARK: - Variables
    var status = WhisperConnectionStatus.Disconnected;
    @objc(whisperInst)
    var whisperInst: Whisper!
    var devices = [Device]()
    
// MARK: - Private variables
    fileprivate var networkManager : NetworkReachabilityManager?

    fileprivate var bulbStatus = false
    fileprivate var brightness = Float(UIScreen.main.brightness)
    fileprivate var captureDevice: AVCaptureDevice?
    fileprivate var audioPlayer : AVAudioPlayer?
    fileprivate var audioVolume : Float = 1.0
    
    fileprivate var captureSession : AVCaptureSession?
    fileprivate var captureConnection : AVCaptureConnection?
    fileprivate var videoPlayLayer : AVSampleBufferDisplayLayer?
    fileprivate var remotePlayingDevices = Set<Device>()
    fileprivate var encoder: VideoEncoder?

    public typealias MessageCompletionHandler = (_ result : [String: Any]?) -> Void
    fileprivate var currentMessage : (device: Device, handler: MessageCompletionHandler, timer: Timer)?

// MARK: - Methods
    
    override init() {
        Whisper.setLogLevel(.Debug)
    }

#if USE_VANILLA
    func start() {
        if whisperInst == nil {
            do {
                let plistPath = Bundle.main.path(forResource: "Config", ofType: "plist")
                let info = NSDictionary(contentsOfFile: plistPath!) as! [String: String]

                if networkManager == nil {
                    let url = URL(string: info["ApiServer"]!)
                    networkManager = NetworkReachabilityManager(host: url!.host!)
                }

                guard networkManager!.isReachable else {
                    print("network is not reachable")
                    networkManager?.listener = { [weak self] newStatus in
                        if newStatus == .reachable(.ethernetOrWiFi) || newStatus == .reachable(.wwan) {
                            self?.start()
                        }
                    }
                    networkManager?.startListening()
                    return
                }

                let whisperDirectory: String = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0] + "/whisper"
                if !FileManager.default.fileExists(atPath: whisperDirectory) {
                    var url = URL(fileURLWithPath: whisperDirectory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                    
                    var resourceValues = URLResourceValues()
                    resourceValues.isExcludedFromBackup = true
                    try url.setResourceValues(resourceValues)
                }
//                else {
//                    let documentDirectory: String = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/whisper"
//                    try? FileManager.default.removeItem(atPath: documentDirectory)
//                    try! FileManager.default.copyItem(atPath: whisperDirectory, toPath: documentDirectory)
//                }

                let userDefaults = UserDefaults.standard
                var deviceId = userDefaults.string(forKey: "deviceId")
                if deviceId == nil {
                    deviceId = UIDevice.current.identifierForVendor!.uuidString
                    userDefaults.set(deviceId, forKey: "deviceId")
                    userDefaults.synchronize()
                }

                let options = WhisperOptions()
                options.setAppId(info["AppId"]!, andKey: info["AppKey"]!)
                options.apiServerUrl = info["ApiServer"]!
                options.mqttServerUri = info["MqttServer"]!
                options.trustStore = Bundle.main.path(forResource: "whisper", ofType: "pem")
                options.persistentLocation = whisperDirectory
                options.deviceId = deviceId
                options.connectTimeout = 5
                
                try whisperInst = Whisper.getInstance(options: options, delegate: self)
                print("Whisper instance created")
                
                networkManager = nil

                try! whisperInst.start(iterateInterval: 1000)
                print("Whisper started, waiting for ready")
                
                NotificationCenter.default.addObserver(forName: .UIApplicationWillResignActive, object: nil, queue: OperationQueue.main, using: didEnterBackground)
                NotificationCenter.default.addObserver(forName: .UIScreenBrightnessDidChange, object: nil, queue: OperationQueue.main, using: brightnessDidChanged)
            }
            catch {
                NSLog("Start whisper instance error : \(error.localizedDescription)")
            }
        }
    }
#endif

#if USE_ORCHID
    func start() {
        if whisperInst == nil {
            do {
                if networkManager == nil {
                    let url = URL(string: "https://apache.org")
                    networkManager = NetworkReachabilityManager(host: url!.host!)
                }

                guard networkManager!.isReachable else {
                    print("network is not reachable")
                    networkManager?.listener = { [weak self] newStatus in
                        if newStatus == .reachable(.ethernetOrWiFi) || newStatus == .reachable(.wwan) {
                            self?.start()
                        }
                    }
                    networkManager?.startListening()
                    return
                }

                let whisperDirectory: String = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0] + "/whisper"
                if !FileManager.default.fileExists(atPath: whisperDirectory) {
                    var url = URL(fileURLWithPath: whisperDirectory)
                    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)

                    var resourceValues = URLResourceValues()
                    resourceValues.isExcludedFromBackup = true
                    try! url.setResourceValues(resourceValues)
                }

                let plistPath = Bundle.main.path(forResource: "Config", ofType: "plist")
                let info = NSDictionary(contentsOfFile: plistPath!) as! [String:Any]
                //let bootstraps = NSArray(object: info["bootstraps"]!)
                let bootstraps = NSMutableArray(array: info["bootstraps"]! as! [Any])

                let options = WhisperOptions()
                options.bootstrapNodes = [BootstrapNode]()

                for bootstrap in bootstraps {
                    let bootstrapNode = BootstrapNode()
                    bootstrapNode.ipv4 = (bootstrap as! [String:String])["ipv4"]
                    bootstrapNode.port = (bootstrap as! [String:String])["port"]
                    bootstrapNode.publicKey = (bootstrap as! [String:String])["public_key"]
                    options.bootstrapNodes?.append(bootstrapNode)
                }

                options.udpEnabled = info["udp_enabled"] as! Bool
                options.persistentLocation = whisperDirectory

                try whisperInst = Whisper.getInstance(options: options, delegate: self)
                print("whisper instance created")

                networkManager = nil

                try! whisperInst.start(iterateInterval: 1000)
                print("Whisper started, waiting for ready")

                NotificationCenter.default.addObserver(forName: .UIApplicationWillResignActive, object: nil, queue: OperationQueue.main, using: didEnterBackground)
                NotificationCenter.default.addObserver(forName: .UIScreenBrightnessDidChange, object: nil, queue: OperationQueue.main, using: brightnessDidChanged)
            }
            catch {
                NSLog("Start whisper instance error : \(error.localizedDescription)")
            }
        }
    }
#endif


    @objc(messageResponseTimeout:)
    func messageResponseTimeout(_ timer: Timer) {
        guard timer == self.currentMessage?.timer else {
            return
        }

        currentMessage?.timer.invalidate()
        currentMessage?.handler(nil)
        currentMessage = nil
    }

    func getDeviceStatus(_ device: Device? = nil, completion: @escaping MessageCompletionHandler) throws {
        currentMessage?.timer.invalidate()
        currentMessage = nil

        if let deviceInfo = device {
            let messageDic = ["type":"query"]
            try sendMessage(messageDic, toDevice: deviceInfo)
            let timer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(messageResponseTimeout(_:)), userInfo: nil, repeats: false)
            currentMessage = (deviceInfo , completion, timer)
        }
        else {
            var selfStstus = [String : Any]()
            selfStstus["type"] = "status"
            selfStstus["bulb"] = bulbStatus
            
            if captureDevice == nil {
                captureDevice = AVCaptureDevice.default(for: AVMediaType.video)
            }
            if captureDevice!.hasTorch && captureDevice!.isTorchAvailable {
                selfStstus["torch"] = captureDevice!.torchMode == .on
            }
            
            selfStstus["brightness"] = brightness
            
            if let player = audioPlayer {
                selfStstus["ring"] = player.isPlaying
                selfStstus["volume"] = player.volume
            }
            else {
                selfStstus["ring"] = false
                selfStstus["volume"] = audioVolume
            }

            selfStstus["camera"] = false
            completion(selfStstus)
        }
    }
    
    
    func setBulbStatus(_ on: Bool, device: Device? = nil) throws {
        if let deviceInfo = device {
            let messageDic = ["type":"modify", "bulb":on] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            bulbStatus = on
            
            let messageDic = ["type":"sync", "bulb":on] as [String : Any]
            NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
            if (self.status == .Connected) {
                for dev in devices {
                    try? sendMessage(messageDic, toDevice: dev)
                }
            }
        }
    }
    
    func setTorchStatus(_ on: Bool, device: Device? = nil) throws {
        if let deviceInfo = device {
            let messageDic = ["type":"modify", "torch":on] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            if captureDevice == nil {
                captureDevice = AVCaptureDevice.default(for: AVMediaType.video)
            }
            
            try captureDevice!.lockForConfiguration()
            captureDevice!.torchMode = on ? .on : .off;
            captureDevice!.unlockForConfiguration()
            
            let messageDic = ["type":"sync", "torch":on] as [String : Any]
            NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
            if (self.status == .Connected) {
                for dev in devices {
                    try? sendMessage(messageDic, toDevice: dev)
                }
            }
        }
    }
    
    private func didEnterBackground(_ notification: Notification) {
        if let tmp = captureDevice {
            if tmp.torchMode == .on {
                try! setTorchStatus(false)
            }
        }
    }
    
    func setBrightness(_ brightness: Float, device: Device? = nil) throws {
        if let deviceInfo = device {
            let messageDic = ["type":"modify", "brightness":brightness] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            UIScreen.main.brightness = CGFloat(brightness)
            self.brightness = brightness;
            
            let messageDic = ["type":"sync", "brightness":brightness] as [String : Any]
            NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
            if (self.status == .Connected) {
                for dev in devices {
                    try? sendMessage(messageDic, toDevice: dev)
                }
            }
        }
    }
    
    private func brightnessDidChanged(_ notification: Notification) {
        let brightness = Float((notification.object as! UIScreen).brightness)
        guard fabs(brightness - self.brightness) > 0.05 else {
            return
        }

        print("UIScreenBrightnessDidChange : \(brightness)")
        self.brightness = brightness;
        
        let messageDic = ["type":"sync", "brightness":brightness] as [String : Any]
        NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
        
        if (self.status == .Connected) {
            for dev in devices {
                try? sendMessage(messageDic, toDevice: dev)
            }
        }
    }
    
    func startAudioPlay(_ device: Device? = nil) throws {
        if let deviceInfo = device {
            let messageDic = ["type":"modify", "ring":true] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            if audioPlayer == nil {
                do {
                    try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
                    let _ = try AVAudioSession.sharedInstance().setActive(true)
                } catch let error as NSError {
                    print("an error occurred when audio session category.\n \(error)")
                }
                
                let path = Bundle.main.url(forResource: "audio", withExtension: "m4a")
                try! audioPlayer = AVAudioPlayer(contentsOf: path!)
                audioPlayer!.numberOfLoops = -1
                audioPlayer!.volume = audioVolume
            }
            
            audioPlayer!.play()
            NotificationCenter.default.addObserver(self, selector: #selector(audioSessionInterrupted), name: .AVAudioSessionInterruption, object: AVAudioSession.sharedInstance())
            
            let messageDic = ["type":"sync", "ring":true] as [String : Any]
            NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
            if (self.status == .Connected) {
                for dev in devices {
                    try? sendMessage(messageDic, toDevice: dev)
                }
            }
        }
    }
    
    func stopAudioPlay(_ device: Device? = nil) throws {
        if let deviceInfo = device {
            let messageDic = ["type":"modify", "ring":false] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            if let player = audioPlayer {
                player.stop()
            }
            
            NotificationCenter.default.removeObserver(self, name: .AVAudioSessionInterruption, object: AVAudioSession.sharedInstance())
            
            let messageDic = ["type":"sync", "ring":false] as [String : Any]
            NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
            if (self.status == .Connected) {
                for dev in devices {
                    try? sendMessage(messageDic, toDevice: dev)
                }
            }
        }
    }
    
    @objc private func audioSessionInterrupted(_ notification:Notification)
    {
        NotificationCenter.default.removeObserver(self, name: .AVAudioSessionInterruption, object: AVAudioSession.sharedInstance())
        
        let messageDic = ["type":"sync", "ring":false] as [String : Any]
        NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
        if (self.status == .Connected) {
            for dev in devices {
                try? sendMessage(messageDic, toDevice: dev)
            }
        }
    }
    
    func setVolume(_ volume: Float, device: Device? = nil) throws {
        if let deviceInfo = device {
            let messageDic = ["type":"modify", "volume":volume] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            audioVolume = volume
            audioPlayer?.volume = volume
            
            let messageDic = ["type":"sync", "volume":volume] as [String : Any]
            NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
            
            if (self.status == .Connected) {
                for dev in devices {
                    try? sendMessage(messageDic, toDevice: dev)
                }
            }
        }
    }
    
    func sendMessage(_ message: [String: Any], toDevice device: Device) throws {
        if device.deviceInfo.status == WhisperConnectionStatus.Connected {
            try sendMessage(message, toDeviceId: device.deviceId)
        }
        else {
            throw WhisperError.InternalError(errno:1)
        }
    }
    
    fileprivate func sendMessage(_ message: [String: Any], toDeviceId deviceId: String) throws {
        let jsonData = try JSONSerialization.data(withJSONObject: message, options: .prettyPrinted)
        let jsonString = NSString(data: jsonData, encoding: String.Encoding.utf8.rawValue)! as String
        try whisperInst.sendFriendMessage(to: deviceId, withMessage: jsonString)
    }
}

// MARK: - WhisperDelegate
extension DeviceManager : WhisperDelegate
{
    func connectionStatusDidChange(_ whisper: Whisper,
                                   _ newStatus: WhisperConnectionStatus) {
        self.status = newStatus
        if status == .Disconnected {
            self.devices.removeAll()
            self.remotePlayingDevices.removeAll()
        }
        
        NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
    }
    
    public func didBecomeReady(_ whisper: Whisper) {
        let myInfo = try! whisper.getSelfUserInfo()
        if myInfo.name?.isEmpty ?? true {
            myInfo.name = UIDevice.current.name
            try? whisper.setSelfUserInfo(myInfo)
        }

        try! _ = WhisperSessionManager.getInstance(whisper: whisper, handler: didReceiveSessionRequest)

#if USE_VANILLA
        let plistPath = Bundle.main.path(forResource: "Config", ofType: "plist")
        let info = NSDictionary(contentsOfFile: plistPath!) as! [String: String]

        let options = IceTransportOptions()
        options.threadModel = TransportOptions.SharedThreadModel
        options.stunHost = info["StunServer"]!
        options.turnHost = info["TurnServer"]!
        options.turnUsername = info["TurnUserName"]!
        options.turnPassword = info["TurnPassword"]!

        try! WhisperSessionManager.getInstance()!.addTransport(options)
#endif
    }
    
    public func selfUserInfoDidChange(_ whisper: Whisper,
                                      _ newInfo: WhisperUserInfo) {
        NotificationCenter.default.post(name: DeviceManager.SelfInfoChanged, object: nil)
    }
    
    public func didReceiveFriendsList(_ whisper: Whisper,
                                      _ friends: [WhisperFriendInfo]) {
        for friend in friends {
            self.devices.append(Device(friend))

            if friend.status == WhisperConnectionStatus.Connected {
                friendConnectionDidChange(whisper, friend.userId!, WhisperConnectionStatus.Connected)
            }
        }
        NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
    }
    
    public func friendInfoDidChange(_ whisper: Whisper,
                                    _ friendId: String,
                                    _ newInfo: WhisperFriendInfo) {
        for device in self.devices {
            if device.deviceId == friendId {
                device.deviceInfo = newInfo
                
                NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
                break
            }
        }
    }
    
    public func friendConnectionDidChange(_ whisper: Whisper,
                                          _ friendId: String,
                                          _ newStatus: WhisperConnectionStatus) {
        for device in self.devices {
            if device.deviceId == friendId {
                device.deviceInfo.status = newStatus
                if (newStatus == WhisperConnectionStatus.Connected) {
                    if let layer = device.videoPlayLayer {
                        _ = device.startVideoPlay(device.videoPlayView!, layer)
                    }
                }
                else {
                    device.remotePlaying = false
                    device.closeSession()
                    self.remotePlayingDevices.remove(device)
                    self.checkAndStopVideoCapture()
                }
                
                NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
                break
            }
        }
    }
    
    public func didReceiveFriendRequest(_ whisper: Whisper,
                                        _ userId: String,
                                        _ userInfo: WhisperUserInfo,
                                        _ hello: String) {
        print("didReceiveFriendRequest, userId : \(userId), name : \(String(describing: userInfo.name)), hello : \(hello)")
        do {
#if USE_VANILLA
            try whisper.acceptFriend(with: userId, entrusted: true, withExpire: nil)
#elseif USE_ORCHID
            try whisper.acceptFriend(with: userId)
#else
//MARK: unknown variant.
#endif
        } catch {
            NSLog("Accept friend \(userId) error : \(error.localizedDescription)")
        }
    }
    
    public func newFriendAdded(_ whisper: Whisper,
                               _ newFriend: WhisperFriendInfo) {
        self.devices.append(Device(newFriend))
        NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
    }
    
    public func friendRemoved(_ whisper: Whisper,
                              _ friendId: String) {
        for index in 0..<self.devices.count {
            let device = self.devices[index]
            if device.deviceId == friendId {
                device.closeSession();

                self.remotePlayingDevices.remove(device)
                self.devices.remove(at: index)
                
                NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
                break
            }
        }
    }
    
    public func didReceiveFriendMessage(_ whisper: Whisper,
                                        _ from: String,
                                        _ message: String) {
        do {
            let data = message.data(using: .utf8)
            let decoded = try JSONSerialization.jsonObject(with: data!, options: [])
            let dict = decoded as! [String: Any]
            let msgType = dict["type"] as! String
            switch msgType {
            case "query":
                try getDeviceStatus() { status in
                    try? self.sendMessage(status!, toDeviceId: from)
                }

            case "status":
                let deviceId = from.components(separatedBy: "@")[0]
                if let device = devices.first(where: {$0.deviceId == deviceId}) {
                    device.status = dict

                    if let curMessage = currentMessage {
                        if curMessage.device == device  {
                            curMessage.timer.invalidate()
                            currentMessage = nil

                            DispatchQueue.main.sync {
                                curMessage.handler(dict)
                            }
                        }
                    }
                }

            case "sync":
                let deviceId = from.components(separatedBy: "@")[0]
                if let device = devices.first(where: {$0.deviceId == deviceId}) {
                    for (key, value) in dict {
                        device.status?[key] = value
                    }
                }
                NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: deviceId, userInfo: dict)

            case "modify":
                if let bulb = dict["bulb"] as? Bool {
                    try! setBulbStatus(bulb)
                }
                if let torchStatus = dict["torch"] as? Bool {
                    try! setTorchStatus(torchStatus)
                }
                if let brightness = dict["brightness"] as? Float {
                    try! setBrightness(brightness)
                }
                if let audioPlay = dict["ring"] as? Bool {
                    if audioPlay {
                        try! startAudioPlay()
                    }
                    else {
                        try! stopAudioPlay()
                    }
                }
                if let volume = dict["volume"] as? Float {
                    try! setVolume(volume)
                }
                if let videoPlay = dict["camera"] as? Bool {
                    let deviceId = from.components(separatedBy: "@")[0]
                    if let device = devices.first(where: {$0.deviceId == deviceId}) {
                        if videoPlay {
                            remotePlayingDevices.insert(device)
                            startVideoCapture()
                        }
                        else {
                            remotePlayingDevices.remove(device)
                            checkAndStopVideoCapture()
                        }
                        device.remotePlaying = videoPlay
                    }
                }

            default:
                print("unsupported message")
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    public func didReceiveSessionRequest(whisper: Whisper, from: String, sdp: String) {
        let deviceId = from.components(separatedBy: "@")[0]
        let device = self.devices.first(where: {$0.deviceId == deviceId})
        _ = device!.didReceiveSessionInviteRequest(whisper: whisper, sdp: sdp)
    }
}

// MARK: - Video methods
extension DeviceManager : AVCaptureVideoDataOutputSampleBufferDelegate
{
    func startVideoPlay(_ layer : AVSampleBufferDisplayLayer) {
        videoPlayLayer = layer
        startVideoCapture()
    }
    
    func stopVideoPlay() {
        videoPlayLayer = nil
        checkAndStopVideoCapture()
    }
    
    func startVideoCapture() {
        if captureSession == nil {
            captureSession = AVCaptureSession()

            if captureDevice == nil {
                captureDevice = AVCaptureDevice.default(for: AVMediaType.video)
            }

            do {
                var formatFound = false

                findLoop: for format in captureDevice!.formats {
                    for range in format.videoSupportedFrameRateRanges {
                        if range.maxFrameRate > 30 && range.minFrameRate < 15 {
                            print ("range.maxFrameRate:",  range.maxFrameRate ,  " minFrameRate:%d", range.minFrameRate)
                            formatFound = true
                            break findLoop
                        }
                    }
                }

                if formatFound {
                    try captureDevice!.lockForConfiguration()
                    captureDevice!.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
                    captureDevice!.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    captureDevice!.unlockForConfiguration()
                }
            }
            catch {
                fatalError()
            }

            let videoInput = try! AVCaptureDeviceInput(device: captureDevice!)
            guard captureSession!.canAddInput(videoInput) else {
                fatalError()
            }
            captureSession!.addInput(videoInput)
            
            let output = AVCaptureVideoDataOutput()
            let videoDataOutputQueue = DispatchQueue(label: "videoDataOutputQueue")
            output.setSampleBufferDelegate(self, queue: videoDataOutputQueue)

            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as AnyHashable as! String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            output.alwaysDiscardsLateVideoFrames = true

            guard captureSession!.canAddOutput(output) else {
                fatalError()
            }

            captureSession!.addOutput(output)
            captureConnection = output.connection(with: AVMediaType.video)
        }
        
        if !captureSession!.isRunning {
            captureSession!.beginConfiguration()
            if captureConnection!.isVideoOrientationSupported {
                switch UIApplication.shared.statusBarOrientation {
                case .portrait:
                    captureConnection!.videoOrientation = .portrait
                case .portraitUpsideDown:
                    captureConnection!.videoOrientation = .portraitUpsideDown
                case .landscapeLeft:
                    captureConnection!.videoOrientation = .landscapeLeft
                case .landscapeRight:
                    captureConnection!.videoOrientation = .landscapeRight
                default:
                    captureConnection!.videoOrientation = .portrait
                }
            }

            let preset = AVCaptureSession.Preset.high
            if captureSession!.canSetSessionPreset(preset) {
                captureSession!.sessionPreset = preset
            }
            else {
                captureSession!.sessionPreset = AVCaptureSession.Preset.medium
            }
            captureSession!.commitConfiguration()
            captureSession!.startRunning()
        }
    }
    
    func checkAndStopVideoCapture() {
        if let captureSession = captureSession {
            if remotePlayingDevices.count == 0 {
                if videoPlayLayer == nil {
                    if captureSession.isRunning {
                        captureSession.stopRunning()
                    }
                }

                if let encoder = encoder {
                    encoder.end()
                }
            }
        }
    }

// MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput,  didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let playLayer = videoPlayLayer {
            //if playLayer.isReadyForMoreMediaData {
                DispatchQueue.main.sync {
                    playLayer.enqueue(sampleBuffer)
                    if playLayer.status == .failed {
                        playLayer.flush()
                    }
                    else {
                        playLayer.setNeedsDisplay()
                    }
                }
            //}
        }

        if self.remotePlayingDevices.count > 0 {
            if encoder == nil {
                encoder = VideoEncoder()
                encoder?.delegate = self
            }
            encoder?.encode(sampleBuffer)
        }
    }
}

extension DeviceManager : VideoEncoderDelegate
{
    func videoEncoder(_ encoder: VideoEncoder!, appendBytes bytes: UnsafeRawPointer!, length: Int) {
        let data = Data(bytes: bytes, count: length)
        for device in self.remotePlayingDevices {
            if device.state == .Connected {
                do {
                    let result = try device.stream!.writeData(data)
                    if result.intValue != length {
                        NSLog("Warning: writeData result: \(result), total length: \(length)")
                    }
                }
                catch {
                    NSLog("writeData error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func videoEncoder(_ encoder: VideoEncoder!, error: String!) {
    }
}
