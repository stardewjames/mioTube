import MioTubeCore
import SwiftUI

struct SearchView: View {
  @Environment(AppEnvironment.self) private var env
  @State private var query = ""
  @State private var submitted: String?
  @State private var filter: SearchFilter?
  @State private var suggestions: [String] = []
  @State private var model: FeedModel?
  @State private var baseChips: [SearchChip] = []

  var body: some View {
    NavigationStack {
      Group {
        if let model {
          FeedScrollView(model: model, style: .list) {
            chipBar
          }
          .id(model.key)
        } else {
          ContentUnavailableView("Search YouTube", systemImage: "magnifyingglass", description: Text("No ads, no tracking pixels — just results."))
        }
      }
      .navigationTitle("Search")
      .searchable(text: $query, prompt: "Videos, channels, playlists")
      .searchSuggestions {
        ForEach(suggestions, id: \.self) { suggestion in
          Label(suggestion, systemImage: "magnifyingglass").searchCompletion(suggestion)
        }
      }
      .onSubmit(of: .search) { run(query, filter: nil) }
      .task(id: query) {
        // 200 ms debounce; failures just mean no suggestions.
        guard !query.isEmpty, query != submitted else {
          suggestions = []
          return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let fetched = await env.suggestions.suggestions(for: query)
        guard !Task.isCancelled, query != submitted else { return }
        suggestions = fetched
      }
      .onChange(of: model?.page?.chips) { _, chips in
        if filter == nil, let chips, !chips.isEmpty { baseChips = chips }
      }
      .withRoutes()
    }
  }

  @ViewBuilder
  private var chipBar: some View {
    if !baseChips.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            ForEach(baseChips) { chip in
              let selected = chip.filter == filter || (filter == nil && chip.filter == nil)
              Button(chip.title) {
                run(submitted ?? query, filter: chip.filter)
              }
              .buttonStyle(.glass)
              .tint(selected ? .accentColor : nil)
              .fontWeight(selected ? .semibold : .regular)
            }
          }
        }
        .padding(.vertical, 4)
      }
      .scrollClipDisabled()
    }
  }

  private func run(_ text: String, filter: SearchFilter?) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if trimmed != submitted { baseChips = [] }
    submitted = trimmed
    self.filter = filter
    suggestions = []
    model = FeedModel(key: .search(trimmed, filter))
  }
}
