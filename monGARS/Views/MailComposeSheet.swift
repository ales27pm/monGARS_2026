import SwiftUI

#if canImport(MessageUI) && canImport(UIKit)
import MessageUI
import UIKit
#endif

struct MailComposeRequest: Identifiable, Equatable {
    var id: String { url.absoluteString }
    var url: URL
}

struct MailComposeSheet: View {
    let request: MailComposeRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if canImport(MessageUI) && canImport(UIKit)
        if MFMailComposeViewController.canSendMail() {
            MailComposeController(url: request.url) {
                dismiss()
            }
        } else {
            unavailableFallback
        }
        #else
        unavailableFallback
        #endif
    }

    private var unavailableFallback: some View {
        NavigationStack {
            ContentUnavailableView("Mail compose unavailable", systemImage: "envelope.badge", description: Text("Use the system Mail handoff instead."))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            openURL(request.url)
                            dismiss()
                        } label: {
                            Label("Open Mail", systemImage: "arrow.up.forward.app")
                        }
                    }
                }
        }
    }
}

#if canImport(MessageUI) && canImport(UIKit)
private struct MailComposeController: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        let draft = MailDraft(url: url)
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(draft.recipients)
        if let subject = draft.subject {
            controller.setSubject(subject)
        }
        if let body = draft.body {
            controller.setMessageBody(body, isHTML: false)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}
#endif

private struct MailDraft {
    var recipients: [String]
    var subject: String?
    var body: String?

    init(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let recipient = url.path.removingPercentEncoding ?? url.path
        recipients = recipient.isEmpty ? [] : [recipient]
        subject = components?.queryItems?.first(where: { $0.name == "subject" })?.value
        body = components?.queryItems?.first(where: { $0.name == "body" })?.value
    }
}
