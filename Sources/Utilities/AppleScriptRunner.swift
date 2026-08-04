import Foundation

class AppleScriptRunner {
    static func run(_ script: String, timeout: TimeInterval = 4.0, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Write script to a temp file to avoid shell escaping issues with osascript -e
            let tempDir = FileManager.default.temporaryDirectory
            let scriptFile = tempDir.appendingPathComponent("playerstudio_\(UUID().uuidString).scpt")
            
            do {
                try script.write(to: scriptFile, atomically: true, encoding: .utf8)
            } catch {
                completion(.failure(error))
                return
            }
            
            defer {
                try? FileManager.default.removeItem(at: scriptFile)
            }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [scriptFile.path]
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            do {
                try process.run()

                let deadline = DispatchTime.now() + timeout
                let timeoutQueue = DispatchQueue.global(qos: .utility)
                var timedOut = false
                timeoutQueue.asyncAfter(deadline: deadline) {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }

                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                if timedOut {
                    completion(.failure(NSError(domain: "AppleScriptErrorDomain", code: -2, userInfo: [NSLocalizedDescriptionKey: "AppleScript timed out after \(timeout)s"])))
                    return
                }

                if process.terminationStatus == 0 {
                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    completion(.success(output))
                } else {
                    let errorMsg = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown AppleScript error"
                    let error = NSError(domain: "AppleScriptErrorDomain", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMsg])
                    completion(.failure(error))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}
