//
//  ContentView.swift
//  app_camera_p2p_v1
//
//  Created by Bach Xuan on 14/4/26.
//

import SwiftUI
import LiveKit

struct ContentView: View {
    
    private let serverURL = "wss://cameratest-vu5mpv41.livekit.cloud"
    private let cameraToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NzYzMDc1OTksImlkZW50aXR5IjoieHVhbmJhY2hfMSIsImlzcyI6IkFQSUhGR252UFNRTXJxViIsIm5hbWUiOiJ4dWFuYmFjaF8xIiwibmJmIjoxNzc2MjIxMTk5LCJzdWIiOiJ4dWFuYmFjaF8xIiwidmlkZW8iOnsicm9vbSI6ImFsZnJlZC1yb29tIiwicm9vbUpvaW4iOnRydWV9fQ.cTB7FgZmmPcDvcZisLcQvqCUihLClsfbhRGNy17kcDo"
    private let viewerToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NzYzMDc4MDgsImlkZW50aXR5IjoieHVhbmJhY2hfMiIsImlzcyI6IkFQSUhGR252UFNRTXJxViIsIm5hbWUiOiJ4dWFuYmFjaF8yIiwibmJmIjoxNzc2MjIxNDA4LCJzdWIiOiJ4dWFuYmFjaF8yIiwidmlkZW8iOnsicm9vbSI6ImFsZnJlZC1yb29tIiwicm9vbUpvaW4iOnRydWV9fQ.En47PDkd1RtqARbLHXkYK4l4orePL870UD7scrIp5zc"

    // MARK: - Telegram Config
    // Điền token và chat ID của bot Telegram vào đây.
    // Lấy botToken: nhắn /newbot cho @BotFather trên Telegram.
    // Lấy chatId: nhắn tin cho bot rồi gọi https://api.telegram.org/bot<TOKEN>/getUpdates
    private let telegramBotToken = "8431346383:AAGm-_nOZn8abnYQSNYk8qhPiIDr2UQ54OI"
    private let telegramChatId   = "7613533018"

    var body: some View {
        ModeSelectionView(
            serverURL: serverURL,
            cameraToken: cameraToken,
            viewerToken: viewerToken,
            telegramBotToken: telegramBotToken,
            telegramChatId: telegramChatId
        )
    }
}

#Preview {
    ContentView()
}
