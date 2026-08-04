import SwiftUI

/// In-app YouTube search + download into the offline library.
struct BrowseView: View {
    @ObservedObject private var search = YouTubeSearchService.shared
    @ObservedObject private var downloads = YouTubeDownloadService.shared
    @ObservedObject private var stream = YouTubeStreamService.shared
    @State private var query = ""
    @State private var hasSearched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Browse")
                .font(.system(size: 34, weight: .bold))

            searchField

            if !downloads.isAvailable {
                unavailableBanner
            }

            if let error = stream.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            content
        }
        .padding(20)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TextField("Cari lagu di YouTube…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(runSearch)
            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
        .clipShape(Capsule())
        .frame(maxWidth: 420)
    }

    private var unavailableBanner: some View {
        HStack(spacing: 8) {
            Text("yt-dlp / ffmpeg tidak ditemukan")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.red)
            Button("Buka Preferences") {
                NotificationCenter.default.post(name: Notification.Name("ShowSettingsWindow"), object: nil)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06).cornerRadius(8))
    }

    @ViewBuilder private var content: some View {
        if search.isSearching {
            Spacer()
            ProgressView()
                .frame(maxWidth: .infinity)
            Spacer()
        } else if let error = search.errorMessage {
            Spacer()
            VStack(spacing: 10) {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                Button("Retry", action: runSearch)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else if search.results.isEmpty {
            Spacer()
            Text(hasSearched ? "Tidak ada hasil." : "Cari lagu di YouTube untuk menambahkannya ke library.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(search.results) { result in
                        resultRow(result)
                        Divider()
                    }
                }
            }
        }
    }

    private func resultRow(_ result: YouTubeSearchResult) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    Color.primary.opacity(0.05)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text(result.channel)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let duration = result.duration {
                Text(timeString(duration))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Button {
                stream.play(result)
            } label: {
                if stream.resolvingID == result.id {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 18))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .help("Putar (stream, tidak masuk library)")
            .disabled(stream.resolvingID == result.id)

            actionButton(result)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func actionButton(_ result: YouTubeSearchResult) -> some View {
        if downloads.finishedIDs.contains(result.id) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.green)
        } else if downloads.activeID == result.id {
            if case .downloading(let progress) = downloads.state {
                ProgressView(value: progress / 100)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            }
        } else if downloads.pending.contains(where: { $0.id == result.id }) {
            Image(systemName: "clock")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
        } else {
            Button {
                downloads.enqueue(YouTubeDownloadService.QueuedDownload(
                    id: result.id,
                    title: result.title,
                    artist: result.channel,
                    target: result.url
                ))
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Download ke library")
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasSearched = true
        search.search(trimmed)
    }
}
