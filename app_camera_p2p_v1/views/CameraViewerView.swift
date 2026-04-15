//
//  CameraViewerView.swift
//  app_camera_p2p_v1
//
//  Created by Bach Xuan on 15/4/26.
//

//
//  CameraViewerView.swift
//  app_camera_p2p_v1
//

import SwiftUI
import LiveKit

struct CameraViewerView: View {
    
    @StateObject private var service: LiveKitViewerService
    @Environment(\.dismiss) private var dismiss
    
    init(serverURL: String, viewerToken: String) {
        _service = StateObject(wrappedValue: LiveKitViewerService(
            serverURL: serverURL,
            token: viewerToken,
            
        ))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // MARK: Video hoặc Waiting screen
            if let track = service.remoteVideoTrack {
                SwiftUIVideoView(track, layoutMode: .fit)
                    .ignoresSafeArea()
            } else {
                WaitingForCameraView(isConnected: service.isConnected)
            }
            
            // MARK: Top status bar + Bottom controls
            VStack {
                HStack {
                    // Status badge
                    StatusBadge(isConnected: service.isConnected, isReceiving: service.isReceiving)

                    Spacer()

                    // Disconnect button
                    Button {
                        Task {
                            await service.disconnect()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer()

                // MARK: Bottom controls (chỉ hiện khi đang nhận stream)
                if service.isReceiving {
                    HStack {
                        Spacer()
                        Button {
                            Task { await service.sendSwitchCameraCommand() }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 56, height: 56)
                                if service.isSwitchingCamera {
                                    ProgressView()
                                        .tint(.white)
                                        .scaleEffect(0.9)
                                } else {
                                    Image(systemName: "camera.rotate.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .disabled(service.isSwitchingCamera)
                        Spacer()
                    }
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            Task { await service.connect() }
        }
        .onDisappear {
            Task { await service.disconnect() }
        }
        .alert("Error", isPresented: .constant(service.errorMessage != nil)) {
            Button("OK") { service.errorMessage = nil }
        } message: {
            Text(service.errorMessage ?? "")
        }
    }
}

// MARK: - Waiting View
struct WaitingForCameraView: View {
    let isConnected: Bool
    
    @State private var pulse = false
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulse ? 1.3 : 1.0)
                    .opacity(pulse ? 0 : 0.5)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
                
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 90, height: 90)
                
                Image(systemName: isConnected ? "video.slash.fill" : "wifi.slash")
                    .font(.system(size: 36))
                    .foregroundColor(.white.opacity(0.6))
            }
            .onAppear { pulse = true }
            
            VStack(spacing: 8) {
                Text(isConnected ? "Đang chờ camera..." : "Đang kết nối...")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(isConnected
                     ? "Camera chưa phát hoặc đã tắt"
                     : "Đang kết nối tới server")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Status Badge
struct StatusBadge: View {
    let isConnected: Bool
    let isReceiving: Bool
    
    var label: String {
        if isReceiving { return "LIVE" }
        if isConnected { return "Chờ" }
        return "Offline"
    }
    
    var color: Color {
        if isReceiving { return .red }
        if isConnected { return .orange }
        return .gray
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
