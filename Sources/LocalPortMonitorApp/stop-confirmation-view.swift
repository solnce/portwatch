import SwiftUI
import PortMonitorCore

struct StopConfirmationView: View {
    let port: ListeningPort
    let heldPorts: [Int]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                Text("\(port.processName) を停止しますか？")
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("このPIDにSIGTERMを送ります。")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailRow(label: "PID", value: String(port.processID))
                    detailRow(label: "ユーザー", value: userDescription)
                    detailRow(label: "対象ポート", value: portDescription)
                    detailRow(
                        label: "作業場所",
                        value: workingDirectoryDescription,
                        highlightsWarning: port.isWorkingDirectoryMissing
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("キャンセル")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("stop-confirmation-cancel-button")

                Button(role: .destructive, action: onConfirm) {
                    Text("停止")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("stop-confirmation-confirm-button")
            }
            .controlSize(.large)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop-confirmation-view")
    }

    private var userDescription: String {
        if let userName = port.userName, let userID = port.userID {
            return "\(userName)（UID \(userID)）"
        }
        if let userID = port.userID {
            return "UID \(userID)"
        }
        return port.userName ?? "不明"
    }

    private var portDescription: String {
        heldPorts
            .sorted()
            .map { ":\($0)" }
            .joined(separator: ", ")
    }

    private var workingDirectoryDescription: String {
        guard let workingDirectory = port.workingDirectory else {
            return "不明"
        }
        return port.isWorkingDirectoryMissing
            ? "\(workingDirectory)（削除済み）"
            : workingDirectory
    }

    private func detailRow(
        label: String,
        value: String,
        highlightsWarning: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(highlightsWarning ? Color.orange : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
