import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, where this Mac has it (macOS 26 or later, Apple Intelligence on):
/// words for what the app's rules found. It never judges the machines itself: a small model
/// misreads numbers (it called load 12 on 22 CPUs "well above" them), so the rules decide what
/// is wrong and the model only says it plainly. Nil when the model isn't there, and the rules'
/// own lines stand.
enum Insight {
    /// The model is on this Mac and ready.
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// A short note for the owner from the rules' findings, one a line: most important first,
    /// each with what to do. Nil without the model, or when it fails.
    static func note(_ findings: [String]) async -> String? {
        guard !findings.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: """
                You write a short status note for the owner of a shared build queue (cpuq) on a \
                few machines. You are given findings that code has already checked. Do not add \
                findings, guess causes, or change numbers. Most important first, one line each, \
                plain words, each ending with what to do. At most 80 words. No headings.
                """)
            guard let reply = try? await session.respond(to: findings.joined(separator: "\n")) else { return nil }
            let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        #endif
        return nil
    }
}
