import SwiftUI

struct TextInputView: View {
    enum Destination: Equatable {
        case android
        case iPhone
    }

    let destination: Destination
    let remoteClipboardText: String?
    let onPaste: (String) -> Void
    let onRequestRemoteClipboard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .focused($isFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(destination == .iPhone ? "发送到 iPhone" : "发送到 Android")
                } footer: {
                    if destination == .iPhone {
                        Text("发送后会在当前输入位置写入文字。")
                    } else {
                        Text("发送后会写入远端剪贴板，并立即执行粘贴。")
                    }
                }

                Section {
                    Button("粘贴到远端") {
                        onPaste(text)
                        dismiss()
                    }
                    .disabled(text.isEmpty)
                }

                if destination == .android {
                    Section("远端剪贴板") {
                        if let remoteClipboardText {
                            Text(remoteClipboardText)
                                .textSelection(.enabled)
                        } else {
                            Text("尚未读取")
                                .foregroundStyle(.secondary)
                        }
                        Button("读取远端剪贴板", action: onRequestRemoteClipboard)
                    }
                }
            }
            .navigationTitle("文字输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }
}
