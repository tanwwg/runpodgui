//
//  ContentView.swift
//  runpodgui
//
//  Created by Tan Thor Jen on 18/1/25.
//

import SwiftUI



struct ContentView: View {
    @Binding var document: RunpodDoc
    
    @State var conn: RunpodConnection?

    var body: some View {
        VStack {
            if let c = conn {
                ConnectionView(conn: c)
            }
        }
        .onAppear {
            if conn == nil {
                conn = RunpodConnection(config: document.config)
            }
        }
    }
}

struct ConnectionView: View {
    var conn: RunpodConnection
    
    @State var lastError: String? = nil
    
    var body: some View {
        VStack {
            Text(conn.config.podId)
            Text(String(describing: conn.status))
            Text("Monitoring: \(conn.isMonitor)")
            Text("GPU Usage: \(conn.lastGpuUsage ?? -1)")
            Text("Idle minutes: \(conn.idleMinutes)")
            if let err = lastError {
                Text(err)
                    .foregroundStyle(Color.red)
            }
            
            Button(action: { Task {
                do {
                    try await conn.startPod()
                } catch {
                    lastError = error.localizedDescription
                }
            } }) {
                Text("Start")
            }
            
            if conn.isStarted {
                Button(action: { Task {
                    do {
                        try await conn.stopPod()
                    } catch {
                        lastError = error.localizedDescription
                    }
                } }) {
                    Text("Stop")
                }
            }
        }
    }
}
