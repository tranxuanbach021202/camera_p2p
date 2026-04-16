//
//  LiveKitViewerService.swift
//  app_camera_p2p_v1
//

import LiveKit
import AVFoundation
import Combine
import SwiftUI
import os

private let viewerLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.camera_p2p", category: "ViewerService")

@MainActor
class LiveKitViewerService: ObservableObject {
    
    @Published var isConnected = false
    @Published var isReceiving = false
    @Published var isSwitchingCamera = false
    @Published var isCapturing = false
    @Published var zoomFactor: CGFloat = 1.0
    let maxZoomFactor: CGFloat = 8.0
    @Published var isSpeakerEnabled: Bool = true
    @Published var errorMessage: String?
    @Published private(set) var remoteVideoTrack: VideoTrack?
    
    private var room: Room?
    let serverURL: String
    let token: String
    
    init(serverURL: String, token: String) {
        self.serverURL = serverURL
        self.token = token
    }
    
    func connect() async {
        do {
            let newRoom = Room(delegate: self)
            
            // autoSubscribe = true: SDK sẽ tự động subscribe vào các track (bao gồm các track đã có sẵn từ trước)
            let connectOptions = ConnectOptions(
                autoSubscribe: true
            )
            
            try await newRoom.connect(
                url: serverURL,
                token: token,
                connectOptions: connectOptions
            )
            
            self.room = newRoom
            self.isConnected = true
            viewerLogger.info("✅ Viewer connected to room")

            // Route audio ra loa ngoài (mặc định iOS dùng tai nghe/earpiece)
            routeAudioToSpeaker(isSpeakerEnabled)

            // Lấy track ngay lập tức nếu camera đã phát trước khi viewer vào
            checkAndAssignExistingTrack(in: newRoom)
            
        } catch {
            errorMessage = "Connect failed: \(error.localizedDescription)"
            viewerLogger.error("❌ Viewer connect error: \(error)")
        }
    }
    
    func sendSwitchCameraCommand() async {
        guard let room = room, isConnected, !isSwitchingCamera else { return }
        do {
            isSwitchingCamera = true
            let data = "switch_camera".data(using: .utf8)!
            try await room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(topic: "camera_control", reliable: true)
            )
            viewerLogger.debug("📤 Đã gửi lệnh switch_camera")
            // Cooldown 2.5s để tránh gửi liên tục trong khi camera đang xoay
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            isSwitchingCamera = false
        } catch {
            isSwitchingCamera = false
            errorMessage = "Không gửi được lệnh: \(error.localizedDescription)"
        }
    }

    func toggleSpeaker() {
        isSpeakerEnabled.toggle()
        routeAudioToSpeaker(isSpeakerEnabled)
    }

    private func routeAudioToSpeaker(_ speaker: Bool) {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
            viewerLogger.info("🔊 Audio route → \(speaker ? "speaker" : "default")")
        } catch {
            viewerLogger.error("❌ Audio route error: \(error)")
        }
    }

    func sendZoomCommand(factor: CGFloat) async {
        guard let room = room, isConnected else { return }
        let clamped = min(max(factor, 1.0), maxZoomFactor)
        zoomFactor = clamped
        let command = String(format: "zoom:%.3f", clamped)
        guard let data = command.data(using: .utf8) else { return }
        // reliable: false — zoom là real-time, ưu tiên tốc độ hơn đảm bảo giao hàng
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: false)
        )
    }

    func sendCapturePhotoCommand() async {
        guard let room = room, isConnected, !isCapturing else { return }
        do {
            isCapturing = true
            let data = "capture_photo".data(using: .utf8)!
            try await room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(topic: "camera_control", reliable: true)
            )
            viewerLogger.debug("📤 Đã gửi lệnh capture_photo")
            // Cooldown 3s — đủ để camera hoàn tất chụp và lưu ảnh
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            isCapturing = false
        } catch {
            isCapturing = false
            errorMessage = "Không gửi được lệnh chụp ảnh: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        await room?.disconnect()
        remoteVideoTrack = nil
        isConnected = false
        isReceiving = false
        room = nil
        viewerLogger.info("🔌 Viewer disconnected")
    }
    
    // Hàm này quét xem trong room đã có video track nào chưa để hiển thị luôn
    private func checkAndAssignExistingTrack(in room: Room) {
        for participant in room.remoteParticipants.values {
            for publication in participant.videoTracks {
                if let track = publication.track as? VideoTrack {
                    self.remoteVideoTrack = track
                    self.isReceiving = true
                    viewerLogger.debug("🎥 Found existing video track and assigned")
                    return // Chỉ lấy track đầu tiên
                }
            }
        }
    }
}

// MARK: - RoomDelegate
extension LiveKitViewerService: RoomDelegate {

    nonisolated func room(_ room: Room,
                          didUpdateConnectionState state: ConnectionState,
                          from oldState: ConnectionState) {
        viewerLogger.debug("🔄 Viewer connection: \(String(describing: oldState)) → \(String(describing: state))")
        if state == .disconnected {
            Task { @MainActor in
                self.isConnected = false
                self.isReceiving = false
            }
        }
    }
    
    // [ĐÃ SỬA] - Dùng didPublishTrack
    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didPublishTrack publication: RemoteTrackPublication) {
        viewerLogger.debug("📡 Remote track published: \(String(describing: publication.kind))")
    }
    
    // LiveKit 2.x: delegate không có tham số track, lấy qua publication.track
    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didSubscribeTrack publication: RemoteTrackPublication) {
        guard let videoTrack = publication.track as? VideoTrack else { return }
        viewerLogger.info("🎥 Video track subscribed and ready")
        Task { @MainActor in
            self.remoteVideoTrack = videoTrack
            self.isReceiving = true
        }
    }

    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didUnsubscribeTrack publication: RemoteTrackPublication) {
        viewerLogger.info("📴 Remote track unsubscribed")
        Task { @MainActor in
            if publication.kind == .video {
                self.remoteVideoTrack = nil
                self.isReceiving = false
            }
        }
    }

    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didUnpublishTrack publication: RemoteTrackPublication) {
        viewerLogger.info("📴 Remote track unpublished")
        Task { @MainActor in
            if publication.kind == .video {
                self.remoteVideoTrack = nil
                self.isReceiving = false
            }
        }
    }
    
    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        let msg = error?.localizedDescription ?? "Unknown error"
        Task { @MainActor in
            self.errorMessage = "Failed to connect: \(msg)"
        }
    }
}
