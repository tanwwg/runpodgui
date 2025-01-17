//
//  ContentView.swift
//  runpodgui
//
//  Created by Tan Thor Jen on 18/1/25.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: runpodguiDocument

    var body: some View {
        TextEditor(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(runpodguiDocument()))
}
