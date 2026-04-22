//
//  ContentView.swift
//  app_camera_p2p_v1
//
//  Created by Bach Xuan on 14/4/26.
//

import SwiftUI
import LiveKit

struct ContentView: View {

    var body: some View {
        KeyEntryView(
            serverURL:   Config.LiveKit.serverURL,
            cameraToken: Config.LiveKit.cameraToken,
            viewerToken: Config.LiveKit.viewerToken
        )
    }
}

#Preview {
    ContentView()
}
