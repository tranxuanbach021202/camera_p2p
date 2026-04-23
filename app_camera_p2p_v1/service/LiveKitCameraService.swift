//
//  LiveKitCameraService.swift
//  app_camera_p2p_v1
//

import LiveKit
import AVFoundation
import Combine
import SwiftUI
import UIKit
import os

private let cameraLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.camera_p2p", category: "CameraService")

@MainActor
class LiveKitCameraService: NSObject, ObservableObject {

    @Published var room: Room?
    @Published var isConnected = false
    @Published var isPublishing = false
    @Published var errorMessage: String?

    @Published private(set) var cameraTrack: LocalVideoTrack?
    private var videoPublication: LocalTrackPublication?

    // Continuation dùng để chờ delegate báo camera track sẵn sàng.
    private var trackReadyContinuation: CheckedContinuation<LocalVideoTrack?, Never>?

    let serverURL: String
    let token: String
    let roomName: String

    // MARK: - Photo Capture Properties
    private let photoOutput = AVCapturePhotoOutput()
    // Trả về Data? — nil nếu chụp thất bại, jpeg data nếu thành công.
    private var captureContinuation: CheckedContinuation<Data?, Never>?

    // Callback được gọi sau khi chụp ảnh thành công (dù local hay remote).
    // View gán closure này để xử lý tiếp — ví dụ: gửi Telegram.
    var onPhotoReady: ((Data) async -> Void)?

    // MARK: - Camera State
    @Published var zoomFactor: CGFloat = 1.0
    var maxZoomFactor: CGFloat = 8.0
    @Published private(set) var isSwitchingCamera = false

    // MARK: - Microphone State
    @Published var isMicEnabled: Bool = false

    // MARK: - Screen Lock
    @Published var isScreenLocked: Bool = false
    /// Viewer đã nhấn "cho phép mở khoá" — camera chỉ unlock được khi cờ này = true.
    @Published var isUnlockAllowed: Bool = false
    private var savedBrightness: CGFloat = UIScreen.main.brightness

    // MARK: - Mic Selection
    private var routeChangeObserver: NSObjectProtocol?

    init(serverURL: String, token: String, roomName: String) {
        self.serverURL = serverURL
        self.token = token
        self.roomName = roomName
        super.init()
    }

    // MARK: - Camera Controls

    func switchCamera() {
        guard let track = cameraTrack,
              let capturer = track.capturer as? CameraCapturer,
              !isSwitchingCamera else { return }

        isSwitchingCamera = true

        Task {
            do {
                try await capturer.switchCameraPosition()
                // Re-inject photoOutput after switching so it connects
                // to the new AVCaptureDeviceInput.
                self.setupPhotoOutput()
            } catch {
                self.errorMessage = "Không thể đổi camera: \(error.localizedDescription)"
            }
            self.isSwitchingCamera = false
        }
    }

    func setZoom(factor: CGFloat) {
        guard let track = cameraTrack,
              let capturer = track.capturer as? CameraCapturer,
              let device = capturer.device else { return }

        let clampedFactor = min(max(factor, 1.0), min(device.activeFormat.videoMaxZoomFactor, 8.0))

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clampedFactor
            device.unlockForConfiguration()
            self.zoomFactor = clampedFactor
            self.maxZoomFactor = min(device.activeFormat.videoMaxZoomFactor, 8.0)
        } catch {
            cameraLogger.error("❌ Zoom error: \(error)")
        }
    }

    // MARK: - Connection & Publishing

    func connect() async {
        do {
            let newRoom = Room(delegate: self)
            let connectOptions = ConnectOptions(autoSubscribe: false)
            let roomOptions = RoomOptions(
                defaultCameraCaptureOptions: CameraCaptureOptions(
                    position: .front,
                    dimensions: .h480_43,
                    fps: 3            //Hard Code Fps       // 15fps — tiết kiệm ~30% pin encode so với 24fps
                ),
                defaultVideoPublishOptions: VideoPublishOptions(
                    encoding: VideoEncoding(
                        maxBitrate: 300_000,  // 300kbps — ổn định trên 4G yếu
                        maxFps: 3 //Hard code FPS
                    ),
                    simulcast: false          // tắt simulcast — không cần multi-layer khi chỉ có 1 viewer
                )
            )

            try await newRoom.connect(
                url: serverURL,
                token: token,
                connectOptions: connectOptions,
                roomOptions: roomOptions
            )

            self.room = newRoom
            self.isConnected = true
            cameraLogger.info("✅ Connected to room: \(self.roomName)")
            self.setupRouteChangeObserver()
            Task { await self.sendMicList() }

        } catch {
            cameraLogger.error("❌ connect() threw: \(String(describing: error))")
            errorMessage = "Kết nối thất bại: \(String(describing: error))"
        }
    }

    func startPublishingCamera() async {
        guard let room = room, cameraTrack == nil else { return }

        do {
            try await room.localParticipant.setCamera(enabled: true)
        } catch {
            errorMessage = "Publish camera failed: \(error)"
            cameraLogger.error("❌ setCamera failed: \(error)")
            return
        }

        // Kiểm tra ngay nếu track đã sẵn sàng (trường hợp SDK trả về đồng bộ)
        if let existing = room.localParticipant.firstCameraVideoTrack as? LocalVideoTrack {
            cameraLogger.debug("✅ Camera track ready immediately")
            self.cameraTrack = existing
            setupPhotoOutput()
            isPublishing = true
            return
        }

        // Chờ delegate didPublishTrack báo track sẵn sàng, timeout 2 giây.
        // Tránh polling — SDK sẽ gọi callback khi track thực sự được publish.
        cameraLogger.debug("⏳ Waiting for camera track via delegate...")
        let track = await withCheckedContinuation { (continuation: CheckedContinuation<LocalVideoTrack?, Never>) in
            self.trackReadyContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self, let cont = self.trackReadyContinuation else { return }
                    cameraLogger.warning("⚠️ Camera track timeout sau 2 giây")
                    cont.resume(returning: nil)
                    self.trackReadyContinuation = nil
                }
            }
        }

        guard let track else {
            errorMessage = "Camera track không khởi động được sau 2 giây."
            return
        }

        self.cameraTrack = track
        setupPhotoOutput()
        isPublishing = true
        UIApplication.shared.isIdleTimerDisabled = true  // Ngăn iOS auto-lock khi đang stream
        cameraLogger.info("✅ Camera publishing started")

        // Bật microphone cùng lúc với camera
        await enableMicrophone()
    }

    func stopPublishing() async {
        guard let room = room else { return }
        do {
            if let publication = videoPublication {
                try await room.localParticipant.unpublish(publication: publication)
                videoPublication = nil
            } else {
                try await room.localParticipant.setCamera(enabled: false)
            }
            try await room.localParticipant.setMicrophone(enabled: false)
        } catch {
            cameraLogger.error("⚠️ Unpublish error: \(error)")
        }
        cameraTrack = nil
        isPublishing = false
        isMicEnabled = false
        UIApplication.shared.isIdleTimerDisabled = false  // Cho phép iOS auto-lock trở lại
    }

    func toggleMicrophone() {
        Task { await setMicrophone(enabled: !isMicEnabled) }
    }

    private func enableMicrophone() async {
        await setMicrophone(enabled: true)
    }

    private func setMicrophone(enabled: Bool) async {
        guard let room = room else { return }
        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
            isMicEnabled = enabled
            cameraLogger.info("\(enabled ? "🎙️ Microphone ON" : "🔇 Microphone OFF")")


            await sendMicState()   // Đồng bộ trạng thái về viewer
        } catch {
            cameraLogger.error("❌ setMicrophone(\(enabled)) failed: \(error)")
        }
    }

    func disconnect() async {
        await stopPublishing()
        await room?.disconnect()
        isConnected = false
        room = nil
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }

    // MARK: - Photo Output Setup

    /// Inject AVCapturePhotoOutput vào AVCaptureSession của LiveKit.
    /// Phải gọi lại mỗi khi switch camera vì DeviceInput thay đổi.
    ///
    /// [PLAN 1] Trước khi thêm output, scan toàn bộ device.formats để tìm format
    /// có supportedMaxPhotoDimensions cao nhất mà vẫn hỗ trợ 480p video ở 15fps.
    /// Switch activeFormat sang đó → ảnh chụp đạt max phần cứng, stream vẫn 480p.
    private func setupPhotoOutput() {
        guard let track = cameraTrack,
              let capturer = track.capturer as? CameraCapturer else { return }

        let session = capturer.captureSession

        session.beginConfiguration()

        if session.outputs.contains(photoOutput) {
            session.removeOutput(photoOutput)
        }

        // [PLAN 1] Tìm và switch sang format tối ưu cho ảnh, trong khi vẫn giữ 480p video
        if #available(iOS 16.0, *), let device = capturer.device {
            switchToBestPhotoFormat(device: device)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)

            if #available(iOS 16.0, *) {
                let dims = capturer.device?.activeFormat.supportedMaxPhotoDimensions ?? []
                let maxDim = dims.max { a, b in
                    let aPixels = Int64(a.width) * Int64(a.height)
                    let bPixels = Int64(b.width) * Int64(b.height)
                    return aPixels < bPixels
                }
                if let maxDim {
                    photoOutput.maxPhotoDimensions = maxDim
                    cameraLogger.info("📸 [Plan1] Photo dimensions after format switch: \(maxDim.width)×\(maxDim.height)")
                }
            } else {
                photoOutput.isHighResolutionCaptureEnabled = true
            }

            photoOutput.maxPhotoQualityPrioritization = .quality
            cameraLogger.debug("✅ Đã inject AVCapturePhotoOutput vào LiveKit session")
        }

        session.commitConfiguration()
    }

    /// [PLAN 1] Scan device.formats để tìm format có photo dimensions cao nhất
    /// mà vẫn hỗ trợ video 640×480 (h480_43) ở 15fps.
    /// Nếu tìm được format tốt hơn current activeFormat thì switch.
    @available(iOS 16.0, *)
    private func switchToBestPhotoFormat(device: AVCaptureDevice) {
        // h480_43 = 640×480 — format phải hỗ trợ ít nhất kích thước này để LiveKit có thể stream
        let minVideoWidth: Int32  = 640
        let minVideoHeight: Int32 = 480
        let minFps: Float64       = 3.0 //Hard code FPS

        var bestFormat: AVCaptureDevice.Format?
        var bestPhotoPixels: Int64 = 0

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= minVideoWidth, dims.height >= minVideoHeight else { continue }

            let supportsFps = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= minFps
            }
            guard supportsFps else { continue }

            let maxPixels = format.supportedMaxPhotoDimensions
                .map { Int64($0.width) * Int64($0.height) }
                .max() ?? 0

            if maxPixels > bestPhotoPixels {
                bestPhotoPixels = maxPixels
                bestFormat = format
            }
        }

        guard let bestFormat, bestFormat != device.activeFormat else {
            cameraLogger.debug("📸 [Plan1] Format hiện tại đã tối ưu hoặc không có format nào tốt hơn")
            return
        }

        let bestDim = bestFormat.supportedMaxPhotoDimensions.max {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        cameraLogger.info("📸 [Plan1] Switching activeFormat → photo max: \(bestDim?.width ?? 0)×\(bestDim?.height ?? 0)")

        do {
            try device.lockForConfiguration()
            device.activeFormat = bestFormat
            // Switching activeFormat resets frame duration to the format's default (thường 30fps).
            // Phải set lại thủ công để giữ đúng 15fps mà LiveKit đã config.
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(minFps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
            cameraLogger.info("📸 [Plan1] Format switched, fps locked at \(Int(minFps))fps")
        } catch {
            cameraLogger.error("❌ [Plan1] Không thể switch format: \(error)")
        }
    }

    // MARK: - Capture

    /// Chụp ảnh và lưu vào thư viện. Trả về JPEG Data để caller dùng tiếp (vd: gửi Telegram).
    /// Trả về nil nếu chụp thất bại.
    func captureAndSavePhoto() async -> Data? {
        guard photoOutput.connections.count > 0 else {
            self.errorMessage = "Camera chưa sẵn sàng để chụp ảnh."
            return nil
        }

        cameraLogger.debug("📸 Đang yêu cầu cảm biến chụp ảnh...")

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization

        if #available(iOS 16.0, *) {
            // maxPhotoDimensions đã được set trong setupPhotoOutput(), đọc lại để dùng.
            let maxDim = photoOutput.maxPhotoDimensions
            settings.maxPhotoDimensions = maxDim
            cameraLogger.debug("📸 Chụp ảnh tại \(maxDim.width)×\(maxDim.height)")
        } else {
            if photoOutput.isHighResolutionCaptureEnabled {
                settings.isHighResolutionPhotoEnabled = true
            }
        }

        return await withCheckedContinuation { continuation in
            self.captureContinuation = continuation
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension LiveKitCameraService: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            // Xác định kết quả: trả về Data nếu thành công, nil nếu lỗi.
            let result: Data?

            if let error = error {
                self.errorMessage = "Lỗi phần cứng chụp ảnh: \(error.localizedDescription)"
                result = nil
            } else if let fileData = photo.fileDataRepresentation() {
                // Lưu vào Photos — tạm comment, chỉ gửi Telegram
                 let image = UIImage(data: fileData)
                 UIImageWriteToSavedPhotosAlbum(
                     image!,
                     self,
                     #selector(handleSaveResult(_:didFinishSavingWithError:contextInfo:)),
                     nil
                 )
                result = fileData
            } else {
                self.errorMessage = "Lỗi xử lý file ảnh."
                result = nil
            }

            // Resume continuation — luôn chạy dù result là nil để tránh deadlock.
            self.captureContinuation?.resume(returning: result)
            self.captureContinuation = nil
        }
    }

    /// Callback sau khi UIImageWriteToSavedPhotosAlbum hoàn thành.
    /// Phải là @objc vì được gọi qua Objective-C runtime.
    @objc nonisolated private func handleSaveResult(
        _ image: UIImage,
        didFinishSavingWithError error: Error?,
        contextInfo: UnsafeRawPointer
    ) {
        Task { @MainActor in
            if let error = error {
                // Thường gặp: NSPhotoLibraryAddUsageDescription chưa được khai báo
                // hoặc user từ chối quyền truy cập thư viện ảnh.
                self.errorMessage = "Không thể lưu ảnh: \(error.localizedDescription)"
                cameraLogger.error("❌ Lưu ảnh thất bại: \(error)")
            } else {
                cameraLogger.info("✅ Đã lưu ảnh vào thư viện thành công")
            }
        }
    }
}

// MARK: - RoomDelegate

extension LiveKitCameraService: RoomDelegate {

    nonisolated func room(
        _ room: Room,
        didUpdateConnectionState state: ConnectionState,
        from oldState: ConnectionState
    ) {
        cameraLogger.debug("🔄 Camera connection: \(String(describing: oldState)) → \(String(describing: state))")
        if state == .disconnected {
            cameraLogger.warning("⚠️ Disconnected from room")
            Task { @MainActor in self.isConnected = false }
        }
    }

    // Được gọi khi local participant publish một track thành công.
    // Resume continuation để startPublishingCamera() không cần polling.
    nonisolated func room(_ room: Room,
                          localParticipant: LocalParticipant,
                          didPublishTrack publication: LocalTrackPublication) {
        guard let videoTrack = publication.track as? LocalVideoTrack else { return }
        cameraLogger.debug("📡 Local camera track published via delegate")
        Task { @MainActor in
            guard let cont = self.trackReadyContinuation else { return }
            cont.resume(returning: videoTrack)
            self.trackReadyContinuation = nil
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        let detail = error.map { String(describing: $0) } ?? "nil — server đóng kết nối không có lý do cụ thể"
        cameraLogger.error("❌ didFailToConnectWithError: \(detail)")
        Task { @MainActor in self.errorMessage = "Kết nối thất bại: \(detail)" }
    }

    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant?,
                          didReceiveData data: Data,
                          forTopic topic: String,
                          encryptionType: EncryptionType) {
        guard topic == "camera_control",
              let command = String(data: data, encoding: .utf8) else { return }
        cameraLogger.debug("📨 Nhận lệnh từ viewer: \(command)")
        if command == "switch_camera" {
            Task { @MainActor in self.switchCamera() }
        } else if command == "capture_photo" {
            Task { @MainActor in
                guard let data = await self.captureAndSavePhoto() else { return }
                await self.onPhotoReady?(data)
            }
        } else if command.hasPrefix("zoom:"),
                  let factor = Double(command.dropFirst(5)) {
            Task { @MainActor in self.setZoom(factor: CGFloat(factor)) }
        } else if command.hasPrefix("mic:") {
            let uid = String(command.dropFirst(4))
            Task { @MainActor in self.switchToMic(uid: uid) }
        } else if command == "request_mic_list" {
            Task { @MainActor in await self.sendMicList() }
        } else if command == "lock_screen" {
            Task { @MainActor in self.lockScreen() }
        } else if command == "allow_unlock" {
            Task { @MainActor in
                self.isUnlockAllowed = true
                cameraLogger.info("🔓 Viewer đã cho phép mở khoá")
            }
        } else if command == "revoke_unlock" {
            Task { @MainActor in
                self.isUnlockAllowed = false
                cameraLogger.info("🔒 Viewer huỷ quyền mở khoá")
            }
        } else if command == "mic_mute" {
            Task { @MainActor in await self.setMicrophone(enabled: false) }
        } else if command == "mic_unmute" {
            Task { @MainActor in await self.setMicrophone(enabled: true) }
        }
    }
}

// MARK: - Mic Selection

private struct MicPayload: Encodable {
    let uid: String
    let name: String
    let active: Bool
}

extension LiveKitCameraService {

    /// Gửi trạng thái mic (bật/tắt) về viewer để đồng bộ UI.
    func sendMicState() async {
        guard let room = room else { return }
        let command = "mic_state:\(isMicEnabled ? 1 : 0)"
        guard let data = command.data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
    }

    /// Đăng ký lắng nghe thay đổi audio route (cắm/tháo Bluetooth).
    /// Mỗi khi route thay đổi → push danh sách mic mới tới viewer.
    func setupRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendMicList()
            }
        }
    }

    /// Đọc danh sách input từ AVAudioSession và gửi tới viewer qua data channel.
    /// Chỉ gửi khi có ít nhất 1 thiết bị Bluetooth HFP (tức là có lựa chọn thực sự).
    func sendMicList() async {
        guard let room = room, isConnected else { return }

        let session = AVAudioSession.sharedInstance()
        let inputs   = session.availableInputs ?? []
        let activeUID = session.currentRoute.inputs.first?.uid ?? ""

        // Lấy tất cả: Bluetooth HFP + Built-in Mic
        let candidates = inputs.filter {
            $0.portType == .bluetoothHFP || $0.portType == .builtInMic
        }

        // Không gửi nếu chỉ có built-in (không có gì để chọn)
        guard candidates.contains(where: { $0.portType == .bluetoothHFP }) else { return }

        let payloads = candidates.map {
            MicPayload(uid: $0.uid, name: $0.portName, active: $0.uid == activeUID)
        }

        guard let jsonData = try? JSONEncoder().encode(payloads),
              let jsonStr  = String(data: jsonData, encoding: .utf8),
              let data     = "mic_list:\(jsonStr)".data(using: .utf8) else { return }

        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
        cameraLogger.debug("🎙️ Đã gửi mic list (\(candidates.count) thiết bị, active: \(activeUID))")
    }

    /// Chuyển sang mic có UID tương ứng, sau đó restart LiveKit audio track.
    func switchToMic(uid: String) {
        let session = AVAudioSession.sharedInstance()
        guard let input = session.availableInputs?.first(where: { $0.uid == uid }) else {
            cameraLogger.warning("⚠️ switchToMic: không tìm thấy UID \(uid)")
            return
        }
        do {
            try session.setPreferredInput(input)
            cameraLogger.info("🎙️ Đã chọn mic: \(input.portName)")
        } catch {
            cameraLogger.error("❌ setPreferredInput thất bại: \(error)")
            return
        }

        // Restart LiveKit mic track để WebRTC engine nhận nguồn âm mới.
        // Chỉ restart nếu mic đang bật; nếu tắt thì thay đổi sẽ có hiệu lực khi bật lại.
        guard isMicEnabled, let room = room else { return }
        Task {
            try? await room.localParticipant.setMicrophone(enabled: false)
            try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3 s buffer
            try? await room.localParticipant.setMicrophone(enabled: true)
            await sendMicList()  // Push trạng thái mới về viewer
        }
    }
}

// MARK: - Screen Lock

extension LiveKitCameraService {

    /// Khoá màn hình: tắt độ sáng, hiện overlay, thông báo viewer.
    func lockScreen() {
        guard !isScreenLocked else { return }
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        isScreenLocked = true
        Task { await sendLockState(true) }
        cameraLogger.info("🔒 Màn hình camera đã khoá")
    }

    /// Mở khoá màn hình: phục hồi độ sáng, ẩn overlay, thông báo viewer.
    /// Chỉ nên được gọi khi `isUnlockAllowed == true` (đã kiểm tra ở view).
    func unlockScreen() {
        guard isScreenLocked else { return }
        UIScreen.main.brightness = savedBrightness
        isScreenLocked = false
        isUnlockAllowed = false   // Reset — cần cho phép lại cho lần khoá tiếp theo
        Task { await sendLockState(false) }
        cameraLogger.info("🔓 Màn hình camera đã mở khoá")
    }

    /// Gửi trạng thái lock về viewer để đồng bộ UI.
    private func sendLockState(_ locked: Bool) async {
        guard let room = room else { return }
        let command = "lock_state:\(locked ? 1 : 0)"
        guard let data = command.data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
    }
}
