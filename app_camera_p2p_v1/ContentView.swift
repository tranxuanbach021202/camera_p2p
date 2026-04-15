//
//  ContentView.swift
//  app_camera_p2p_v1
//
//  Created by Bach Xuan on 14/4/26.
//

import SwiftUI
import LiveKit

struct ContentView: View {
    
    private let serverURL = "Test"
       private let cameraToken = "Test"
       private let viewerToken = "Test"
       
    
    var body: some View {
        ModeSelectionView(
                    serverURL: serverURL,
                    cameraToken: cameraToken,
                    viewerToken: viewerToken
                )
    }
}

#Preview {
    ContentView()
}
