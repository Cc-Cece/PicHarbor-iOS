import SwiftUI
import Photos
import PhotosUI
import AVKit

private struct AssetSelection: Identifiable { var asset: PHAsset; var id: String { asset.localIdentifier } }

struct LibraryView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var filter = "all"
    @State private var album = ""
    @State private var detail: AssetSelection?
    @State private var confirm = false
    var assets: [PHAsset] {
        var values = model.library.assets
        if !album.isEmpty {
            var settings = BackupSettings(); settings.selectedAlbums = [album]
            values = model.library.scope(settings)
        }
        return values.filter { filter == "all" || (filter == "video" ? $0.mediaType == .video : filter == "live" ? $0.mediaSubtypes.contains(.photoLive) : $0.mediaType == .image) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.library.status == .authorized || model.library.status == .limited {
                if model.library.status == .limited {
                    HStack { Label(L10n.text("仅显示已授权内容"), systemImage: "lock"); Spacer(); Button(L10n.text("管理")) { model.library.manageLimited() } }.font(.caption).padding().background(Color(uiColor: .secondarySystemGroupedBackground))
                }
                HStack {
                    Menu {
                        Button(L10n.text("全部可访问项目")) { album = "" }
                        ForEach(model.library.albums) { group in Button("\(group.title) · \(group.count)") { album = group.id } }
                    } label: { Label(model.library.albums.first(where: { $0.id == album })?.title ?? L10n.text("最近项目"), systemImage: "chevron.down").font(.subheadline.bold()) }
                    Spacer()
                    Text(L10n.text("{0} 项", [String(describing: assets.count.formatted())])).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal).padding(.vertical, 10)
                if assets.isEmpty { ContentUnavailableView(L10n.text("没有可显示的项目"), systemImage: "photo", description: Text(L10n.text("调整筛选条件或相册访问权限。"))) }
                else {
                    PhotoGrid(assets: assets, manager: model.library.images, selecting: selecting, selected: selected, states: model.assetStates, account: model.account) { asset in
                        if selecting {
                            if selected.contains(asset.localIdentifier) { selected.remove(asset.localIdentifier) } else { selected.insert(asset.localIdentifier) }
                        } else { detail = AssetSelection(asset: asset) }
                    }
                }
                if selecting {
                    HStack {
                        Text(L10n.text("已选择 {0} 项", [String(describing: selected.count)])).font(.subheadline)
                        Spacer()
                        Button(L10n.text("备份"), systemImage: "icloud.and.arrow.up") { confirm = true }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || model.account.isEmpty)
                    }.padding().background(.bar)
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.text("你的照片，尽在这里"), systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(L10n.text("允许访问后，直接浏览并备份照片、视频与 Live Photo。也可以仅授权部分内容。"))
                } actions: {
                    Button(L10n.text("允许访问相册")) { Task { await model.library.authorize() } }.buttonStyle(.borderedProminent)
                    if model.library.status == .denied || model.library.status == .restricted {
                        Button(L10n.text("打开系统设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }
                }
            }
        }
        .navigationTitle(L10n.text("照片"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu { Picker(L10n.text("媒体类型"), selection: $filter) { Text(L10n.text("全部")).tag("all"); Text(L10n.text("照片")).tag("photo"); Text(L10n.text("视频")).tag("video"); Text("Live Photo").tag("live") } } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel(L10n.text("筛选照片"))
            }
            ToolbarItem(placement: .topBarTrailing) { Button(selecting ? L10n.text("完成") : L10n.text("选择")) { selecting.toggle(); if !selecting { selected = [] } } }
            if selecting { ToolbarItem(placement: .bottomBar) { Button(L10n.text("选择当前范围全部")) { selected = Set(assets.map(\.localIdentifier)) } } }
        }
        .sheet(item: $detail) { item in NavigationStack { AssetDetailView(asset: item.asset) }.environmentObject(model) }
        .confirmationDialog(L10n.text("备份已选项目"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L10n.text("开始备份 {0} 项", [String(describing: selected.count)])) { Task {
                await model.enqueue(model.library.assets.filter { selected.contains($0.localIdentifier) }); selecting = false; selected = []
            } }
        } message: { Text("\(model.settings.quality.title) · \(model.settings.live.title)\n\(model.settings.edits.title)") }
    }
}

private struct PhotoGrid: UIViewRepresentable {
    let languageCode = L10n.language.rawValue
    var assets: [PHAsset]
    let manager: PHCachingImageManager
    var selecting: Bool
    var selected: Set<String>
    var states: [String: AssetBackupState]
    var account: String
    var tapped: (PHAsset) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout(); layout.minimumInteritemSpacing = 2; layout.minimumLineSpacing = 2
        let grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        grid.backgroundColor = .systemBackground
        grid.register(PhotoCell.self, forCellWithReuseIdentifier: "photo")
        grid.dataSource = context.coordinator; grid.delegate = context.coordinator
        return grid
    }
    func updateUIView(_ grid: UICollectionView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        if previous.languageCode != languageCode || previous.assets.map({ $0.localIdentifier + PhotoLibrary.stamp($0) }) != assets.map({ $0.localIdentifier + PhotoLibrary.stamp($0) }) { grid.reloadData() }
        else {
            for path in grid.indexPathsForVisibleItems {
                guard path.item < assets.count, let cell = grid.cellForItem(at: path) as? PhotoCell else { continue }
                cell.badge.text = selecting ? (selected.contains(assets[path.item].localIdentifier) ? "✓" : "○") : ""
                cell.applyState(state(for: assets[path.item]), selecting: selecting, skipped: states[assets[path.item].localIdentifier]?.skipped == true)
                cell.accessibilityTraits = selected.contains(assets[path.item].localIdentifier) ? [.button, .selected] : .button
            }
        }
    }
    func state(for asset: PHAsset) -> JobState? {
        guard let value = states[asset.localIdentifier], value.account == account, value.revision == PhotoLibrary.stamp(asset) else { return nil }
        return value.state
    }
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: PhotoGrid
        init(_ parent: PhotoGrid) { self.parent = parent }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { parent.assets.count }
        func collectionView(_ grid: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = max(1, floor((grid.bounds.width - 4) / 3)); return CGSize(width: width, height: width)
        }
        func collectionView(_ grid: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = grid.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! PhotoCell
            let asset = parent.assets[indexPath.item]
            cell.configure(asset, manager: parent.manager)
            cell.badge.text = parent.selecting ? (parent.selected.contains(asset.localIdentifier) ? "✓" : "○") : ""
            cell.applyState(parent.state(for: asset), selecting: parent.selecting, skipped: parent.states[asset.localIdentifier]?.skipped == true)
            cell.accessibilityTraits = parent.selected.contains(asset.localIdentifier) ? [.button, .selected] : .button
            return cell
        }
        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { parent.tapped(parent.assets[indexPath.item]) }
    }
}

private final class PhotoCell: UICollectionViewCell {
    let image = UIImageView(), badge = UILabel(), subtitle = UILabel()
    let cloud = UIImageView()
    var request: PHImageRequestID?
    var representedID = ""
    weak var manager: PHCachingImageManager?
    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFill; image.clipsToBounds = true; image.backgroundColor = .secondarySystemBackground
        badge.textColor = .white; badge.font = .systemFont(ofSize: 25, weight: .bold); badge.textAlignment = .right
        subtitle.textColor = .white; subtitle.font = .preferredFont(forTextStyle: .caption2); subtitle.adjustsFontForContentSizeCategory = true
        cloud.tintColor = .white; cloud.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8); cloud.layer.cornerRadius = 5; cloud.contentMode = .scaleAspectFit
        for view in [image, badge, subtitle, cloud] { view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: contentView.topAnchor), image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), image.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6), badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6), subtitle.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            cloud.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6), cloud.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6), cloud.widthAnchor.constraint(equalToConstant: 25), cloud.heightAnchor.constraint(equalToConstant: 22)
        ])
        isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func applyState(_ state: JobState?, selecting: Bool, skipped: Bool = false) {
        cloud.isHidden = selecting || state == nil || state == .cancelled
        accessibilityValue = state == .completed && skipped ? L10n.text("已存在，跳过") : state?.title
        guard let state else { return }
        let symbol = state == .paired ? "checkmark.circle.fill" : state == .completed ? "checkmark.icloud.fill" : state == .failed || state == .attention ? "exclamationmark.icloud" : state == .paused ? "pause.circle.fill" : "icloud.and.arrow.up"
        cloud.tintColor = state == .paired ? .systemBlue : state == .completed ? (skipped ? .systemGray : .systemGreen) : .white
        cloud.backgroundColor = (state == .paired || state == .completed ? UIColor.black : UIColor.systemBlue).withAlphaComponent(0.8)
        cloud.image = UIImage(systemName: symbol)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        if let request { manager?.cancelImageRequest(request) }
        request = nil; representedID = ""; image.image = nil
    }
    func configure(_ asset: PHAsset, manager: PHCachingImageManager) {
        if let request { self.manager?.cancelImageRequest(request) }
        self.manager = manager; representedID = asset.localIdentifier
        subtitle.text = asset.mediaType == .video ? String(format: "%d:%02d", Int(asset.duration) / 60, Int(asset.duration) % 60) : asset.mediaSubtypes.contains(.photoLive) ? "◉ LIVE" : ""
        accessibilityLabel = "\(asset.mediaType == .video ? "视频" : asset.mediaSubtypes.contains(.photoLive) ? "Live Photo" : "照片")，\(asset.creationDate.map { L10n.date($0, time: .short) } ?? "")"
        let options = PHImageRequestOptions(); options.deliveryMode = .opportunistic; options.resizeMode = .fast; options.isNetworkAccessAllowed = false
        request = manager.requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFill, options: options) { [weak self] image, _ in
            DispatchQueue.main.async { if self?.representedID == asset.localIdentifier { self?.image.image = image } }
        }
    }
}

struct AssetDetailView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @Environment(\.dismiss) private var dismiss
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var live: PHLivePhoto?
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var previewError = false
    @State private var previewRequest: PHImageRequestID?
    @State private var information = false
    @State private var filename = false
    @State private var sizes: [Int: Int64] = [:]
    @State private var sizeFailed = false
    @State private var downloadSize = false
    @State private var sizeReadID = UUID()
    @State private var sharing = false
    @State private var shareReady = false
    @State private var shareError = false
    @State private var shareProvider: NSItemProvider?
    @State private var shareFailure = ""
    @State private var shareFiles: [URL] = []
    @State private var shareDirectory: URL?
    @State private var shareTask: Task<Void, Never>?
    @State private var shareControl: ExportControl?
    var resources: [PHAssetResource] { AssetInformation.resources(asset) }
    var name: String { resources.first?.originalFilename ?? L10n.text("照片或视频") }
    var typeName: String { asset.mediaSubtypes.contains(.photoLive) ? "Live Photo" : asset.mediaType == .video ? L10n.text("视频") : L10n.text("照片") }
    var sizeText: String {
        if !resources.isEmpty && sizes.count == resources.count { return ByteCountFormatter.string(fromByteCount: sizes.values.reduce(0, +), countStyle: .file) }
        return sizeFailed ? L10n.text("原件暂不可用，可能需要从 iCloud 下载。") : L10n.text("正在读取大小…")
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player { VideoPlayer(player: player) }
                else if let live { LivePreview(photo: live) }
                else if let image { Image(uiImage: image).resizable().scaledToFit() }
                if loading { ProgressView().tint(.white) }
                if previewError { Text(L10n.text("预览暂不可用，原件可能需要从 iCloud 下载。")).foregroundStyle(.white).padding() }
            }
            VStack(alignment: .leading, spacing: 12) {
                Button { filename = true } label: { Text(name).font(.headline).lineLimit(1).truncationMode(.middle) }.buttonStyle(.plain)
                    .contextMenu { Button(L10n.text("复制文件名"), systemImage: "doc.on.doc") { UIPasteboard.general.string = name } }
                Text(asset.creationDate.map { L10n.date($0, date: .long, time: .short) } ?? L10n.text("照片详情")).font(.headline)
                Text(sizeText + " · " + typeName).font(.subheadline).foregroundStyle(.secondary)
                if sizeFailed { Button(L10n.text("下载原件并读取大小")) { downloadSize = true; sizeReadID = UUID() } }
                if sharing { HStack { ProgressView(); Text(L10n.text("正在准备分享，可能需要下载原件…")); Button(L10n.text("取消")) { shareControl?.cancel("JOB_PAUSED"); shareTask?.cancel() } }.font(.caption) }
                Button { Task { await model.enqueue([asset]) } } label: { Label(L10n.text("备份此项目"), systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(model.account.isEmpty)
                if let job = model.visibleJobs.first(where: { $0.assetID == asset.localIdentifier }) { NavigationLink { JobDetailView(id: job.id) } label: { Label(job.displayStatus, systemImage: "clock") } }
            }.padding()
        }
        .navigationTitle(L10n.text("照片详情")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { dismiss() } }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { information = true } label: { Image(systemName: "info.circle") }.accessibilityLabel(L10n.text("详情")).accessibilityIdentifier("photo.info")
                Button { prepareShare() } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(L10n.text("分享")).disabled(sharing).accessibilityIdentifier("photo.share")
            }
        }
        .sheet(isPresented: $information) { NavigationStack { AssetInformationView(asset: asset, resources: resources, sizes: sizes) }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $filename) { NavigationStack { ScrollView { Text(name).textSelection(.enabled).padding() }.navigationTitle(L10n.text("完整文件名")).toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { filename = false } } } }.presentationDetents([.medium]) }
        .sheet(isPresented: $shareReady, onDismiss: cleanShare) { if let shareProvider { AssetShareSheet(provider: shareProvider) } }
        .alert(L10n.text("暂时无法分享"), isPresented: $shareError) { Button(L10n.text("好"), role: .cancel) {} } message: { Text(shareFailure) }
        .task(id: sizeReadID) {
            sizes = [:]; sizeFailed = false
            do {
                guard !resources.isEmpty else { throw HarborError("RESOURCE_MISSING") }
                for (index, resource) in resources.enumerated() {
                    let size = try await AssetByteRequest().size(resource, network: downloadSize)
                    try Task.checkCancellation(); sizes[index] = size
                }
            } catch { if !Task.isCancelled { sizeFailed = true } }
        }
        .onAppear { load() }.onDisappear {
            player?.pause()
            if let request = previewRequest { model.library.images.cancelImageRequest(request) }
            if !shareReady { shareControl?.cancel("JOB_PAUSED"); shareTask?.cancel() }
        }
    }
    private func cleanShare() {
        if let shareDirectory { try? FileManager.default.removeItem(at: shareDirectory) }
        shareDirectory = nil; shareFiles = []; shareProvider = nil
    }
    private func prepareShare() {
        guard !sharing else { return }
        sharing = true
        let control = ExportControl(wifiOnly: false); shareControl = control
        shareTask = Task { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Share-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard !resources.isEmpty else { throw HarborError("RESOURCE_MISSING") }
                var files: [URL] = []
                for (index, resource) in resources.enumerated() {
                    try Task.checkCancellation()
                    let folder = directory.appendingPathComponent(String(index)); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent((resource.originalFilename as NSString).lastPathComponent)
                    try await PhotoResourceWriter.write(resource: resource, url: url, control: control); files.append(url)
                }
                try Task.checkCancellation()
                let photo = asset.mediaSubtypes.contains(.photoLive) ? try await AssetShareItems.livePhoto(files: files) : nil
                let provider = try AssetShareItems.provider(files: files, live: photo)
                try Task.checkCancellation()
                shareDirectory = directory; shareFiles = files; shareProvider = provider; shareReady = true
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if !Task.isCancelled {
                    shareFailure = (error as? HarborError)?.code == "LIVE_SHARE_UNAVAILABLE" ? L10n.text("系统暂时无法提供动态照片分享，请从苹果相册分享此项目。") : L10n.text("请检查照片权限、网络和可用空间后重试。")
                    shareError = true
                }
            }
            sharing = false; shareControl = nil
        }
    }
    private func load() {
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = true
            previewRequest = model.library.images.requestPlayerItem(forVideo: asset, options: options) { value, _ in
                Task { @MainActor in loading = false; previewError = value == nil; if let value { player = AVPlayer(playerItem: value) } }
            }
        } else if asset.mediaSubtypes.contains(.photoLive) {
            let options = PHLivePhotoRequestOptions(); options.isNetworkAccessAllowed = true
            previewRequest = model.library.images.requestLivePhoto(for: asset, targetSize: CGSize(width: 1200, height: 1600), contentMode: .aspectFit, options: options) { value, info in
                Task { @MainActor in live = value; loading = info?[PHImageResultIsDegradedKey] as? Bool == true; previewError = value == nil && !loading }
            }
        } else {
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
            previewRequest = model.library.images.requestImage(for: asset, targetSize: CGSize(width: 1600, height: 2000), contentMode: .aspectFit, options: options) { value, info in
                Task { @MainActor in image = value; loading = info?[PHImageResultIsDegradedKey] as? Bool == true; previewError = value == nil && !loading }
            }
        }
    }
}

private struct LivePreview: UIViewRepresentable {
    let photo: PHLivePhoto
    func makeUIView(context: Context) -> PHLivePhotoView { let view = PHLivePhotoView(); view.contentMode = .scaleAspectFit; return view }
    func updateUIView(_ view: PHLivePhotoView, context: Context) { view.livePhoto = photo }
}
