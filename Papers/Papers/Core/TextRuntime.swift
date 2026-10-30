import Foundation
#if canImport(ChatEngineC)
import ChatEngineC   // the macOS test harness; the app sees ChatEngine.h through its bridging header
#endif

/// Anything that answers chat messages with text: the app's work queue (which moves the model between the GPU
/// and the CPU) and the macOS test harness both provide one, so the paper and transcript pipelines are shared.
protocol TextWriter {
    func write(_ messages: [TextRuntime.Message], maxTokens: Int32, temperature: Float) async throws -> String
}

enum EngineError: LocalizedError {
    case load(String)
    case inference(String)

    var errorDescription: String? {
        switch self {
        case .load(let msg): return msg
        case .inference(let msg): return msg
        }
    }
}

/// Owns one text-only chat model (Qwen3.5) and runs every call on a private serial queue.
/// It can move between the GPU and the CPU, because iOS refuses GPU work while the app is in the background.
final class TextRuntime: @unchecked Sendable {
    struct Message {
        let role: String      // "system", "user" or "assistant"
        let content: String
    }

    private let queue = DispatchQueue(label: "papers.text.engine", qos: .userInitiated)
    private let engine: OpaquePointer
    private var closed = false

    private init(engine: OpaquePointer) {
        self.engine = engine
    }

    deinit {
        let engine = self.engine
        let closed = self.closed
        queue.async { if !closed { chat_engine_free(engine) } }
    }

    /// `streamWeights`: run on the CPU only and read the weights from the memory-mapped file, for a model larger
    /// than the memory iOS gives the app (slower, but it fits).
    static func load(modelPath: String, contextSize: Int32, useGPU: Bool, streamWeights: Bool = false) async throws -> TextRuntime {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err = [CChar](repeating: 0, count: 512)
                #if targetEnvironment(simulator)
                let gpu = false
                #else
                let gpu = useGPU
                #endif
                if let engine = chat_engine_create(modelPath, contextSize, gpu, streamWeights, &err, err.count) {
                    cont.resume(returning: TextRuntime(engine: engine))
                } else if gpu, let engine = chat_engine_create(modelPath, contextSize, false, streamWeights, &err, err.count) {
                    cont.resume(returning: TextRuntime(engine: engine))
                } else {
                    cont.resume(throwing: EngineError.load(String(cString: err)))
                }
            }
        }
    }

    /// Frees the model now, after any running call.
    func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.closed {
                    chat_engine_free(self.engine)
                    self.closed = true
                }
                cont.resume()
            }
        }
    }

    /// Moves the model to the GPU or the CPU (a reload of a few seconds) when it is not already there.
    func setGPU(_ useGPU: Bool) async throws {
        #if targetEnvironment(simulator)
        return
        #else
        let engine = self.engine
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if chat_engine_set_gpu(engine, useGPU) || chat_engine_set_gpu(engine, !useGPU) {
                    cont.resume()
                } else {
                    cont.resume(throwing: EngineError.load(String(cString: chat_engine_last_error(engine))))
                }
            }
        }
        #endif
    }

    /// The prompt for `messages` in the model's own chat format, ending with the assistant header.
    /// Thinking is switched off (an empty think block) for models whose template has one.
    func prompt(_ messages: [Message]) async throws -> String {
        let engine = self.engine
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let roles = messages.map { strdup($0.role) }
                let contents = messages.map { strdup($0.content) }
                defer { (roles + contents).forEach { free($0) } }
                var rolePtrs: [UnsafePointer<CChar>?] = roles.map { UnsafePointer($0) }
                var contentPtrs: [UnsafePointer<CChar>?] = contents.map { UnsafePointer($0) }

                var usesThink = false
                var size = Int32(messages.reduce(0) { $0 + $1.content.utf8.count } * 2 + 1024)
                var buf = [CChar](repeating: 0, count: Int(size))
                var n = chat_engine_render(engine, &rolePtrs, &contentPtrs, Int32(messages.count), &buf, size, &usesThink)
                if n > size {
                    size = n + 1
                    buf = [CChar](repeating: 0, count: Int(size))
                    n = chat_engine_render(engine, &rolePtrs, &contentPtrs, Int32(messages.count), &buf, size, &usesThink)
                }
                guard n > 0 else {
                    cont.resume(throwing: EngineError.inference("The summary model's chat template is not supported."))
                    return
                }
                let text = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                cont.resume(returning: text + (usesThink ? "<think>\n\n</think>\n\n" : ""))
            }
        }
    }

    /// Streams text pieces to `onText`; return false from it to stop early.
    func generate(prompt: String, maxTokens: Int32, temperature: Float,
                  onText: @escaping @Sendable (String) -> Bool) async throws {
        let box = Unmanaged.passRetained(TextPieceSink(onText)).toOpaque()
        defer { Unmanaged<TextPieceSink>.fromOpaque(box).release() }
        let engine = self.engine

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let callback: chat_text_callback = { piece, userData in
                    guard let piece, let userData else { return false }
                    return Unmanaged<TextPieceSink>.fromOpaque(userData).takeUnretainedValue().fn(String(cString: piece))
                }
                if chat_engine_generate(engine, prompt, maxTokens, temperature, callback, box) == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: EngineError.inference(String(cString: chat_engine_last_error(engine))))
                }
            }
        }
    }
}

private final class TextPieceSink {
    let fn: @Sendable (String) -> Bool
    init(_ fn: @escaping @Sendable (String) -> Bool) { self.fn = fn }
}
