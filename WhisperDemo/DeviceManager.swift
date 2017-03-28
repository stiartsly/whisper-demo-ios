//
//  DeviceManager.swift
//  WhisperDemo
//
//  Created by suleyu on 2017/1/12.
//  Copyright © 2017年 Kortide. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer
import ManagedWhisper

class DeviceManager : NSObject {
    
// MARK: Constants
    
    fileprivate static let appId = "7sRQjDsniyuHdZ9zsQU9DZbMLtQGLBWZ78yHWgjPpTKm"
    fileprivate static let appKey = "6tzPPAgSACJdScX79wuzMNPQTWkRLZ4qEdhLcZU6q4B9"
    fileprivate static let apiServer = "https://whisper.freeddns.org:8443/web/api"
    fileprivate static let mqttServer = "ssl://whisper.freeddns.org:8883"
//    fileprivate static let stunServer = "whisper.freeddns.org"
//    fileprivate static let turnServer = "whisper.freeddns.org"
//    fileprivate static let turnUsername = "whisper"
//    fileprivate static let turnPassword = "io2016whisper"
    
//    fileprivate static let apiServerUrl = "https://192.168.3.182:8443/web/api"
//    fileprivate static let mqttServerUri = "ssl://192.168.3.182:8883"
//    fileprivate static let apiServerUrl = "http://192.168.3.182:8080/web/api"
//    fileprivate static let mqttServerUri = "tcp://192.168.3.182:1883"
    fileprivate static let stunServer = "27.115.62.114"
    fileprivate static let turnServer = "27.115.62.114"
    fileprivate static let turnUsername = "demo"
    fileprivate static let turnPassword = "secret"
    
//    fileprivate static let videoFramesPreSecond : CMTimeScale = 2
    
// MARK: - Notifications
    
    static let SelfInfoChanged = NSNotification.Name("kNotificationSelfInfoChanged")
    static let DeviceListChanged = NSNotification.Name("kNotificationDeviceListChanged")
    static let DeviceStatusChanged = NSNotification.Name("kNotificationDeviceStatusChanged")
    
// MARK: - Singleton
    static let sharedInstance = DeviceManager()
    
// MARK: - Variables
    
    var status = WhisperConnectionStatus.Disconnected;
    var whisperInst: Whisper!
    var devices = [Device]()
    
// MARK: - Private variables
    
    fileprivate var bulbStatus = false
    fileprivate var captureDevice: AVCaptureDevice?
    fileprivate var audioPlayer : AVAudioPlayer?
    fileprivate var audioVolume : Float = 1.0
    
    fileprivate var captureSession : AVCaptureSession?
    fileprivate var videoPlayLayer : AVSampleBufferDisplayLayer?
    fileprivate var remotePlayingDevices = Set<Device>()
    fileprivate var encoder : VideoEncoder?
    
// MARK: - Methods
    
    override init() {
        Whisper.setLogLevel(.Debug)
    }
    
    func start() {
        if whisperInst == nil {
            do {
                let whisperDirectory: String = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0] + "/whisper"
                if !FileManager.default.fileExists(atPath: whisperDirectory) {
                    var url = URL(fileURLWithPath: whisperDirectory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                    
                    var resourceValues = URLResourceValues()
                    resourceValues.isExcludedFromBackup = true
                    try url.setResourceValues(resourceValues)
                }
                
                let options = WhisperOptions()
                options.setAppId(DeviceManager.appId, andKey: DeviceManager.appKey)
                options.apiServerUrl = DeviceManager.apiServer
                options.mqttServerUri = DeviceManager.mqttServer
                options.trustStore = Bundle.main.path(forResource: "whisper", ofType: "pem")
                options.persistentLocation = whisperDirectory
                options.deviceId = UIDevice.current.identifierForVendor!.uuidString
                options.connectTimeout = 5
                
//                try? FileManager.default.removeItem(atPath: whisperDirectory + "/.whisper")
                try whisperInst = Whisper.getInstance(options: options, delegate: self, nil)
                print("Whisper instance created")
                
                try whisperInst.start(iterateInterval: 1000)
                print("Whisper started, waiting for ready")
                
                NotificationCenter.default.addObserver(forName: .UIApplicationWillResignActive, object: nil, queue: OperationQueue.main, using: didEnterBackground)
                NotificationCenter.default.addObserver(forName: .UIScreenBrightnessDidChange, object: nil, queue: OperationQueue.main, using: brightnessDidChanged)
            }
            catch {
                NSLog("Start whisper instance error : \(error)")
            }
        }
    }
    
    func getDeviceStatus(_ device: Device? = nil) throws -> [String: Any]? {
        if let deviceInfo = device {
            let messageDic = ["type":"query"]
            try sendMessage(messageDic, toDevice: deviceInfo)
            return nil
        }
        else {
            var selfStstus = [String : Any]()
            selfStstus["type"] = "status"
            selfStstus["bulb"] = bulbStatus
            
            if captureDevice == nil {
                captureDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo)
            }
            if captureDevice!.hasTorch && captureDevice!.isTorchAvailable {
                selfStstus["torch"] = captureDevice!.torchMode == .on ? "on" : "off"
            }
            else {
                selfStstus["torch"] = "none"
            }
            
            selfStstus["brightness"] = Float(UIScreen.main.brightness)
            
            if let player = audioPlayer {
                selfStstus["audioPlay"] = player.isPlaying
                selfStstus["volume"] = player.volume
            }
            else {
                selfStstus["audioPlay"] = false
                selfStstus["volume"] = audioVolume
            }
            
            return selfStstus
        }
    }
    
    
    func setBulbStatus(_ on: Bool, device: Device? = nil) throws {
        if let deviceInfo = device {
            let messageDic = ["type":"modify", "bulb":on] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            bulbStatus = on
            
            let messageDic = ["type":"status", "bulb":on] as [String : Any]
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
            let messageDic = ["type":"modify", "torch":on ? "on" : "off"] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            if captureDevice == nil {
                captureDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo)
            }
            
            try captureDevice!.lockForConfiguration()
            captureDevice!.torchMode = on ? .on : .off;
            captureDevice!.unlockForConfiguration()
            
            let messageDic = ["type":"status", "torch":on ? "on" : "off"] as [String : Any]
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
            
            let messageDic = ["type":"status", "brightness":brightness] as [String : Any]
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
        print("UIScreenBrightnessDidChange : \(brightness)")
        
        let messageDic = ["type":"status", "brightness":brightness] as [String : Any]
        NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
        
        if (self.status == .Connected) {
            for dev in devices {
                try? sendMessage(messageDic, toDevice: dev)
            }
        }
    }
    
    func startAudioPlay(_ device: Device? = nil) throws {
        if let deviceInfo = device {
            let messageDic = ["type":"modify", "audioPlay":true] as [String : Any]
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
            
            let messageDic = ["type":"status", "audioPlay":true] as [String : Any]
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
            let messageDic = ["type":"modify", "audioPlay":false] as [String : Any]
            try sendMessage(messageDic, toDevice: deviceInfo)
        }
        else {
            if let player = audioPlayer {
                player.stop()
            }
            
            NotificationCenter.default.removeObserver(self, name: .AVAudioSessionInterruption, object: AVAudioSession.sharedInstance())
            
            let messageDic = ["type":"status", "audioPlay":false] as [String : Any]
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
        print("audioSessionInterrupted: \(notification)")
        NotificationCenter.default.removeObserver(self, name: .AVAudioSessionInterruption, object: AVAudioSession.sharedInstance())
        
        let messageDic = ["type":"status", "audioPlay":false] as [String : Any]
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
            
            let messageDic = ["type":"status", "volume":volume] as [String : Any]
            NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: nil, userInfo: messageDic)
            
            if (self.status == .Connected) {
                for dev in devices {
                    try? sendMessage(messageDic, toDevice: dev)
                }
            }
        }
    }
    
    func sendMessage(_ message: [String: Any], toDevice device: Device) throws {
        if device.deviceInfo.presence == "online" {
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
//    func willBecomeIdle(_ whisper: Whisper, _ context: AnyObject?) {
//        print("onIdle")
//    }
    
    func connectionStatusDidChange(_ whisper: Whisper,
                                   _ newStatus: WhisperConnectionStatus,
                                   _ context: AnyObject?) {
        print("onConnection status : \(status)")
        self.status = newStatus
        if status == .Disconnected {
            self.devices.removeAll()
            self.remotePlayingDevices.removeAll()
        }
        
        NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
    }
    
    public func didBecomeReady(_ whisper: Whisper, _ context: AnyObject?) {
        print("onReady")
        let myInfo = try! whisper.getSelfUserInfo()
        if myInfo.name?.isEmpty ?? true {
            myInfo.name = UIDevice.current.name
            try? whisper.setSelfUserInfo(myInfo)
        }
        
        //self.devices = try! whisper.getFriends()
        //NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
        
        let options = WhisperSessionManagerOptions(stunServer: DeviceManager.stunServer,
                                                   turnServer: DeviceManager.turnServer,
                                                   turnUsername: DeviceManager.turnUsername,
                                                   turnPassword: DeviceManager.turnPassword)
        try! _ = WhisperSessionManager.getInstance(whisper: whisper, options: options, handler: didReceiveSessionRequest, nil)
    }
    
    public func selfUserInfoDidChange(_ whisper: Whisper,
                                      _ newInfo: WhisperUserInfo,
                                      _ context: AnyObject?) {
        print("onSelfInfoChanged : \(newInfo)")
        NotificationCenter.default.post(name: DeviceManager.SelfInfoChanged, object: nil)
    }
    
    public func iterateFriend(_ whisper: Whisper,
                              _ friendInfo: WhisperFriendInfo?,
                              _ context: AnyObject?) ->Bool {
        print("onFriendIterated : \(friendInfo)")
        if let friend = friendInfo {
            self.devices.append(Device(friend))
        }
        else {
            NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
        }
        return true;
    }
    
    public func friendInfoDidChange(_ whisper: Whisper,
                                    _ friendId: String,
                                    _ newInfo: WhisperFriendInfo,
                                    _ context: AnyObject?) {
        print("onFriendInfoChanged")
        for index in 0..<self.devices.count {
            let device = self.devices[index]
            if device.deviceId == friendId {
                device.deviceInfo = newInfo
                
                NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
                break
            }
        }
    }
    
    public func friendPresenceDidChange(_ whisper: Whisper,
                                        _ friendId: String,
                                        _ newPresence: String,
                                        _ context: AnyObject?) {
        print("onFriendPresence")
        for device in self.devices {
            if device.deviceId == friendId {
                device.deviceInfo.presence = newPresence
                if newPresence == "online" {
                    if let layer = device.videoPlayLayer {
                        _ = device.startVideoPlay(layer)
                    }
                }
                else {
                    device.remotePlaying = false
                    device.closeSession()
                    self.remotePlayingDevices.remove(device)
                }
                
                NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
                break
            }
        }
    }
    
    public func didReceiveFriendRequest(_ whisper: Whisper,
                                        _ userId: String,
                                        _ userInfo: WhisperUserInfo,
                                        _ hello: String,
                                        _ context: AnyObject?) -> Bool {
        print("onFriendRequest, userId : \(userId), name : \(userInfo.name), hello : \(hello)")
        var result = false
        do {
            try whisper.replyFriendRequest(to: userId, withStatus: 0, reason: nil, entrusted: true, expire: nil)
            result = true
        } catch {
            NSLog("replyFriendRequest error : \(error)")
        }
        return result;
    }
    
    public func didReceiveFriendResponse(_ whisper: Whisper,
                                         _ userId: String,
                                         _ status: Int,
                                         _ reason: String?,
                                         _ entrusted: Bool,
                                         _ expire: String?,
                                         _ context: AnyObject?) -> Bool {
        print("onFriendResponse, userId : \(userId)")
        return true;
    }
    
    public func newFriendAdded(_ whisper: Whisper,
                               _ newFriend: WhisperFriendInfo,
                               _ context: AnyObject?) {
        print("onFriendAdded")
        self.devices.append(Device(newFriend))
        NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
    }
    
    public func friendRemoved(_ whisper: Whisper,
                              _ friendId: String,
                              _ context: AnyObject?) {
        print("onFriendRemoved")
        for index in 0..<self.devices.count {
            let device = self.devices[index]
            if device.deviceId == friendId {
                self.remotePlayingDevices.remove(device)
                self.devices.remove(at: index)
                
                NotificationCenter.default.post(name: DeviceManager.DeviceListChanged, object: nil)
                break
            }
        }
    }
    
    public func didReceiveFriendMessage(_ whisper: Whisper,
                                        _ from: String,
                                        _ message: String,
                                        _ context: AnyObject?) -> Bool {
        print("onFriendMessage: \(message)")
        do {
            let data = message.data(using: .utf8)
            let decoded = try JSONSerialization.jsonObject(with: data!, options: [])
            let dict = decoded as! [String: Any]
            let msgType = dict["type"] as! String
            switch msgType {
            case "query":
                let message = try getDeviceStatus()
                try sendMessage(message!, toDeviceId: from)
                
            case "status":
                let userId = from.components(separatedBy: "@")[0]
                NotificationCenter.default.post(name: DeviceManager.DeviceStatusChanged, object: userId, userInfo: dict)
                
            case "modify":
                if let bulb = dict["bulb"] as? Bool {
                    try! setBulbStatus(bulb)
                }
                if let torchStatus = dict["torch"] as? String {
                    try! setTorchStatus(torchStatus == "on")
                }
                if let brightness = dict["brightness"] as? Float {
                    try! setBrightness(brightness)
                }
                if let audioPlay = dict["audioPlay"] as? Bool {
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
                if let videoPlay = dict["videoPlay"] as? Bool {
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
        return true;
    }
    
    public func didReceiveFriendInviteRequest(_ whisper: Whisper,
                                              _ from: String,
                                              _ data: String,
                                              _ context: AnyObject?) -> Bool {
        print("onFriendInvite")
        return false;
    }
    
    public func didReceiveSessionRequest(whisper: Whisper, from: String, sdp: String, context: AnyObject?) -> Bool {
        let deviceId = from.components(separatedBy: "@")[0]
        let device = self.devices.first(where: {$0.deviceId == deviceId})
        return device!.didReceiveSessionInviteRequest(whisper: whisper, sdp: sdp)
    }
}

// MARK: - Video methods
extension DeviceManager : AVCaptureVideoDataOutputSampleBufferDelegate, VideoEncoderDelegate
{
    func startVideoPlay(_ layer : AVSampleBufferDisplayLayer, device: Device? = nil) {
        if let selectedDevice = device {
            _ = selectedDevice.startVideoPlay(layer)
        }
        else {
            videoPlayLayer = layer
            startVideoCapture()
        }
    }
    
    func stopVideoPlay(_ device: Device? = nil) {
        if let selectedDevice = device {
            selectedDevice.stopVideoPlay()
        }
        else {
            videoPlayLayer = nil
            checkAndStopVideoCapture()
        }
    }
    
    func startVideoCapture() {
        if captureSession == nil {
            captureSession = AVCaptureSession()
            
            if captureDevice == nil {
                captureDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo)
            }
            
//            do {
//                try captureDevice!.lockForConfiguration()
//                if captureDevice!.activeFormat.videoSupportedFrameRateRanges != nil {
//                    captureDevice!.activeVideoMinFrameDuration = CMTime(value: 1, timescale: DeviceManager.videoFramesPreSecond)
//                    captureDevice!.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: DeviceManager.videoFramesPreSecond)
//                }
//                captureDevice!.unlockForConfiguration()
//            }
//            catch {
//                print("set frame rate failed");
//            }
            
            let videoInput = try! AVCaptureDeviceInput(device: captureDevice)
            captureSession!.addInput(videoInput)
            
            let output = AVCaptureVideoDataOutput()
            let videoDataOutputQueue = DispatchQueue(label: "videoDataOutputQueue")
            output.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as AnyHashable : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            captureSession!.addOutput(output)
            
            captureSession!.beginConfiguration()
            let preset = AVCaptureSessionPreset352x288
            if captureSession!.canSetSessionPreset(preset) {
                captureSession?.sessionPreset = preset
            }
            else {
                captureSession?.sessionPreset = AVCaptureSessionPresetMedium
            }
            
            if let videoConnection = output.connection(withMediaType: AVMediaTypeVideo) {
                if videoConnection.isVideoOrientationSupported {
                    videoConnection.videoOrientation = .portrait
                }
            }
            captureSession!.commitConfiguration()
        }
        
        if !captureSession!.isRunning {
            captureSession!.startRunning()
        }
    }
    
    func checkAndStopVideoCapture() {
        if videoPlayLayer == nil && remotePlayingDevices.count == 0 {
            if let captureSession = captureSession {
                if captureSession.isRunning {
                    captureSession.stopRunning()
                }
            }
            if let encoder = encoder {
                encoder.end()
            }
        }
    }

// MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        if let playLayer = videoPlayLayer {
            if playLayer.isReadyForMoreMediaData {
                DispatchQueue.main.sync {
                    playLayer.enqueue(sampleBuffer)
                    if playLayer.status == .failed {
                        playLayer.flush()
                    }
                    else {
                        playLayer.setNeedsDisplay()
                    }
                }
            }
        }
        
        if self.remotePlayingDevices.count > 0 {
            if encoder == nil {
                encoder = VideoEncoder()
                encoder?.delegate = self
            }
            encoder?.encode(sampleBuffer)
        }
    }

// MARK: VideoEncoderDelegate
    
    func videoEncoder(_ encoder: VideoEncoder!, appendBytes bytes: UnsafeRawPointer!, length: Int) {
        //let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: length, deallocator: .none)
        let data = Data(bytes: bytes, count: length)
        for device in self.remotePlayingDevices {
            if device.state == .Connected {
                do {
                    let result = try device.stream!.writeData(component: 1, data: data)
                    if result.intValue != length {
                        NSLog("writeData result: \(result), total length: \(length)")
                    }
                }
                catch {
                    NSLog("writeData error: \(error)")
                }
            }
        }
    }
    
    func videoEncoder(_ encoder: VideoEncoder!, error: String!) {
        
    }
}
