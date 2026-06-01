import SwiftUI

struct ReceiveConsentView: View {
    @EnvironmentObject var manager: LocalShareManager
    @State private var destDirectory: URL = LocalShareManager.shared.currentSaveDirectory()
    @State private var showFolderPicker = false

    private var pending: LocalShareManager.IncomingTransfer? { manager.pendingConsent }
    private var files: [(String, FileDTOUpload)] {
        pending?.request.files.sorted(by: { $0.key < $1.key }) ?? []
    }
    private var totalSize: Int64 {
        files.reduce(0) { $0 + $1.1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.haloAccent)

                Text("Incoming Transfer")
                    .font(HaloFont.display(18, weight: .bold))
                    .foregroundColor(.haloText)

                if let info = pending?.request.info {
                    HStack(spacing: 6) {
                        Image(systemName: deviceIcon(for: info.deviceType))
                            .foregroundColor(.haloText2)
                        Text(info.alias)
                            .font(HaloFont.body(13, weight: .medium))
                            .foregroundColor(.haloText)
                        if let ip = pending?.sourceIP {
                            Text("(\(ip))")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText3)
                        }
                    }
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider().background(Color.haloBorder)

            // File list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(files, id: \.0) { fileId, file in
                        HStack(spacing: 10) {
                            Image(systemName: fileIcon(for: file.fileName))
                                .foregroundColor(.haloText2)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.fileName)
                                    .font(HaloFont.body(12))
                                    .foregroundColor(.haloText)
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(HaloFont.body(10))
                                    .foregroundColor(.haloText3)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                    }
                }
            }
            .frame(maxHeight: 200)
            .padding(.vertical, 12)

            Divider().background(Color.haloBorder)

            // Summary + destination
            VStack(spacing: 12) {
                HStack {
                    Text("\(files.count) file(s)")
                        .font(HaloFont.body(12, weight: .medium))
                        .foregroundColor(.haloText)
                    Text("·")
                        .foregroundColor(.haloText3)
                    Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText2)
                    Spacer()
                }

                HStack {
                    Text("Save to:")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    Text(destDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText)
                        .lineLimit(1)
                    Spacer()
                    Button("Change...") { showFolderPicker = true }
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloAccent)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider().background(Color.haloBorder)

            // Actions
            HStack(spacing: 12) {
                Button {
                    manager.rejectTransfer()
                } label: {
                    Text("Reject")
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(.haloRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.haloRed.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    manager.setSaveDirectory(destDirectory)
                    manager.acceptTransfer(destDirectory: destDirectory)
                } label: {
                    Text("Accept")
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.haloAccent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .frame(width: 420, height: 480)
        .background(Color.haloSurface)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() { destDirectory = url }
        }
    }

    private func deviceIcon(for type: String?) -> String {
        switch type {
        case "mobile": return "iphone"
        case "desktop": return "desktopcomputer"
        case "web": return "globe"
        default: return "laptopcomputer"
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic": return "photo"
        case "mp4", "mov", "avi": return "film"
        case "mp3", "wav", "m4a": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "rar": return "doc.zipper"
        case "txt", "md": return "doc.text"
        default: return "doc"
        }
    }
}
