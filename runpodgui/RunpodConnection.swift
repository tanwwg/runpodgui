//
//  RunpodConnection.swift
//  runpodgui
//
//  Created by Tan Thor Jen on 18/1/25.
//

import SwiftUI

struct RunpodQuery: Codable {
    var query: String
    var variables: [String:String]
}

enum RunpodError: Error {
    case invalidResponse(message: String)
    case unknownError
    case podNotFound
}

enum RunpodStatus {
    case notStarted
    case starting
    case started(ip: String, port: Int)
}

@MainActor @Observable class RunpodConnection {
        
    var config: RunpodConfig
    var status = RunpodStatus.notStarted
    
    var lastGpuUsage: Int?
    var startIdleTime: Date?
    var idleMinutes = 0
    var isMonitor = false
    
    init(config: RunpodConfig) {
        self.config = config
    }
    
    var isStarted: Bool {
        guard case .started(_, _) = status else { return false }
        return true
    }
    
    func query(query: String, vars: [String:String]? = nil) async throws -> Data {
        guard let url = URL(string: "\(config.apiHost)?api_key=\(config.apiKey)") else { throw RunpodError.unknownError }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let podquery = RunpodQuery(query: query, variables: vars ?? [:])
        request.httpBody = try JSONEncoder().encode(podquery)
        
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let httpResponse = resp as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw RunpodError.invalidResponse(message: String(data: data, encoding: .utf8) ?? "")
        }
        print(String(data: data, encoding: .utf8) ?? "")
        return data
    }

    func getPods() async throws -> [Pod] {
        let data = try await query(query: "query myPods { myself { pods { id containerDiskInGb costPerHr desiredStatus dockerArgs dockerId env gpuCount imageName lastStatusChange machineId memoryInGb name podType port ports uptimeSeconds vcpuCount volumeInGb volumeMountPath machine { gpuDisplayName location } runtime { ports { ip isIpPublic privatePort publicPort PortType: type } } } } }")

        let getResp = try JSONDecoder().decode(RunpodGetResponse.self, from: data)
        return getResp.data.myself.pods
    }
    
    func startPod() async throws {
        status = .starting
        do {
            _ = try await query(query: "mutation podResume($podId: String!) { podResume(input: {podId: $podId}) { id costPerHr desiredStatus lastStatusChange } }", vars: [ "podId": config.podId ])
            
            while true {
                let pods = try await getPods()
                guard let pod = pods.first(where: { $0.id == config.podId }) else { throw RunpodError.podNotFound }
                if let r = pod.runtime, let pub = r.ports.first(where: { $0.isIpPublic }) {
                    self.status = .started(ip: pub.ip, port: pub.publicPort)
                    
                    startMonitor()
                    try openTerminalAndRunCommand(command: "ssh -L 127.0.0.1:8188:127.0.0.1:8188 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@\(pub.ip) -p \(pub.publicPort)")
                    
                    return
                }
            }
            
        } catch {
            status = .notStarted
            throw error
        }
    }
    
    func stopPod() async throws {
        _ = try await query(query: "mutation stopPod($podId: String!) { podStop(input: {podId: $podId}) { id desiredStatus lastStatusChange } }", vars: [ "podId": config.podId ])
        self.status = .notStarted
    }
    
    func startMonitor() {
        Task {
            self.isMonitor = true
            while true {
                do {
                    if !self.isStarted { break }
                    
                    let usage = try checkGpuUsage()
                    let now = Date.now
                    self.lastGpuUsage = usage
                    if usage < config.idleThreshold {
                        if self.startIdleTime == nil {
                            self.startIdleTime = now
                        }
                        self.idleMinutes = Int(now.timeIntervalSince(self.startIdleTime!) / 60)
                        if idleMinutes > config.idleTimeMins {
                            try await stopPod()
                            break
                        }
                    } else {
                        self.startIdleTime = nil
                        self.idleMinutes = 0
                    }
                    
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    print("Unable to check usage")
                }
            }
            self.isMonitor = false
        }
    }
    
    func checkGpuUsage() throws -> Int {
        let str = try runSSHCommand(command: "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits")
        if let usage = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return usage
        } else {
            throw RunpodError.unknownError
        }
    }
    
    func runSSHCommand(command: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        guard case let .started(ip, port) = status else {
            throw RunpodError.unknownError
        }

        // Configure the process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "root@\(ip)", "-p", "\(port)",
            command]
        process.standardOutput = pipe
//        process.standardError = pipe

        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8) ?? ""
        print(str)
        return str
    }
    
    func openTerminalAndRunCommand(command: String) throws {
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: appleScript) else { throw RunpodError.unknownError }
        script.executeAndReturnError(&error)
        if let err = error {
            print("AppleScript Error: \(err)")
            throw RunpodError.unknownError
        }
    }

}


struct RunpodGetResponse: Codable {
    let data: DataContainer
}

struct DataContainer: Codable {
    let myself: Myself
}

struct Myself: Codable {
    let pods: [Pod]
}

struct Pod: Codable {
    let id: String
    let containerDiskInGb: Int
    let costPerHr: Double
    let desiredStatus: String
    let dockerArgs: String
    let dockerId: String?
    let env: [String]
    let gpuCount: Int
    let imageName: String
    let lastStatusChange: String
    let machineId: String
    let memoryInGb: Int
    let name: String
    let podType: String
    let port: Int?
    let ports: String
    let uptimeSeconds: Int
    let vcpuCount: Int
    let volumeInGb: Int
    let volumeMountPath: String
    let machine: Machine
    let runtime: Runtime?
}

struct Machine: Codable {
    let gpuDisplayName: String
    let location: String
}

struct Runtime: Codable {
    let ports: [Port]
}

struct Port: Codable {
    let ip: String
    let isIpPublic: Bool
    let privatePort: Int
    let publicPort: Int
    let PortType: String
}
