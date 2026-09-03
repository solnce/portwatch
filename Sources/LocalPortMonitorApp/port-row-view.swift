import SwiftUI
import PortMonitorCore

struct PortRowView: View {
    let port: ListeningPort
    let isStopping: Bool
    let canStop: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 1) {
                Text(":\(port.port)")
                    .font(.system(.headline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(addressSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(port.processName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("PID \(port.processID)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let workingDirectory = port.workingDirectory {
                    HStack(spacing: 4) {
                        if port.isWorkingDirectoryMissing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                        }
                        Text(directorySummary(workingDirectory))
                            .font(.caption)
                            .foregroundStyle(port.isWorkingDirectoryMissing ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(port.isWorkingDirectoryMissing ? "削除済み: \(workingDirectory)" : workingDirectory)
                } else {
                    Text("作業ディレクトリを取得できません")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onStop) {
                Group {
                    if isStopping {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: canStop ? "stop.circle.fill" : "lock.circle")
                            .font(.title3)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canStop ? Color.red : Color.secondary)
            .disabled(!canStop || isStopping)
            .help(canStop ? "プロセスを停止" : "このプロセスは停止できません")
            .accessibilityLabel(canStop ? "ポート\(port.port)のプロセスを停止" : "停止できないプロセス")
            .accessibilityIdentifier("port-row-stop-button-\(port.processID)-\(port.port)")
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(port.isWorkingDirectoryMissing ? Color.orange.opacity(0.45) : Color.clear)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private var addressSummary: String {
        let names = port.addresses.map { address in
            switch address {
            case "127.0.0.1", "[::1]":
                return "localhost"
            case "*":
                return "すべて"
            default:
                return address
            }
        }
        return Array(NSOrderedSet(array: names))
            .compactMap { $0 as? String }
            .joined(separator: ", ")
    }

    private func directorySummary(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        if let workspacesIndex = components.firstIndex(of: "workspaces"),
           components.indices.contains(workspacesIndex + 2) {
            return components[(workspacesIndex + 1)...].joined(separator: " / ")
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
