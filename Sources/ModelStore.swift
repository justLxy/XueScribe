import Foundation
import CryptoKit

struct LocalModelPaths: Sendable {
    let asr: URL
    let translation: URL
}

struct ModelDownloadUpdate: Sendable {
    let modelName: String
    let phase: String
    let completedBytes: Int64
    let totalBytes: Int64
    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1,max(0,Double(completedBytes) / Double(totalBytes)))
    }
}

enum ModelStoreError: LocalizedError {
    case invalidResponse(String)
    case insufficientSpace(required: Int64, available: Int64)
    case sizeMismatch(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let name): return "下载 \(name) 失败：服务器响应异常。"
        case .insufficientSpace(let required,let available):
            return "磁盘空间不足：模型还需要约 \(Self.size(required))，当前可用约 \(Self.size(available))。"
        case .sizeMismatch(let name): return "\(name) 下载不完整，请重新开始下载。"
        case .checksumMismatch(let name): return "\(name) 校验失败，文件可能损坏，请重新下载。"
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)
    }
}

actor ModelStore {
    struct Descriptor: Sendable {
        enum Kind: Sendable { case asr, translation }
        let kind: Kind
        let displayName: String
        let fileName: String
        let url: URL
        let bytes: Int64
        let sha256: String
    }

    static let catalog: [Descriptor] = [
        Descriptor(
            kind:.asr,
            displayName:"Nemotron English 0.6B",
            fileName:"nemotron-speech-streaming-en-0.6b.q8_0.gguf",
            url:URL(string:"https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b/resolve/ebe59e5a817142986528bbbee5dba8db7b38ed50/nemotron-speech-streaming-en-0.6b.q8_0.gguf")!,
            bytes:699_872_960,
            sha256:"d9a01898d2a611c8764e23a1c2f45e70bbd5a425dc4de93692ac951dd603812d"
        ),
        Descriptor(
            kind:.translation,
            displayName:"Hy-MT2 1.8B Q4_K_M",
            fileName:"Hy-MT2-1.8B-Q4_K_M.gguf",
            url:URL(string:"https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/a0c709d9fac510f2c807aa3af52872340dc37a4a/Hy-MT2-1.8B-Q4_K_M.gguf")!,
            bytes:1_133_080_448,
            sha256:"dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
        )
    ]
    static let totalDownloadBytes = catalog.reduce(Int64(0)) { $0 + $1.bytes }

    private let directory: URL
    init(directory: URL) { self.directory = directory }

    nonisolated static func modelsAreReady(in directory: URL) -> Bool {
        catalog.allSatisfy { descriptor in
            let file = directory.appendingPathComponent(descriptor.fileName)
            let marker = file.appendingPathExtension("sha256")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath:file.path),
                  (attributes[.size] as? NSNumber)?.int64Value == descriptor.bytes,
                  let saved = try? String(contentsOf:marker,encoding:.utf8)
                    .trimmingCharacters(in:.whitespacesAndNewlines) else { return false }
            return saved == descriptor.sha256
        }
    }

    func ensureModels(progress: @escaping @Sendable (ModelDownloadUpdate) -> Void) async throws -> LocalModelPaths {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var completed = Int64(0)
        for descriptor in Self.catalog {
            try Task.checkCancellation()
            let file = directory.appendingPathComponent(descriptor.fileName)
            if try validateExisting(file,descriptor:descriptor,progress:progress,completedBefore:completed) {
                completed += descriptor.bytes
                progress(ModelDownloadUpdate(modelName:descriptor.displayName,phase:"已就绪",completedBytes:completed,totalBytes:Self.totalDownloadBytes))
                continue
            }
            try checkDiskSpace(required:descriptor.bytes)
            let staging = directory.appendingPathComponent(".\(descriptor.fileName).download")
            try? FileManager.default.removeItem(at:staging)
            let completedBefore = completed
            let operation = ModelDownloadOperation(source:descriptor.url,destination:staging) { received in
                progress(ModelDownloadUpdate(modelName:descriptor.displayName,phase:"下载中",completedBytes:completedBefore + min(received,descriptor.bytes),totalBytes:Self.totalDownloadBytes))
            }
            do {
                try await operation.run()
                progress(ModelDownloadUpdate(modelName:descriptor.displayName,phase:"正在校验",completedBytes:completed + descriptor.bytes,totalBytes:Self.totalDownloadBytes))
                try verify(staging,descriptor:descriptor)
                if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
                try FileManager.default.moveItem(at:staging,to:file)
                try Data((descriptor.sha256 + "\n").utf8).write(to:file.appendingPathExtension("sha256"),options:.atomic)
            } catch {
                try? FileManager.default.removeItem(at:staging)
                throw error
            }
            completed += descriptor.bytes
        }
        let asr = Self.catalog.first { $0.kind == .asr }!
        let translation = Self.catalog.first { $0.kind == .translation }!
        return LocalModelPaths(
            asr:directory.appendingPathComponent(asr.fileName),
            translation:directory.appendingPathComponent(translation.fileName)
        )
    }

    private func validateExisting(_ file: URL, descriptor: Descriptor,
                                  progress: @escaping @Sendable (ModelDownloadUpdate) -> Void,
                                  completedBefore: Int64) throws -> Bool {
        guard FileManager.default.fileExists(atPath:file.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == descriptor.bytes else { return false }
        let marker = file.appendingPathExtension("sha256")
        if let saved = try? String(contentsOf:marker,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines),
           saved == descriptor.sha256 { return true }
        progress(ModelDownloadUpdate(modelName:descriptor.displayName,phase:"正在校验已有文件",completedBytes:completedBefore,totalBytes:Self.totalDownloadBytes))
        do {
            try verify(file,descriptor:descriptor)
            try Data((descriptor.sha256 + "\n").utf8).write(to:marker,options:.atomic)
            return true
        } catch ModelStoreError.checksumMismatch {
            try? FileManager.default.removeItem(at:file)
            try? FileManager.default.removeItem(at:marker)
            return false
        }
    }

    private func verify(_ file: URL, descriptor: Descriptor) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == descriptor.bytes else {
            throw ModelStoreError.sizeMismatch(descriptor.displayName)
        }
        let handle = try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount:4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data:chunk)
        }
        let actual = digest.finalize().map { String(format:"%02x",$0) }.joined()
        guard actual == descriptor.sha256 else { throw ModelStoreError.checksumMismatch(descriptor.displayName) }
    }

    private func checkDiskSpace(required: Int64) throws {
        let values = try directory.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let reserve = Int64(256 * 1024 * 1024)
        if available < required + reserve { throw ModelStoreError.insufficientSpace(required:required + reserve,available:available) }
    }
}

private final class ModelDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void,Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var movedFile = false
    private var cancelled = false
    private var completed = false
    private var reportedBytes: Int64 = 0
    /// didWriteData fires every few KB; each report becomes a main-actor task and a
    /// SwiftUI update, so report only every 4 MiB (~450 updates for 1.8 GB).
    private static let progressStep: Int64 = 4 * 1024 * 1024

    init(source: URL, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.source = source; self.destination = destination; self.progress = progress
    }

    func run() async throws {
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock(); continuation.resume(throwing:CancellationError()); return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration:configuration,delegate:self,delegateQueue:nil)
                self.session = session
                let task = session.downloadTask(with:source)
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Delegate callbacks are serialized on the session's delegate queue.
        guard totalBytesWritten - reportedBytes >= Self.progressStep
                || totalBytesWritten == totalBytesExpectedToWrite else { return }
        reportedBytes = totalBytesWritten
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw ModelStoreError.invalidResponse(destination.lastPathComponent)
            }
            if FileManager.default.fileExists(atPath:destination.path) { try FileManager.default.removeItem(at:destination) }
            try FileManager.default.moveItem(at:location,to:destination)
            lock.lock(); movedFile = true; lock.unlock()
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let moved = movedFile; let wasCancelled = cancelled; lock.unlock()
        if let error { finish(.failure(wasCancelled ? CancellationError() : error)); return }
        finish(moved ? .success(()) : .failure(ModelStoreError.invalidResponse(destination.lastPathComponent)))
    }

    private func finish(_ result: Result<Void,Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; task = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with:result)
    }
}
