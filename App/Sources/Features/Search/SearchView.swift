import MioTubeCore
import SwiftUI

struct SearchView: View {
  @Environment(AppEnvironment.self) private var env
  @State private var query = ""
  @State private var searchPresented = false
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
          .id(ObjectIdentifier(model))
        } else if !env.searchHistory.queries.isEmpty {
          recentSearches
        } else {
          ContentUnavailableView("Search YouTube", systemImage: "magnifyingglass", description: Text("No ads, no tracking pixels — just results."))
        }
      }
      .navigationTitle("Search")
      .searchable(text: $query, isPresented: $searchPresented, prompt: "Videos, channels, playlists")
      .searchSuggestions {
        let recent = env.searchHistory.matching(query)
        if !recent.isEmpty {
          Section("Recent searches") {
            ForEach(recent, id: \.self) { text in
              recentSearch(text)
            }
            Button("Clear history", role: .destructive) { env.searchHistory.removeAll() }
          }
        }
        let remote = suggestions.filter { suggestion in
          !recent.contains { $0.caseInsensitiveCompare(suggestion) == .orderedSame }
        }
        if !remote.isEmpty {
          Section("Suggestions") {
            ForEach(remote, id: \.self) { suggestion in
              Label(suggestion, systemImage: "magnifyingglass").searchCompletion(suggestion)
            }
          }
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

  private var recentSearches: some View {
    List {
      Section {
        ForEach(env.searchHistory.queries, id: \.self) { text in
          recentSearch(text)
            .swipeActions {
              Button("Delete", systemImage: "trash", role: .destructive) {
                env.searchHistory.remove(text)
              }
            }
        }
      } header: {
        HStack {
          Text("Recent searches")
          Spacer()
          Button("Clear history", role: .destructive) { env.searchHistory.removeAll() }
        }
      } footer: {
        Text("Saved on this device only.")
      }
    }
    .listStyle(.plain)
  }

  private func recentSearch(_ text: String) -> some View {
    Button {
      query = text
      run(text, filter: nil)
    } label: {
      Label(text, systemImage: "clock.arrow.circlepath")
    }
    .contextMenu {
      Button("Remove from history", systemImage: "trash", role: .destructive) {
        env.searchHistory.remove(text)
      }
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
    // A YouTube link pasted into search opens the target instead of searching for it.
    if let link = YouTubeLink(string: trimmed) {
      env.open(link)
      return
    }
    if trimmed != submitted { baseChips = [] }
    query = trimmed
    searchPresented = false
    if filter == nil { env.searchHistory.record(trimmed) }
    submitted = trimmed
    self.filter = filter
    suggestions = []
    model = FeedModel(key: .search(trimmed, filter))
  }
}
