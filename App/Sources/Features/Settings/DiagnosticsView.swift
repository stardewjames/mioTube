import MioTubeCore
import SwiftUI
import UIKit

struct DiagnosticsView: View {
  @Environment(AppEnvironment.self) private var env
  @State private var probes: [ProfileProbe] = []
  @State private var probing = false
  @State private var probedVideoID: String?
  @State private var config: InnertubeConfig?
  @State private var copied = false

  private static let probeFallbackVideo = "dQw4w9WgXcQ"

  var body: some View {
    @Bindable var settings = env.settings
    List {
      Section("Current video") {
        LabeledContent("Video ID", value: currentVideoID)
        LabeledContent("Resolved source", value: sourceDescription)
        LabeledContent("Resolved by", value: env.coordinator.lastResolution?.profileID ?? "—")
        LabeledContent("SponsorBlock segments", value: "\(env.coordinator.sponsorSegments.count)")
        if let log = env.coordinator.engine.lastErrorLog {
          LabeledContent("Last player log", value: log)
        }
      }

      Section {
        if probes.isEmpty && !probing {
          Text("Run a probe to see every client profile's answer.").foregroundStyle(.secondary)
        }
        ForEach(probes) { probe in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(probe.profile).font(.subheadline.monospaced().weight(.semibold))
              Spacer()
              Text(probe.playabilityStatus ?? "—").font(.caption.monospaced())
                .foregroundStyle(probe.source != nil ? Color.green : Color.secondary)
            }
            Text("HLS: \(probe.hlsManifestURL != nil ? "yes" : "no") · muxed itags: \(probe.muxedItags.isEmpty ? "none" : probe.muxedItags.map(String.init).joined(separator: ",")) · ad placements: \(probe.hasAdPlacements ? "yes (ignored)" : "no")")
              .font(.caption)
              .foregroundStyle(.secondary)
            if let reason = probe.reason {
              Text(reason).font(.caption).foregroundStyle(.orange)
            }
          }
        }
        Button {
          Task { await probe() }
        } label: {
          if probing { ProgressView() } else { Label("Re-probe", systemImage: "arrow.clockwise") }
        }
        .disabled(probing)
      } header: {
        Text("Profiles (\(probedVideoID ?? currentVideoID))")
      }

      Section("Feeds") {
        LabeledContent("Last feed", value: env.diagnostics.lastFeedName.isEmpty ? "—" : env.diagnostics.lastFeedName)
        LabeledContent("Dropped ads (last feed page)", value: "\(env.diagnostics.lastFeedDroppedAds)")
        LabeledContent("Dropped ads (last watch page)", value: "\(env.diagnostics.lastWatchDroppedAds)")
        LabeledContent("Total blocked", value: "\(env.settings.blockedAdsTotal)")
      }

      Section("InnerTube") {
        LabeledContent("Client version", value: config?.clientVersion ?? "\(env.catalog.metadata.clientVersion) (pinned)")
        LabeledContent("Visitor data", value: config?.visitorData.map { String($0.prefix(16)) + "…" } ?? "—")
        LabeledContent("Playback order", value: env.catalog.playbackOrder.joined(separator: ", "))
      }

      Section {
        Toggle("Force test SponsorBlock segment", isOn: $settings.forceTestSponsorSegment)
      } footer: {
        Text("Injects a synthetic skip segment at 00:10–00:15 into every video for testing.")
      }

      Section {
        Button(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = report
          copied = true
        }
      }
    }
    .navigationTitle("Diagnostics")
    .task {
      config = await env.configProvider.config()
      if probes.isEmpty { await probe() }
    }
  }

  private var currentVideoID: String {
    env.coordinator.current?.video.videoID ?? Self.probeFallbackVideo
  }

  private var sourceDescription: String {
    switch env.coordinator.lastResolution?.source {
    case .hls?: "HLS"
    case .progressive?: "Progressive MP4"
    case .unavailable?: "Unavailable"
    case nil: "—"
    }
  }

  private func probe() async {
    probing = true
    let id = currentVideoID
    await env.configProvider.invalidate()
    config = await env.configProvider.config()
    probes = await env.resolver.probeAll(videoID: id)
    probedVideoID = id
    probing = false
  }

  private var report: String {
    var lines = [
      "MioTube diagnostics",
      "video: \(probedVideoID ?? currentVideoID)",
      "source: \(sourceDescription) via \(env.coordinator.lastResolution?.profileID ?? "-")",
      "clientVersion: \(config?.clientVersion ?? env.catalog.metadata.clientVersion)",
      "visitorData: \(config?.visitorData != nil ? "present" : "absent")",
      "sponsorSegments: \(env.coordinator.sponsorSegments.count)",
      "droppedAds(feed): \(env.diagnostics.lastFeedDroppedAds) total: \(env.settings.blockedAdsTotal)",
    ]
    for probe in probes {
      lines.append("\(probe.profile): status=\(probe.playabilityStatus ?? "-") hls=\(probe.hlsManifestURL != nil) itags=\(probe.muxedItags) ads=\(probe.hasAdPlacements) reason=\(probe.reason ?? "-")")
    }
    return lines.joined(separator: "\n")
  }
}
