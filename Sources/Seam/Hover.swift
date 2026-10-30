import SwiftUI

/// Soft rounded highlight that fades in under the pointer.
struct Hoverable: ViewModifier {
    let corner: CGFloat
    @StateObject private var hover = Local(false)

    func body(content: Content) -> some View {
        content
            .background(Workspace.shared.theme.dim.opacity(hover.value ? 0.16 : 0), in: RoundedRectangle(cornerRadius: corner))
            .animation(.easeOut(duration: 0.12), value: hover.value)
            .onHover { hover.value = $0 }
    }
}

extension View {
    func hoverable(_ corner: CGFloat = 6) -> some View { modifier(Hoverable(corner: corner)) }
}

/// A file or folder icon that follows the monochrome-icons setting.
struct FileIcon: View {
    let item: FileItem
    let size: CGFloat
    private let ws = Workspace.shared

    var body: some View {
        Image(nsImage: Icons.icon(for: item))
            .resizable()
            .saturation(ws.monoIcons ? 0 : 1)
            .colorMultiply(ws.monoIcons ? ws.theme.tint : .white)
            .frame(width: size, height: size)
    }
}
