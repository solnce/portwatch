import AppKit
import SwiftUI
import PortMonitorCore

struct PortMenuView: View {
    @ObservedObject var store: PortMonitorStore

    var body: some View {
        ZStack {
            if let pendingStop = store.pendingStop {
                StopConfirmationView(
                    port: pendingStop.target,
                    heldPorts: pendingStop.heldPorts,
                    onCancel: {
                        store.cancelPendingStop()
                    },
                    onConfirm: {
                        store.confirmPendingStop()
                    }
                )
            } else {
                mainContent
            }
        }
        .frame(width: 460, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.refresh()
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            if let errorMessage = store.errorMessage {
                Divider()
                errorBanner(errorMessage)
            }
            Divider()
            filters
            Divider()
            portList
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Port Watch")
                    .font(.headline)
                Text("TCP LISTEN \(store.visiblePorts.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("今すぐ更新")
            .accessibilityLabel("ポート一覧を更新")
        }
        .padding(14)
    }

    private var filters: some View {
        VStack(spacing: 10) {
            TextField("ポート・プロセス・パスを検索", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
            Picker("表示範囲", selection: $store.showsOnlyCurrentUser) {
                Text("自分のプロセス").tag(true)
                Text("すべて").tag(false)
            }
            .pickerStyle(.segmented)
        }
        .padding(12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("閉じる") {
                store.dismissError()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("error-banner-dismiss-button")
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error-banner")
    }

    @ViewBuilder
    private var portList: some View {
        if store.visiblePorts.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: store.isRefreshing ? "hourglass" : "network.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(store.isRefreshing ? "確認中…" : "待受中のポートはありません")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.visiblePorts) { port in
                        PortRowView(
                            port: port,
                            isStopping: store.isStopping(port),
                            canStop: store.canStop(port),
                            onStop: {
                                store.requestStop(port)
                            }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(lastUpdatedText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var lastUpdatedText: String {
        guard let date = store.lastUpdatedAt else {
            return "未更新"
        }
        return "最終更新 \(date.formatted(date: .omitted, time: .standard))"
    }

}
