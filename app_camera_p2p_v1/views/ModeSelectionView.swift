//
//  ModeSelectionView.swift
//  app_camera_p2p_v1
//
//  Created by Bach Xuan on 15/4/26.
//

//
//  ModeSelectionView.swift
//  app_camera_p2p_v1
//

import SwiftUI

struct ModeSelectionView: View {

    let serverURL: String
    let cameraToken: String
    let viewerToken: String
    // let telegramBotToken: String
    // let telegramChatId: String
    
    @State private var selectedMode: AppMode? = nil
    
    enum AppMode {
        case camera, viewer
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [Color.black, Color(white: 0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 48) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white)
                        
                        Text("Camera P2P")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("Chọn chế độ để bắt đầu")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    // Mode Buttons
                    VStack(spacing: 16) {
                        ModeButton(
                            icon: "camera.fill",
                            title: "Camera",
                            subtitle: "Phát trực tiếp từ camera",
                            color: .blue
                        ) {
                            selectedMode = .camera
                        }
                        
                        ModeButton(
                            icon: "eye.fill",
                            title: "Viewer",
                            subtitle: "Xem camera từ xa",
                            color: .green
                        ) {
                            selectedMode = .viewer
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }
            .navigationDestination(item: $selectedMode) { mode in
                switch mode {
                case .camera:
                    CameraPublisherView(
                        serverURL: serverURL,
                        cameraToken: cameraToken
                    )
                    .navigationBarBackButtonHidden(false)
                    
                case .viewer:
                    CameraViewerView(
                        serverURL: serverURL,
                        viewerToken: viewerToken
                    )
                    .navigationBarBackButtonHidden(false)
                }
            }
        }
    }
}

// MARK: - Mode Button Component
struct ModeButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                // Icon
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundColor(color)
                }
                
                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(color.opacity(0.3), lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Preview helper
extension ModeSelectionView.AppMode: Hashable {}
