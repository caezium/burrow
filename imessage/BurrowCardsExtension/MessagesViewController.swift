//
//  MessagesViewController.swift
//  Burrow Cards iMessage extension.
//
//  Two jobs:
//   1. Render an incoming card — decode the selected message's `?p=` payload
//      into a BurrowLayout and host the SwiftUI renderer.
//   2. Compose — when there's no card selected, show a gallery of sample cards
//      to insert into the thread (so you can test send/tap without the sidecar).
//

import Messages
import SwiftUI

final class MessagesViewController: MSMessagesAppViewController {

    /// Base URL the compose gallery encodes sample layouts into.
    private let cardBase = URL(string: "https://burrow.henryzh.dev/card")!

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        present(for: conversation.selectedMessage)
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        present(for: message)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        present(for: activeConversation?.selectedMessage)
    }

    // MARK: - Rendering

    private func present(for message: MSMessage?) {
        removeAllChildren()

        let root: AnyView
        if let url = message?.url, let layout = try? BurrowTransport.decode(url: url) {
            root = AnyView(
                ScrollView { BurrowLayoutView(layout: layout) { [weak self] in self?.open($0) } }
            )
        } else {
            root = AnyView(ComposeGallery { [weak self] in self?.insert($0) })
        }

        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func removeAllChildren() {
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }

    // MARK: - Compose / actions

    private func insert(_ layout: BurrowLayout) {
        guard let conversation = activeConversation else { return }

        let template = MSMessageTemplateLayout()
        template.caption = layout.title
        template.subcaption = layout.subtitle

        let message = MSMessage()
        message.layout = template
        message.url = (try? BurrowTransport.encode(base: cardBase, layout: layout)) ?? cardBase

        conversation.insert(message) { _ in }
        requestPresentationStyle(.compact)
    }

    private func open(_ action: BurrowAction) {
        guard let url = action.burrowURL else { return }
        extensionContext?.open(url) { [weak self] opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "Open Burrow on your Mac", message: "Review your Mac's health and cleanup options in Burrow on that Mac.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }
}
