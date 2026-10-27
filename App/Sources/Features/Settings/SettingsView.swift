import MioTubeCore
import SwiftUI

struct SettingsView: View {
  @Environment(AppEnvironment.self) private var env
  @State private var confirmClear = false

  var body: some View {
    @Bindable var settings = env.settings
    Form {
      accountSection

      Section("Playback") {
        Picker("Default quality", selection: $settings.defaultQuality) {
          ForEach(QualityCap.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Default speed", selection: $settings.defaultSpeed) {
          ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
            Text(speed == 1 ? "Normal" : "\(speed.formatted())×").tag(speed)
          }
        }
        Toggle("Autoplay next video", isOn: $settings.autoplay)
        Toggle("Start Picture in Picture automatically", isOn: $settings.pipAutoStart)
        Toggle("Keep playing in background", isOn: $settings.backgroundPlayback)
        Stepper("Caption size: \(Int(settings.preferredCaptionSize)) pt", value: $settings.preferredCaptionSize, in: 12...32)
      }

      sponsorBlockSection(settings)

      Section {
        LabeledContent("Feed ads blocked", value: settings.blockedAdsTotal.formatted())
        Button("Clear feed cache", role: .destructive) { confirmClear = true }
      } header: {
        Text("Ads")
      } footer: {
        Text("Ad renderers are removed from every response before it is displayed, and the player never requests ad playback. This is always on.")
      }

      Section("Appearance") {
        Picker("Theme", selection: $settings.appearance) {
          Text("System").tag(AppearanceMode.system)
          Text("Light").tag(AppearanceMode.light)
          Text("Dark").tag(AppearanceMode.dark)
        }
        .pickerStyle(.segmented)
      }

      Section {
        NavigationLink(value: Route.diagnostics) { Label("Diagnostics", systemImage: "stethoscope") }
      }
    }
    .navigationTitle("Settings")
    .confirmationDialog("Clear cached feeds and thumbnails?", isPresented: $confirmClear, titleVisibility: .visible) {
      Button("Clear", role: .destructive) {
        Task {
          await env.feedCache.clearAll()
          await env.images.clearDisk()
        }
      }
    }
  }

  @ViewBuilder
  private var accountSection: some View {
    Section("Account") {
      AccountSummaryRow()
      switch env.account.state {
      case .signedIn, .validating:
        Button("Sign out", role: .destructive) { Task { await env.account.signOut() } }
      case .expired:
        Text("Session expired — sign in again").foregroundStyle(.orange)
        Button("Sign out", role: .destructive) { Task { await env.account.signOut() } }
      case .signedOut:
        EmptyView()
      }
      NavigationLink(value: Route.pasteCookies) { Text("Paste cookies…") }
    }
  }

  private func sponsorBlockSection(_ source: Settings) -> some View {
    @Bindable var settings = source
    return Section {
      Toggle("Skip sponsored segments", isOn: $settings.sponsorBlockEnabled)
      if settings.sponsorBlockEnabled {
        ForEach(SponsorCategory.allCases, id: \.self) { category in
          if let actions = Settings.configurableActions[category] {
            Picker(category.displayName, selection: actionBinding(category, settings: settings)) {
              ForEach(actions, id: \.self) { action in
                Text(action == .skip ? "Skip" : "Mute").tag(Optional(action))
              }
              Text("Off").tag(SponsorAction?.none)
            }
          } else {
            Toggle(category.displayName, isOn: categoryBinding(category, settings: settings))
          }
        }
        TextField("Server", text: $settings.sponsorBlockServer)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Toggle("Privacy mode (hash prefix)", isOn: $settings.sponsorBlockPrivacyMode)
      }
    } header: {
      Text("SponsorBlock")
    } footer: {
      Text("Segments come from the community SponsorBlock database. Privacy mode sends only the first 4 characters of a SHA-256 hash of the video ID.")
    }
  }

  private func categoryBinding(_ category: SponsorCategory, settings: Settings) -> Binding<Bool> {
    Binding(
      get: { settings.enabledSponsorCategories.contains(category) },
      set: { enabled in
        if enabled { settings.enabledSponsorCategories.insert(category) } else { settings.enabledSponsorCategories.remove(category) }
      }
    )
  }

  /// skip / mute / off (off = category disabled).
  private func actionBinding(_ category: SponsorCategory, settings: Settings) -> Binding<SponsorAction?> {
    Binding(
      get: {
        guard settings.enabledSponsorCategories.contains(category) else { return nil }
        return settings.sponsorCategoryActions[category] ?? .skip
      },
      set: { action in
        if let action {
          settings.enabledSponsorCategories.insert(category)
          settings.sponsorCategoryActions[category] = action == .skip ? nil : action
        } else {
          settings.enabledSponsorCategories.remove(category)
        }
      }
    )
  }
}
