import Foundation
import Observation

public enum QualityCap: String, CaseIterable, Sendable, Codable {
  case auto, p1080, p720, p480

  public var maxHeight: Int? {
    switch self {
    case .auto: nil
    case .p1080: 1080
    case .p720: 720
    case .p480: 480
    }
  }

  /// Bit-rate cap for HLS variants; 1080/Auto rely on resolution only.
  public var peakBitRate: Double? {
    switch self {
    case .p480: 1_500_000
    case .p720: 3_500_000
    default: nil
    }
  }

  public var label: String {
    switch self {
    case .auto: "Auto"
    case .p1080: "1080p"
    case .p720: "720p"
    case .p480: "480p"
    }
  }
}

public enum AppearanceMode: String, CaseIterable, Sendable, Codable {
  case system, light, dark
}

/// User preferences backed by `UserDefaults`; keys are the property names.
@MainActor
@Observable
public final class Settings {
  public static let defaultEnabledCategories: Set<SponsorCategory> = [
    .sponsor, .selfpromo, .interaction, .exclusiveAccess, .musicOfftopic, .poiHighlight, .chapter,
  ]
  /// Categories whose action the user may change, and the allowed actions.
  public static let configurableActions: [SponsorCategory: [SponsorAction]] = [
    .sponsor: [.skip, .mute], .selfpromo: [.skip, .mute], .musicOfftopic: [.skip, .mute],
  ]

  @ObservationIgnored private let defaults: UserDefaults

  public var defaultQuality: QualityCap { didSet { defaults.set(defaultQuality.rawValue, forKey: "defaultQuality") } }
  public var defaultSpeed: Double { didSet { defaults.set(defaultSpeed, forKey: "defaultSpeed") } }
  public var autoplay: Bool { didSet { defaults.set(autoplay, forKey: "autoplay") } }
  public var pipAutoStart: Bool { didSet { defaults.set(pipAutoStart, forKey: "pipAutoStart") } }
  public var backgroundPlayback: Bool { didSet { defaults.set(backgroundPlayback, forKey: "backgroundPlayback") } }
  public var sponsorBlockEnabled: Bool { didSet { defaults.set(sponsorBlockEnabled, forKey: "sponsorBlockEnabled") } }
  public var enabledSponsorCategories: Set<SponsorCategory> {
    didSet { defaults.set(enabledSponsorCategories.map(\.rawValue).sorted(), forKey: "enabledSponsorCategories") }
  }
  public var sponsorCategoryActions: [SponsorCategory: SponsorAction] {
    didSet {
      defaults.set(
        Dictionary(uniqueKeysWithValues: sponsorCategoryActions.map { ($0.key.rawValue, $0.value.rawValue) }),
        forKey: "sponsorCategoryActions"
      )
    }
  }
  public var sponsorBlockServer: String { didSet { defaults.set(sponsorBlockServer, forKey: "sponsorBlockServer") } }
  public var sponsorBlockPrivacyMode: Bool { didSet { defaults.set(sponsorBlockPrivacyMode, forKey: "sponsorBlockPrivacyMode") } }
  public var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
  public var preferredCaptionSize: Double { didSet { defaults.set(preferredCaptionSize, forKey: "preferredCaptionSize") } }
  public var preferredCaptionLanguage: String? { didSet { defaults.set(preferredCaptionLanguage, forKey: "preferredCaptionLanguage") } }
  public var blockedAdsTotal: Int { didSet { defaults.set(blockedAdsTotal, forKey: "blockedAdsTotal") } }
  public var forceTestSponsorSegment: Bool { didSet { defaults.set(forceTestSponsorSegment, forKey: "forceTestSponsorSegment") } }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    defaultQuality = defaults.string(forKey: "defaultQuality").flatMap(QualityCap.init(rawValue:)) ?? .auto
    defaultSpeed = defaults.object(forKey: "defaultSpeed") as? Double ?? 1
    autoplay = defaults.object(forKey: "autoplay") as? Bool ?? true
    pipAutoStart = defaults.object(forKey: "pipAutoStart") as? Bool ?? true
    backgroundPlayback = defaults.object(forKey: "backgroundPlayback") as? Bool ?? true
    sponsorBlockEnabled = defaults.object(forKey: "sponsorBlockEnabled") as? Bool ?? true
    enabledSponsorCategories = (defaults.stringArray(forKey: "enabledSponsorCategories"))
      .map { Set($0.compactMap(SponsorCategory.init(rawValue:))) } ?? Self.defaultEnabledCategories
    sponsorCategoryActions = (defaults.dictionary(forKey: "sponsorCategoryActions") as? [String: String] ?? [:])
      .reduce(into: [:]) { result, pair in
        if let category = SponsorCategory(rawValue: pair.key), let action = SponsorAction(rawValue: pair.value) {
          result[category] = action
        }
      }
    sponsorBlockServer = defaults.string(forKey: "sponsorBlockServer") ?? SponsorBlockClient.defaultServer.absoluteString
    sponsorBlockPrivacyMode = defaults.object(forKey: "sponsorBlockPrivacyMode") as? Bool ?? false
    appearance = defaults.string(forKey: "appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
    preferredCaptionSize = defaults.object(forKey: "preferredCaptionSize") as? Double ?? 17
    preferredCaptionLanguage = defaults.string(forKey: "preferredCaptionLanguage")
    blockedAdsTotal = defaults.integer(forKey: "blockedAdsTotal")
    forceTestSponsorSegment = defaults.object(forKey: "forceTestSponsorSegment") as? Bool ?? false
  }

  public var sponsorServerURL: URL {
    URL(string: sponsorBlockServer).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } ?? SponsorBlockClient.defaultServer
  }

  /// Categories the SkipEngine should act on right now.
  public var activeSponsorCategories: Set<SponsorCategory> {
    sponsorBlockEnabled ? enabledSponsorCategories : []
  }
}
