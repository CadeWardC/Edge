import Foundation

enum LFMError: LocalizedError {
    case load(String)
    case inference(String)

    var errorDescription: String? {
        switch self {
        case .load(let msg): return msg
        case .inference(let msg): return msg
        }
    }
}

/// Owns one lfm_engine and runs every call on a private serial queue.
final class LFMRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "edge.lfm.engine", qos: .userInitiated)
    private let engine: OpaquePointer

    let inputSampleRate: Double

    private init(engine: OpaquePointer) {
        self.engine = engine
        self.inputSampleRate = Double(lfm_engine_input_sample_rate(engine))
    }

    private var closed = false

    deinit {
        let engine = self.engine
        let closed = self.closed
        queue.async { if !closed { lfm_engine_free(engine) } }
    }

    /// Frees the model now, after any running call, so a reload never holds two copies in memory.
    func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.closed {
                    lfm_engine_free(self.engine)
                    self.closed = true
                }
                cont.resume()
            }
        }
    }

    static func load(modelPath: String, mmprojPath: String, speechOnGPU: Bool = true,
                     contextSize: Int32 = 4096) async throws -> LFMRuntime {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err = [CChar](repeating: 0, count: 512)
                #if targetEnvironment(simulator)
                let useGPU = false
                #else
                let useGPU = true
                #endif
                if let engine = lfm_engine_create(modelPath, mmprojPath, contextSize, useGPU, useGPU && speechOnGPU, &err, err.count) {
                    cont.resume(returning: LFMRuntime(engine: engine))
                } else {
                    cont.resume(throwing: LFMError.load(String(cString: err)))
                }
            }
        }
    }

    /// Streams text pieces to `onText`; return false from it to stop early.
    func generate(prompt: String, audio: [Float]? = nil, maxTokens: Int32, temperature: Float,
                  onText: @escaping @Sendable (String) -> Bool) async throws {
        let box = Unmanaged.passRetained(TextSink(onText)).toOpaque()
        defer { Unmanaged<TextSink>.fromOpaque(box).release() }
        let engine = self.engine

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let callback: lfm_text_callback = { piece, userData in
                    guard let piece, let userData else { return false }
                    return Unmanaged<TextSink>.fromOpaque(userData).takeUnretainedValue().fn(String(cString: piece))
                }
                let ret: Int32
                if let audio, !audio.isEmpty {
                    ret = audio.withUnsafeBufferPointer { buf in
                        lfm_engine_generate(engine, prompt, buf.baseAddress, buf.count, maxTokens, temperature, callback, box)
                    }
                } else {
                    ret = lfm_engine_generate(engine, prompt, nil, 0, maxTokens, temperature, callback, box)
                }
                if ret == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: LFMError.inference(String(cString: lfm_engine_last_error(engine))))
                }
            }
        }
    }

    /// The conversation: only the part of `prompt` not already in memory is evaluated. Streams the reply
    /// to `onText`; returning false from it pauses the reply. Returns true when paused (see `chatContinue`).
    func chat(prompt: String, maxTokens: Int32, temperature: Float,
              onText: @escaping @Sendable (String) -> Bool) async throws -> Bool {
        try await runChat(onText) { engine, callback, box, paused in
            lfm_engine_chat(engine, prompt, maxTokens, temperature, callback, box, paused)
        }
    }

    /// Resumes a paused reply. Returns true when paused again.
    func chatContinue(maxTokens: Int32, onText: @escaping @Sendable (String) -> Bool) async throws -> Bool {
        try await runChat(onText) { engine, callback, box, paused in
            lfm_engine_chat_continue(engine, maxTokens, callback, box, paused)
        }
    }

    /// Forgets the conversation held in the model's memory.
    func chatReset() {
        let engine = self.engine
        queue.async { lfm_engine_chat_reset(engine) }
    }

    private func runChat(_ onText: @escaping @Sendable (String) -> Bool,
                         _ call: @escaping (OpaquePointer, lfm_text_callback, UnsafeMutableRawPointer, UnsafeMutablePointer<Bool>) -> Int32) async throws -> Bool {
        let box = Unmanaged.passRetained(TextSink(onText)).toOpaque()
        defer { Unmanaged<TextSink>.fromOpaque(box).release() }
        let engine = self.engine

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            queue.async {
                let callback: lfm_text_callback = { piece, userData in
                    guard let piece, let userData else { return false }
                    return Unmanaged<TextSink>.fromOpaque(userData).takeUnretainedValue().fn(String(cString: piece))
                }
                var paused = false
                let ret = withUnsafeMutablePointer(to: &paused) { call(engine, callback, box, $0) }
                if ret == 0 {
                    cont.resume(returning: paused)
                } else {
                    cont.resume(throwing: LFMError.inference(String(cString: lfm_engine_last_error(engine))))
                }
            }
        }
    }

    /// Streams 24 kHz mono PCM chunks to `onAudio`; return false from it to stop early.
    func speak(prompt: String, maxFrames: Int32 = 600,
               onAudio: @escaping @Sendable ([Float], Double) -> Bool) async throws {
        let box = Unmanaged.passRetained(AudioSink(onAudio)).toOpaque()
        defer { Unmanaged<AudioSink>.fromOpaque(box).release() }
        let engine = self.engine

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let callback: lfm_audio_callback = { samples, count, sampleRate, userData in
                    guard let samples, let userData, count > 0 else { return true }
                    let chunk = Array(UnsafeBufferPointer(start: samples, count: Int(count)))
                    return Unmanaged<AudioSink>.fromOpaque(userData).takeUnretainedValue().fn(chunk, Double(sampleRate))
                }
                if lfm_engine_speak(engine, prompt, maxFrames, callback, box) == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: LFMError.inference(String(cString: lfm_engine_last_error(engine))))
                }
            }
        }
    }
}

private final class TextSink {
    let fn: @Sendable (String) -> Bool
    init(_ fn: @escaping @Sendable (String) -> Bool) { self.fn = fn }
}

private final class AudioSink {
    let fn: @Sendable ([Float], Double) -> Bool
    init(_ fn: @escaping @Sendable ([Float], Double) -> Bool) { self.fn = fn }
}
