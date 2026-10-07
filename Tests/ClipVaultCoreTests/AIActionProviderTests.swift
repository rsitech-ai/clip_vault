import Testing
@testable import ClipVaultCore

@Suite("AI action provider")
struct AIActionProviderTests {
    @Test("local summary and email attribute only clips actually used", arguments: [AIActionKind.summarize, .explain, .email])
    func localActionsReportUsedSources(kind: AIActionKind) async throws {
        let clips = (0..<7).map { index in
            Clip(id: "clip-\(index)", kind: .text, title: "Fixture \(index)", preview: "Fixture \(index)", extractedText: "Fixture \(index)")
        }
        let result = try await LocalClipAIActionProvider().perform(AIActionRequest(kind: kind, clips: clips))
        #expect(result.citedClipIDs == clips.prefix(kind == .email ? 3 : 5).map(\.id))
    }

    @Test("local Ask answers customer questions from selected clip evidence")
    func localAskAnswersCustomerQuestion() async throws {
        let provider = LocalClipAIActionProvider()
        let clip = Clip(
            id: "customer-1",
            kind: .text,
            title: "Customer account note",
            preview: "Customer: Maria Chen",
            extractedText: """
            Customer: Maria Chen
            Email: maria.chen@example.com
            Phone: +1 415 555 0188
            Plan: Pro annual
            """
        )

        let result = try await provider.perform(
            AIActionRequest(
                kind: .ask,
                clips: [clip],
                question: "What is the customer email?"
            )
        )

        #expect(result.title == "Ask")
        #expect(result.isFallback)
        #expect(result.citedClipIDs == ["customer-1"])
        #expect(result.content.contains("maria.chen@example.com"))
    }

    @Test("Ask requires a typed question")
    func askRequiresQuestion() async {
        let provider = LocalClipAIActionProvider()
        let clip = Clip(
            kind: .text,
            title: "Customer account note",
            preview: "Customer: Maria Chen",
            extractedText: "Email: maria.chen@example.com"
        )

        var didThrowEmptyQuestion = false
        do {
            _ = try await provider.perform(
                AIActionRequest(kind: .ask, clips: [clip], question: "   ")
            )
        } catch AIActionError.emptyQuestion {
            didThrowEmptyQuestion = true
        } catch {
            didThrowEmptyQuestion = false
        }

        #expect(didThrowEmptyQuestion)
    }
}
