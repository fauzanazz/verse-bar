import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Albums section: grid of album cards → detail view. Navigation is local
/// `@State` (the view already sits inside the split view's detail column).
struct AlbumsView: View {
    @ObservedObject private var service = AlbumService.shared
    @State private var selectedAlbumID: String?
    @State private var editing: Album?
    @State private var isCreating = false
    @State private var albumToDelete: Album?

    var body: some View {
        if let albumID = selectedAlbumID, let album = service.albums.first(where: { $0.id == albumID }) {
            AlbumDetailView(
                album: album,
                onBack: { selectedAlbumID = nil },
                onEdit: { editing = album }
            )
        } else {
            grid
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Albums")
                    .font(.system(size: 34, weight: .bold))
                Spacer()
                Button {
                    isCreating = true
                } label: {
                    Label("New Album", systemImage: "plus")
                }
            }

            ScrollView {
                if service.albums.isEmpty {
                    Text("Belum ada album.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(service.albums) { album in
                            card(album)
                        }
                    }
                }
            }
        }
        .padding(20)
        .confirmationDialog("Hapus Album?", isPresented: deleteDialogPresented, presenting: albumToDelete) { album in
            Button("Hapus", role: .destructive) {
                service.delete(id: album.id)
                if selectedAlbumID == album.id { selectedAlbumID = nil }
            }
        } message: { album in
            Text("“\(album.title)” akan dihapus. Lagunya tetap ada di Library.")
        }
        .sheet(isPresented: $isCreating) { AlbumEditorSheet(album: nil) }
        .sheet(item: $editing) { AlbumEditorSheet(album: $0) }
    }

    private func card(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(album, width: 160)
            Text(album.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(album.trackIDs.count) songs")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(width: 160, alignment: .leading)
        .onTapGesture { selectedAlbumID = album.id }
        .contextMenu {
            Button("Edit") { editing = album }
            Button("Delete Album", role: .destructive) { albumToDelete = album }
        }
    }

    @ViewBuilder
    private func cover(_ album: Album, width: CGFloat) -> some View {
        if let image = service.cover(for: album) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "square.stack")
                .font(.system(size: width * 0.3))
                .foregroundColor(.secondary)
                .frame(width: width, height: width)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { albumToDelete != nil },
            set: { if !$0 { albumToDelete = nil } }
        )
    }
}

/// Create/edit sheet. `album == nil` means create; otherwise the sheet is
/// seeded from the existing album (cover included).
struct AlbumEditorSheet: View {
    let album: Album?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var cover: NSImage?
    @State private var coverCleared = false

    init(album: Album?) {
        self.album = album
        _title = State(initialValue: album?.title ?? "")
        _description = State(initialValue: album?.description ?? "")
        _cover = State(initialValue: album.flatMap { AlbumService.shared.cover(for: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(album == nil ? "New Album" : "Edit Album")
                .font(.system(size: 17, weight: .semibold))

            HStack(spacing: 12) {
                coverPreview
                VStack(alignment: .leading, spacing: 8) {
                    Button("Choose Image…") { chooseImage() }
                    if cover != nil {
                        Button("Remove") {
                            cover = nil
                            coverCleared = true
                        }
                    }
                }
            }

            TextField("Album title", text: $title)

            Text("Description")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextEditor(text: $description)
                .frame(height: 70)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(album == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private var coverPreview: some View {
        if let cover {
            Image(nsImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "square.stack")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
                .frame(width: 120, height: 120)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            cover = image
            coverCleared = false
        }
    }

    private func save() {
        if let album {
            AlbumService.shared.update(
                id: album.id,
                title: title,
                description: description,
                cover: cover,
                clearCover: coverCleared
            )
        } else {
            _ = AlbumService.shared.create(title: title, description: description, cover: cover)
        }
        dismiss()
    }
}
