import AppKit
import ArgumentParser
import Foundation
import TrolleyKit
import TrolleyWidget

/// Types a prompt into the running app's box from a terminal, and prints what came back.
///
/// Not the same thing as `trolley ask`, and the difference is the whole point. `ask`
/// talks to the model from *this* process, which can chat but cannot touch the Mac:
/// macOS attributes an Accessibility grant to the process responsible for the launch, so
/// a binary started from a shell is trusted as that shell. Measured here -- the app
/// reports trusted while a `trolley mcp` beside it, same binary and same path, does not.
///
/// So this hands the question to the app, which has the grant, and waits. What runs is
/// the same tool loop the prompt box runs, because it *is* the prompt box.
struct PromptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompt",
        abstract: "Send a prompt to the running trolley app and print the answer."
    )

    @Argument(help: "What to ask. The app runs it, tools and all.")
    var text: [String]

    @Option(help: "Give up after this many seconds.")
    var timeout: Double = 300

    func run() throws {
        let prompt = text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ValidationError("보낼 말이 없습니다.")
        }
        guard WidgetHost.isRunning() else {
            throw ValidationError(
                "trolley 앱이 실행 중이 아닙니다. 응용 프로그램에서 trolley 를 먼저 여세요."
            )
        }

        // Correlates the answer with this call. Two terminals asking at once must not
        // read each other's replies.
        let requestID = UUID().uuidString
        var answered = false

        let observer = PromptBridge.observeAnswers { id, answer, isError in
            guard id == requestID else { return }
            answered = true
            print(answer)
            if isError {
                // The distinction the shell cares about: a model that failed and a model
                // that answered should not both look like success.
                Darwin.exit(1)
            }
            Darwin.exit(0)
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        guard PromptBridge.submit(prompt, requestID: requestID) else {
            throw ValidationError("trolley 앱에 전달하지 못했습니다.")
        }

        // A run loop rather than a semaphore: distributed notifications are delivered
        // by the run loop, so blocking the thread would mean never hearing the answer.
        let deadline = Date().addingTimeInterval(timeout)
        while !answered, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        guard answered else {
            FileHandle.standardError.write(Data("시간이 지나도 답이 오지 않았습니다.\n".utf8))
            throw ExitCode(2)
        }
    }
}
