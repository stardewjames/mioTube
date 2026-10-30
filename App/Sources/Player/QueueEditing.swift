import SwiftUI
import UniformTypeIdentifiers

extension View {
  /// Long-press-and-drag reordering for a queue row. `dragged` holds the row being moved.
  func queueReorder(id: QueueItem.ID, dragged: Binding<QueueItem.ID?>, coordinator: PlaybackCoordinator) -> some View {
    onDrag {
      dragged.wrappedValue = id
      return NSItemProvider(object: id.uuidString as NSString)
    }
    .onDrop(of: [.plainText], delegate: QueueReorderDelegate(target: id, dragged: dragged, coordinator: coordinator))
  }
}

/// Moves the dragged row onto each row the drag enters, so the list reorders live.
struct QueueReorderDelegate: DropDelegate {
  let target: QueueItem.ID
  @Binding var dragged: QueueItem.ID?
  let coordinator: PlaybackCoordinator

  func dropEntered(info: DropInfo) {
    guard let dragged, dragged != target else { return }
    coordinator.moveQueueItem(dragged, onto: target)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    dragged = nil
    return true
  }
}

/// Swipe left to remove. Only leftward drags move the row; rightward drags are ignored.
/// For rows outside a `List`, where native `swipeActions` isn't available.
struct SwipeToRemove: ViewModifier {
  let onRemove: () -> Void

  @State private var offset: CGFloat = 0
  private let removeThreshold: CGFloat = 150

  init(onRemove: @escaping () -> Void) {
    self.onRemove = onRemove
  }

  func body(content: Content) -> some View {
    content
      .offset(x: offset)
      .background(alignment: .trailing) {
        ZStack {
          Color.red
          Image(systemName: "trash")
            .font(.title3)
            .foregroundStyle(.white)
        }
        .frame(width: max(0, -offset))
        .frame(maxHeight: .infinity)
        .opacity(offset < 0 ? 1 : 0)
        .accessibilityHidden(true)
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 12)
          .onChanged { value in
            guard isLeftward(value.translation) else {
              offset = 0
              return
            }
            offset = max(value.translation.width, -removeThreshold)
          }
          .onEnded { value in
            if isLeftward(value.translation), value.translation.width <= -removeThreshold {
              onRemove()
            }
            withAnimation(.snappy) { offset = 0 }
          }
      )
      .accessibilityAction(named: "Remove from queue", onRemove)
  }

  private func isLeftward(_ translation: CGSize) -> Bool {
    translation.width < 0 && abs(translation.width) > abs(translation.height)
  }
}
