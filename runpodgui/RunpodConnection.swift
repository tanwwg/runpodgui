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
    var monitorTask: Task<Void, any Error>?
    
    var startTerminal = true
    var terminalCmd: String?
    
    var isMonitor: Bool { monitorTask != nil }
    
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
            if let bid = config.bid {
                _ = try exec(command: "/opt/homebrew/bin/runpodctl", args: [
                    "start", "pod", config.podId, "--bid", bid
                ])
            } else {
                _ = try await query(query: "mutation podResume($podId: String!) { podResume(input: {podId: $podId}) { id costPerHr desiredStatus lastStatusChange } }", vars: [ "podId": config.podId ])
            }
            
            while true {
                let pods = try await getPods()
                guard let pod = pods.first(where: { $0.id == config.podId }) else { throw RunpodError.podNotFound }
                if let r = pod.runtime, let pub = r.ports.first(where: { $0.isIpPublic }) {
                    self.status = .started(ip: pub.ip, port: pub.publicPort)
                    
                    // wait 3 seconds for SSH to start up
                    try await Task.sleep(for: .seconds(3))
                    
                    startMonitor(ip: pub.ip, port: pub.publicPort)
                    
                    self.terminalCmd = "ssh -L 127.0.0.1:8188:127.0.0.1:8188 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@\(pub.ip) -p \(pub.publicPort)"
                    if startTerminal {
                        try openTerminalAndRunCommand(command: terminalCmd ?? "")
                    }
                    
                    return
                } else {
                    try await Task.sleep(for: .seconds(1))
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
        
        self.monitorTask?.cancel()
        self.monitorTask = nil
        self.terminalCmd = nil
        self.startIdleTime = nil
        self.idleMinutes = 0
        self.lastGpuUsage = nil
    }
    
    /// Returns true if we should end the monitor
    func reportGpuUsage(usage: Int) async throws -> Bool {
        let now = Date.now
        
        self.lastGpuUsage = usage
        if usage < config.idleThreshold {
            if self.startIdleTime == nil {
                self.startIdleTime = now
            }
            self.idleMinutes = Int(now.timeIntervalSince(self.startIdleTime!) / 60)
            if idleMinutes > config.idleTimeMins {
                try await stopPod()
                return true
            }
        } else {
            self.startIdleTime = nil
            self.idleMinutes = 0
        }
        
        return false
    }
    
    func startMonitor(ip: String, port: Int) {
        self.monitorTask = Task.detached {
            while true {
                guard let usage = try? checkGpuUsage(ip: ip, port: port) else { continue }
                
                if try await self.reportGpuUsage(usage: usage) {
                    break
                }
                
                try await Task.sleep(for: .seconds(60))
            }
        }
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


func checkGpuUsage(ip: String, port: Int) throws -> Int {
    let str = try runSSHCommand(ip: ip, port: port, command: "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits")
    if let usage = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return usage
    } else {
        throw RunpodError.unknownError
    }
}

func exec(command: String, args: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    
    print("exec \(command) \(args.joined(separator: " "))")
    
    // Configure the process
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let str = String(data: data, encoding: .utf8) ?? ""
    print(str)
    return str

}

func runSSHCommand(ip: String, port: Int, command: String) throws -> String {
//    guard case let .started(ip, port) = status else {
//        throw RunpodError.unknownError
//    }
    return try exec(command: "/usr/bin/ssh", args: [
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "root@\(ip)", "-p", "\(port)",
        command
    ])
}
