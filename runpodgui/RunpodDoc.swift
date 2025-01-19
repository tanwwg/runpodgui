//
//  runpodguiDocument.swift
//  runpodgui
//
//  Created by Tan Thor Jen on 18/1/25.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var exampleText: UTType {
        UTType(importedAs: "com.example.plain-text")
    }
}

struct RunpodConfig: Codable {
    var apiHost: String = ""
    var apiKey: String = ""
    var podId: String = ""
    var idleTimeMins = 60
    var idleThreshold = 10
    
    var bid: String?
}


struct RunpodDoc: FileDocument {
    var config: RunpodConfig

    static var readableContentTypes: [UTType] { [.exampleText] }
    
    init() {
        config = RunpodConfig()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let config = try? JSONDecoder().decode(RunpodConfig.self, from: data)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.config = config
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}
