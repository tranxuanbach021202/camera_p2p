//
//  LiveKitViewerService.swift
//  app_camera_p2p_v1
//

import LiveKit
import Combine
import SwiftUI
import os

private let viewerLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.camera_p2p", category: "ViewerService")

@MainActor
class LiveKitViewerService: ObservableObject {
    
    @Published var isConnected = false
    @Published var isReceiving = false
    @Published var isSwitchingCamera = false
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
