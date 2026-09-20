import AppKit
import SwiftUI
import ImageIO

struct HotspotChrome: ViewModifier {
    let part: AhaKeyStudioPart
    let selectedPart: AhaKeyStudioPart
    let dirtyParts: Set<AhaKeyStudioPart>

    func body(content: Content) -> some View {
        let isSelected = selectedPart == part
        content
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    // 非选中时几乎隐形，避免每个 hotspot 都画一圈灰线和邻近元件视觉打架
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.black.opacity(0.015),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if dirtyParts.contains(part) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .padding(8)
                }
            }
            // 选中态阴影从 10 收到 6，减少向邻近元件溢出的发光半径
            .shadow(color: isSelected ? Color.accentColor.opacity(0.18) : .clear, radius: 6)
    }
}

struct OLEDMotionPreviewSheet: View {
    let modeTitle: String
    let assetPath: String?
    let fps: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "text.9b0749974bdd", defaultValue: "\(String(describing: modeTitle)) 动图预览"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(String(localized: "text.7b5a955722ce", defaultValue: "这里展示的是你刚选中的 GIF 动图文件。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "text.3fd47edce45b", defaultValue: "关闭")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.92))

                if let assetPath {
                    DraggableAnimatedGIFPreview(path: assetPath, fps: fps)
                        .padding(12)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: {
                            if #available(macOS 14, *) { "film.stack" } else { "film" }
                        }())
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "text.1f4f655d1c6e", defaultValue: "还没有选择动图"))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                        .frame(minWidth: 480, minHeight: 240)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 460)
            .clipped()
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 380)
    }
}

/// 支持鼠标按住拖拽（上下左右）查看大图，避免仅靠滚轮导致横向浏览困难。
struct DraggableAnimatedGIFPreview: View {
    let path: String
    let fps: Int
    @State private var imageSize = CGSize(width: 480, height: 240)
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            AnimatedGIFView(path: path, fps: fps, maxPixelSize: 1_200)
                .frame(width: imageSize.width, height: imageSize.height)
                .position(
                    x: viewportSize.width / 2 + offset.width,
                    y: viewportSize.height / 2 + offset.height
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let proposed = CGSize(
                                width: dragStartOffset.width + value.translation.width,
                                height: dragStartOffset.height + value.translation.height
                            )
                            offset = clampOffset(proposed, imageSize: imageSize, viewportSize: viewportSize)
                        }
                        .onEnded { _ in
                            dragStartOffset = offset
                        }
                )
                .onAppear {
                    reloadImageSizeAndResetOffset()
                }
                .onChange(of: path) { _ in
                    reloadImageSizeAndResetOffset()
                }
        }
    }

    private func reloadImageSizeAndResetOffset() {
        if let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 {
            imageSize = image.size
        } else {
            imageSize = CGSize(width: 480, height: 240)
        }
        offset = .zero
        dragStartOffset = .zero
    }

    private func clampOffset(_ proposed: CGSize, imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        let maxX = max(0, (imageSize.width - viewportSize.width) / 2)
        let maxY = max(0, (imageSize.height - viewportSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

// MARK: - 帮助中心（内嵌弹窗）
