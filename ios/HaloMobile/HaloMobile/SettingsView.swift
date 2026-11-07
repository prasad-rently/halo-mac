import SwiftUI
import HaloShareKit

/// Settings — grouped cards. Long explanations are behind (i) sheets, not on the surface.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cloud: CloudModel
    @State private var path: [CloudRoute] = []
    enum CloudRoute: Hashable { case setup }
    @State private var alias = ""
    @State private var showDeviceInfo = false
    @State private var showReceivingInfo = false
    @State private var showAboutInfo = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: HaloLayout.sectionSpacing) {
                    thisDevice
                    CloudSettingsSection(openSetup: { path = [.setup] })
                    receiving
                    about
                }
                .padding(HaloLayout.screenPadding)
            }
            .haloScreen()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(HaloStrings.Settings.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CloudRoute.self) { _ in CloudSetupView() }
            .onAppear { alias = model.identity.alias; if cloud.wantsSetup { path = [.setup]; cloud.wantsSetup = false } }
            .onChange(of: cloud.wantsSetup) { want in if want { path = [.setup]; cloud.wantsSetup = false } }
            .onDisappear { if alias != model.identity.alias { model.setAlias(alias) } }
            .haloInfoSheet(isPresented: $showDeviceInfo, title: HaloStrings.Info.deviceTitle, points: [
                HaloInfoPoint("person.wave.2.fill", .haloAccent, "Shown to others", "Other devices see this name when you send or receive."),
            ])
            .haloInfoSheet(isPresented: $showReceivingInfo, title: HaloStrings.Info.receivingTitle,
                           summary: HaloStrings.Info.receivingSummary, points: ShareInfo.receiving)
            .haloInfoSheet(isPresented: $showAboutInfo, title: HaloStrings.Info.aboutTitle, points: [
                HaloInfoPoint("wifi.exclamationmark", .haloAmber, "Not encrypted in transit", "Transfers stay on your Wi-Fi and are not encrypted in transit. Only accept files from people you trust."),
                HaloInfoPoint("arrow.left.arrow.right", .haloAccent, "LocalSend v2", "HaloShare speaks the open LocalSend v2 protocol, so it works with Halo on Mac and LocalSend apps."),
                HaloInfoPoint("touchid", .haloText2, "Fingerprint", "A short ID for this device, used by the protocol to tell devices apart."),
            ])
        }
    }

    // MARK: Sections

    private var thisDevice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(HaloStrings.Settings.thisDevice, onInfo: { showDeviceInfo = true })
            HaloCard(padding: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "iphone").font(.system(.subheadline).weight(.semibold)).foregroundColor(.haloAccent)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.haloAccent.opacity(0.14)))
                        .accessibilityHidden(true)
                    TextField(HaloStrings.Settings.name, text: $alias)
                        .font(HaloFont.headline).foregroundColor(.haloText)
                        .submitLabel(.done)
                        .accessibilityIdentifier("settings.alias")
                        .onSubmit { model.setAlias(alias) }
                    Image(systemName: "pencil").font(.system(.footnote)).foregroundColor(.haloText3).accessibilityHidden(true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(minHeight: 56)
            }
        }
    }

    private var receiving: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(HaloStrings.Settings.receiving, onInfo: { showReceivingInfo = true })
            HaloCard(padding: 0) {
                VStack(spacing: 0) {
                    HaloListRow(icon: "antenna.radiowaves.left.and.right", tint: statusState.color,
                                title: HaloStrings.Settings.status) { HaloStatusBadge(statusText, statusState, maxLines: 0) }
                    HaloRowDivider()
                    HaloListRow(icon: "folder.fill", tint: .haloAccent, title: HaloStrings.Settings.savedTo) {
                        Text(HaloStrings.Settings.savedToValue).font(HaloFont.caption).foregroundColor(.haloText2)
                    }
                    HaloRowDivider()
                    HaloListRow(icon: "wifi", tint: localNetworkState.color, title: ShareStrings.localNetwork) {
                        if model.localNetwork == .denied {
                            HaloSecondaryButton(HaloStrings.Share.openSettings, fullWidth: false) { model.openSystemSettings() }
                                .accessibilityIdentifier("settings.localNetwork.open")
                        } else {
                            HaloStatusBadge(localNetworkText, localNetworkState)
                        }
                    }
                    .accessibilityIdentifier("settings.localNetwork")
                    HaloRowDivider()
                    HaloListRow(icon: "square.and.arrow.up.on.square", tint: model.staging == nil ? .haloAmber : .haloGreen,
                                title: HaloStrings.Settings.shareFromApps) {
                        HaloStatusBadge(model.staging == nil ? "Unavailable" : "On", model.staging == nil ? .warning : .ok)
                    }
                    .accessibilityIdentifier("settings.shareExtension")
                    HaloRowDivider()
                    // Honest limit (F-050 D8): iOS suspends apps, so Halo receives while it is open. The detail is behind the (i).
                    HaloListRow(icon: "app.badge", tint: .haloGreen, title: ShareStrings.receivingChip)
                        .accessibilityIdentifier("settings.receivingCopy")
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(HaloStrings.Settings.about, onInfo: { showAboutInfo = true })
            HaloCard(padding: 0) {
                VStack(spacing: 0) {
                    HaloListRow(icon: "arrow.left.arrow.right", tint: .haloAccent, title: HaloStrings.Settings.protocolLabel,
                                subtitle: HaloStrings.Settings.protocolValue) {
                        HaloStatusBadge(HaloStrings.Settings.notEncrypted, .warning)
                    }
                    HaloRowDivider()
                    HaloListRow(icon: "touchid", tint: .haloText2, title: HaloStrings.Settings.fingerprint) {
                        Text(String(model.identity.fingerprint.prefix(12)) + "…").font(HaloFont.mono).foregroundColor(.haloText3)
                    }
                }
            }
        }
    }

    private var localNetworkState: HaloState {
        if !model.localNetworkExplained { return .neutral }
        switch model.localNetwork {
        case .granted: return .ok
        case .denied: return .warning
        case .undetermined: return .neutral
        }
    }

    private var localNetworkText: String {
        if !model.localNetworkExplained { return "Not asked yet" }
        switch model.localNetwork {
        case .granted: return "Allowed"
        case .denied: return "Off"
        case .undetermined: return "Checking…"
        }
    }

    private var statusText: String {
        switch model.listenState {
        case .listening(let port): return "Listening on \(port)"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .failed(let why): return why
        }
    }

    private var statusState: HaloState {
        switch model.listenState {
        case .listening: return .ok
        case .starting: return .warning
        case .stopped, .failed: return .error
        }
    }
}
