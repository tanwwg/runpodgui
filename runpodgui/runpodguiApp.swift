//
//  runpodguiApp.swift
//  runpodgui
//
//  Created by Tan Thor Jen on 18/1/25.
//

import SwiftUI

@main
struct runpodguiApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: RunpodDoc()) { file in
            ContentView(document: file.$document)
        }
    }
}
