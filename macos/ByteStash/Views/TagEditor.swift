import SwiftUI

/// Category chips with an inline field to add more. Categories are lower-cased by the server.
struct TagEditor: View {
    @Binding var tags: [String]
    var editable: Bool

    @State private var newTag = ""
    @FocusState private var focused: Bool

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text("#\(tag)")
                    if editable {
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "xmark").imageScale(.small)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            if editable {
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 80)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: newTag) { _, value in
                        if value.contains(",") { commit() }
                    }
            }
        }
    }

    private func commit() {
        let parts = newTag.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for part in parts where !part.isEmpty && !tags.contains(part) {
            tags.append(part)
        }
        newTag = ""
        focused = true
    }
}

/// Wraps children onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
