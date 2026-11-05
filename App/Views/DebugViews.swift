import SwiftUI
import UIKit
import BudgetCore

/// There is no Xcode debugger in this workflow, so the app shows its own log.
struct DebugLogView: View {
    @Environment(LedgerModel.self) private var model

    var body: some View {
        List(model.ledger.log) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.message)
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let raw = entry.rawText {
                    Text(raw)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .overlay {
            if model.ledger.log.isEmpty {
                ContentUnavailableView("Log is empty", systemImage: "doc.text")
            }
        }
        .navigationTitle("Debug log")
        .toolbar {
            Button("Clear", role: .destructive) { model.clearLog() }
                .disabled(model.ledger.log.isEmpty)
        }
        .refreshable { model.reload() }
    }
}

/// Paste an SMS to see how it parses, and optionally log it the same way the Shortcuts automation does.
struct ParserPlaygroundView: View {
    @Environment(LedgerModel.self) private var model
    @State private var text = ""
    @State private var lastOutcome: String?

    private var result: ParseResult? {
        text.isEmpty ? nil : SMSParser(settings: model.ledger.settings).parse(text)
    }

    var body: some View {
        Form {
            Section("SMS text") {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .font(.footnote.monospaced())
                Button("Paste from clipboard") {
                    text = UIPasteboard.general.string ?? ""
                }
            }

            if let result {
                Section("Result") {
                    if let parsed = result.parsed {
                        LabeledContent("Amount", value: "\(parsed.amount)")
                        LabeledContent("Merchant", value: parsed.merchant ?? "—")
                        LabeledContent("Type", value: parsed.kind.title)
                        LabeledContent("Account", value: parsed.account == .creditCard ? "Credit card" : "Bank")
                        LabeledContent("Card", value: parsed.card ?? "—")
                        LabeledContent("Reference", value: parsed.ref ?? "—")
                        LabeledContent("Rule", value: parsed.ruleID)
                    } else if case .ignored(let reason) = result {
                        LabeledContent("Ignored", value: reason)
                    }
                }
                Section {
                    Button("Log it (like the automation)") {
                        lastOutcome = (try? LogBankSMSIntent.process(message: text, at: Date())) ?? "Save failed"
                        model.reload()
                    }
                    if let lastOutcome {
                        Text(lastOutcome).font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Test SMS parser")
    }
}
