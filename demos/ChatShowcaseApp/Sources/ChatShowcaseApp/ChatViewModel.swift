import Foundation
import Observation
import PhotosUI
import PhoenixNectar
import SwiftUI
import UIKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ChatMessage: Identifiable, Sendable {
  let id: String
  let fromUserID: String
  let body: String?
  let imageData: Data?
}

struct InspectorEntry: Identifiable, Sendable {
  let id: String
  let title: String
  let detail: String
}

private struct PreparedImageAsset {
  let uploadData: Data
  let previewData: Data
}

private enum ImagePreparationConfig {
  static let maxUploadBytes = 700_000
  static let maxPreviewDimension: CGFloat = 1600
  static let minimumDimensionScale: CGFloat = 0.08
}

struct MessagePosted: Decodable, Sendable {
  let id: String
  let from_user_id: String
  let body: String
}

struct SendMessageRequest: Encodable, Sendable {
  let body: String
}

struct SendReply: Decodable, Sendable {
  let message_id: String
  let accepted: Bool
}

struct ConnectParams: Encodable, Sendable {
  let device_id: String
}

@MainActor
@Observable
final class ChatViewModel {
  var endpoint: String = "ws://127.0.0.1:4000/socket"
  var roomID: String = "engineering"
  var userID: String = "demo-user"
  var composer: String = ""
  var status: String = "idle"
  var messages: [ChatMessage] = []
  var inspectorEntries: [InspectorEntry] = []
  var connected: Bool = false
  var selectedImageData: Data?
  var selectedPreviewImage: UIImage?

  private var client: Socket?
  private var channel: Channel?
  private var receiveTask: Task<Void, Never>?
  private var imageTask: Task<Void, Never>?
  private var selectedPreparedAsset: PreparedImageAsset?

  func connectAndJoin() async {
    if connected { return }

    do {
      let client = try Socket(
        endpoint: endpoint,
        connectParamsProvider: { ConnectParams(device_id: "chat-showcase-ios") },
        authTokenProvider: { [userID] in "user:\(userID)" }
      )

      try await client.connect()
      let topic = Topic("private:room:\(roomID)")
      let channel = try await client.joinChannel(topic)
      appendInspector("phx_join", detail: "topic=\(topic.rawValue)")

      let posted = Event<MessagePosted>("message:posted")
      let postedStream = await channel.subscribe(to: posted)

      let imageStream = await channel.subscribeBinary(to: "image:posted")

      receiveTask = Task { [weak self] in
        do {
          for try await next in postedStream {
            guard !Task.isCancelled else { return }
            await MainActor.run {
              self?.messages.append(.init(id: next.id, fromUserID: next.from_user_id, body: next.body, imageData: nil))
              self?.appendInspector(
                "message:posted",
                detail: "topic=\(topic.rawValue) from=\(next.from_user_id) chars=\(next.body.count)"
              )
            }
          }
        } catch {
          await MainActor.run {
            self?.status = "stream error: \(error.localizedDescription)"
          }
        }
      }

      imageTask = Task { [weak self] in
        for await payload in imageStream {
          guard !Task.isCancelled else { continue }
          await MainActor.run {
            self?.messages.append(
              .init(
                id: UUID().uuidString,
                fromUserID: "image",
                body: nil,
                imageData: payload
              )
            )
            self?.status = "image received: \(payload.count) bytes"
            self?.appendInspector(
              "image:posted",
              detail: "topic=\(topic.rawValue) bytes=\(payload.count)"
            )
          }
        }
      }

      self.client = client
      self.channel = channel
      self.connected = true
      self.status = "connected"
      appendInspector("phx_reply", detail: "status=ok topic=\(topic.rawValue)")
    } catch {
      status = "connect failed: \(error.localizedDescription)"
      appendInspector("connect:error", detail: error.localizedDescription)
    }
  }

  func disconnect() async {
    receiveTask?.cancel()
    receiveTask = nil
    imageTask?.cancel()
    imageTask = nil

    if let client {
      await client.disconnect(code: 1000, reason: "user_disconnected")
    }

    channel = nil
    client = nil
    connected = false
    status = "disconnected"
    appendInspector("disconnect", detail: "code=1000 reason=user_disconnected")
  }

  func send() async {
    guard let channel, !composer.isEmpty else { return }

    do {
      let postMessage = Push<SendMessageRequest, SendReply>("message:send")
      appendInspector("push", detail: "event=message:send chars=\(composer.count)")
      let reply = try await channel.push(postMessage, payload: SendMessageRequest(body: composer))
      status = reply.accepted ? "sent \(reply.message_id)" : "rejected"
      appendInspector("phx_reply", detail: "event=message:send status=\(reply.accepted ? "ok" : "error") id=\(reply.message_id)")
      composer = ""
    } catch {
      status = "send failed: \(error.localizedDescription)"
      appendInspector("push:error", detail: "event=message:send \(error.localizedDescription)")
    }
  }

  func previewSelectedPhoto(_ item: PhotosPickerItem?) async {
    guard let item else {
      selectedImageData = nil
      selectedPreviewImage = nil
      selectedPreparedAsset = nil
      return
    }

    do {
      status = "preparing image..."
      guard let data = try await item.loadTransferable(type: Data.self) else {
        selectedImageData = nil
        selectedPreviewImage = nil
        selectedPreparedAsset = nil
        status = "no image selected"
        return
      }

      let prepared = await Task.detached(priority: .userInitiated) {
        Self.prepareImageAsset(from: data)
      }.value

      guard let prepared else {
        selectedImageData = nil
        selectedPreviewImage = nil
        selectedPreparedAsset = nil
        status = "image too large after compression"
        appendInspector("image:prepare", detail: "failed size=\(data.count)")
        return
      }

      selectedPreparedAsset = prepared
      selectedImageData = prepared.previewData
      selectedPreviewImage = UIImage(data: prepared.previewData)
      status = "image ready: \(prepared.uploadData.count) bytes"
      appendInspector("image:prepare", detail: "original=\(data.count) prepared=\(prepared.uploadData.count)")
    } catch {
      status = "preview failed: \(error.localizedDescription)"
      appendInspector("image:preview:error", detail: error.localizedDescription)
    }
  }

  func uploadSelectedPhoto(_ item: PhotosPickerItem?) async {
    guard let channel, let item else { return }

    do {
      let uploadData: Data

      if let selectedPreparedAsset {
        uploadData = selectedPreparedAsset.uploadData
      } else {
        status = "preparing image..."
        guard let data = try await item.loadTransferable(type: Data.self) else {
          status = "no image selected"
          return
        }

        let prepared = await Task.detached(priority: .userInitiated) {
          Self.prepareImageAsset(from: data)
        }.value

        guard let prepared else {
          selectedImageData = nil
          selectedPreviewImage = nil
          selectedPreparedAsset = nil
          status = "image too large after compression"
          appendInspector("binary:upload", detail: "failed original=\(data.count)")
          return
        }

        selectedPreparedAsset = prepared
        selectedImageData = prepared.previewData
        selectedPreviewImage = UIImage(data: prepared.previewData)
        uploadData = prepared.uploadData
      }

      appendInspector("push", detail: "event=binary:upload bytes=\(uploadData.count)")
      let reply = try await channel.pushBinary("binary:upload", data: uploadData)
      status = reply.status == .ok ? "image uploaded: \(uploadData.count) bytes" : "image upload rejected"
      appendInspector("phx_reply", detail: "event=binary:upload status=\(reply.status.rawValue) bytes=\(uploadData.count)")
    } catch {
      status = "image upload failed: \(error.localizedDescription)"
      appendInspector("push:error", detail: "event=binary:upload \(error.localizedDescription)")
    }
  }

  var selectedUIImage: UIImage? {
    selectedPreviewImage
  }

  private nonisolated static func prepareImageAsset(from sourceData: Data) -> PreparedImageAsset? {
    if sourceData.count <= ImagePreparationConfig.maxUploadBytes {
      return .init(uploadData: sourceData, previewData: sourceData)
    }

    guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
          let baseImage = downsampledImage(from: source, maxDimension: ImagePreparationConfig.maxPreviewDimension)
    else {
      return nil
    }

    let dimensionScales: [CGFloat] = [1.0, 0.85, 0.7, 0.55, 0.4, 0.3, 0.2, 0.12]

    for scale in dimensionScales {
      let candidate = scale < 1.0 ? resizedImage(baseImage, scale: scale) : baseImage
      if let data = compressedJPEGData(for: candidate), data.count <= ImagePreparationConfig.maxUploadBytes {
        return .init(uploadData: data, previewData: data)
      }
    }

    var candidate = baseImage
    while max(CGFloat(candidate.width), CGFloat(candidate.height)) > 1 {
      candidate = resizedImage(candidate, scale: 0.75)
      if let data = compressedJPEGData(for: candidate), data.count <= ImagePreparationConfig.maxUploadBytes {
        return .init(uploadData: data, previewData: data)
      }
      let currentScale = max(
        CGFloat(candidate.width) / max(CGFloat(baseImage.width), 1),
        CGFloat(candidate.height) / max(CGFloat(baseImage.height), 1)
      )
      if currentScale <= ImagePreparationConfig.minimumDimensionScale {
        break
      }
    }

    return nil
  }

  private nonisolated static func downsampledImage(from source: CGImageSource, maxDimension: CGFloat) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxDimension
    ]

    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private nonisolated static func resizedImage(_ image: CGImage, scale: CGFloat) -> CGImage {
    let clampedScale = max(0.05, min(scale, 1.0))
    let width = max(1, Int(round(CGFloat(image.width) * clampedScale)))
    let height = max(1, Int(round(CGFloat(image.height) * clampedScale)))
    let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = image.bitmapInfo.rawValue == 0
      ? CGImageAlphaInfo.premultipliedLast.rawValue
      : image.bitmapInfo.rawValue

    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    ) else {
      return image
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
  }

  private nonisolated static func compressedJPEGData(for image: CGImage) -> Data? {
    let qualities: [CGFloat] = [0.75, 0.6, 0.45, 0.3, 0.2, 0.12]
    for quality in qualities {
      if let data = jpegData(for: image, quality: quality), data.count <= ImagePreparationConfig.maxUploadBytes {
        return data
      }
    }

    return jpegData(for: image, quality: 0.08)
  }

  private nonisolated static func jpegData(for image: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }

    let options: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality
    ]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }

    return data as Data
  }

  private func appendInspector(_ title: String, detail: String) {
    inspectorEntries.insert(.init(id: UUID().uuidString, title: title, detail: detail), at: 0)
    if inspectorEntries.count > 24 {
      inspectorEntries.removeLast(inspectorEntries.count - 24)
    }
  }
}

struct ChatView: View {
  @State var viewModel: ChatViewModel
  @State private var selectedPhoto: PhotosPickerItem?

  var body: some View {
    NavigationStack {
      ZStack {
        LinearGradient(
          colors: [
            Color(red: 0.97, green: 0.91, blue: 0.84),
            Color(red: 0.96, green: 0.97, blue: 0.92),
            Color(red: 0.84, green: 0.92, blue: 0.94)
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        ScrollView {
          VStack(spacing: 18) {
            heroCard
            connectionCard
            transcriptCard
            composerCard
            inspectorCard
            if let selectedUIImage = viewModel.selectedUIImage {
              previewCard(image: selectedUIImage)
            }
          }
          .padding(.horizontal, 18)
          .padding(.vertical, 20)
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .onChange(of: selectedPhoto) { _, newPhoto in
        Task { await viewModel.previewSelectedPhoto(newPhoto) }
      }
    }
  }

  private var heroCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Phoenix Nectar")
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(Color(red: 0.56, green: 0.28, blue: 0.18))

          Text("Shared room chat, with images and live presence.")
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.15, green: 0.18, blue: 0.22))

          Text("Use the same room on web and iOS with different users. Messages and image uploads stay in one transcript.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 12)

        statusPill
      }

      HStack(spacing: 10) {
        MetricTile(title: "Room", value: viewModel.roomID)
        MetricTile(title: "User", value: viewModel.userID)
      }
    }
    .padding(22)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(Color.white.opacity(0.5), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.08), radius: 22, x: 0, y: 12)
  }

  private var connectionCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Connection")
        .font(.headline)

      VStack(spacing: 10) {
        LabeledField(title: "Endpoint") {
          TextField("Endpoint", text: $viewModel.endpoint)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.callout.monospaced())
        }

        AdaptivePairStack {
          LabeledField(title: "Room") {
            TextField("Room", text: $viewModel.roomID)
          }

          LabeledField(title: "User") {
            TextField("User", text: $viewModel.userID)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
        }
      }

      AdaptivePairStack {
        ActionButton(title: "Connect", systemImage: "bolt.horizontal.circle.fill", prominent: true) {
          Task { await viewModel.connectAndJoin() }
        }
        .disabled(viewModel.connected)

        ActionButton(title: "Disconnect", systemImage: "xmark.circle", prominent: false) {
          Task { await viewModel.disconnect() }
        }
        .disabled(!viewModel.connected)
      }
    }
    .cardStyle()
  }

  private var transcriptCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Transcript")
          .font(.headline)
        Spacer()
        Text("\(viewModel.messages.count) items")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      if viewModel.messages.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("No messages yet")
            .font(.headline)
            .foregroundStyle(Color(red: 0.24, green: 0.28, blue: 0.33))
          Text("Connect both demos to the same room, then send text or image messages.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
      } else {
        LazyVStack(spacing: 12) {
          ForEach(viewModel.messages) { message in
            MessageBubble(message: message, isCurrentUser: message.fromUserID == viewModel.userID)
          }
        }
      }
    }
    .cardStyle()
  }

  private var composerCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Composer")
        .font(.headline)

      TextField("Type a message", text: $viewModel.composer, axis: .vertical)
        .lineLimit(1...4)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

      AdaptiveActionLayout(
        primary: {
          ActionButton(title: "Send", systemImage: "paperplane.fill", prominent: true) {
            Task { await viewModel.send() }
          }
          .disabled(!viewModel.connected || viewModel.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        },
        secondary: {
          PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Label("Pick Image", systemImage: "photo.on.rectangle")
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.9)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(SecondaryCapsuleButtonStyle())
          .disabled(!viewModel.connected)
        },
        tertiary: {
          ActionButton(title: "Upload", systemImage: "arrow.up.circle.fill", prominent: false) {
            Task { await viewModel.uploadSelectedPhoto(selectedPhoto) }
          }
          .disabled(!viewModel.connected || selectedPhoto == nil)
        }
      )

      Text(viewModel.status)
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color(red: 0.30, green: 0.35, blue: 0.40))
    }
    .cardStyle()
  }

  private func previewCard(image: UIImage) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Upload Preview")
        .font(.headline)
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxHeight: 240)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    .cardStyle()
  }

  private var inspectorCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Wire Inspector")
        .font(.headline)

      Text("Recent Phoenix channel traffic from the demo client.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if viewModel.inspectorEntries.isEmpty {
        Text("No events yet.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      } else {
        LazyVStack(spacing: 10) {
          ForEach(viewModel.inspectorEntries) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.title)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color(red: 0.60, green: 0.29, blue: 0.18))
              Text(entry.detail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Color(red: 0.25, green: 0.30, blue: 0.35))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          }
        }
      }
    }
    .cardStyle()
  }

  private var statusPill: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(viewModel.connected ? Color.green : Color.orange)
        .frame(width: 10, height: 10)
      Text(viewModel.connected ? "Live" : "Offline")
        .font(.caption.weight(.bold))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color.white.opacity(0.8), in: Capsule())
  }
}

private struct AdaptivePairStack<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        content
      }

      VStack(spacing: 10) {
        content
      }
    }
  }
}

private struct AdaptiveActionLayout<Primary: View, Secondary: View, Tertiary: View>: View {
  @ViewBuilder let primary: Primary
  @ViewBuilder let secondary: Secondary
  @ViewBuilder let tertiary: Tertiary

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        primary
        secondary
        tertiary
      }

      VStack(spacing: 10) {
        primary

        HStack(spacing: 10) {
          secondary
          tertiary
        }
      }

      VStack(spacing: 10) {
        primary
        secondary
        tertiary
      }
    }
  }
}

private struct LabeledField<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }
}

private struct MetricTile: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

private struct MessageBubble: View {
  let message: ChatMessage
  let isCurrentUser: Bool

  var body: some View {
    VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: 6) {
      Text(message.fromUserID)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 10) {
        if let body = message.body {
          Text(body)
            .font(.body)
            .foregroundStyle(isCurrentUser ? Color.white : Color(red: 0.18, green: 0.22, blue: 0.26))
        }

        if let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
          Image(uiImage: uiImage)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
      }
      .padding(14)
      .frame(maxWidth: 320, alignment: .leading)
      .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: isCurrentUser ? .trailing : .leading)
  }

  private var bubbleBackground: LinearGradient {
    if isCurrentUser {
      return LinearGradient(
        colors: [Color(red: 0.96, green: 0.49, blue: 0.31), Color(red: 0.73, green: 0.27, blue: 0.22)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }

    return LinearGradient(
      colors: [Color.white.opacity(0.95), Color(red: 0.91, green: 0.95, blue: 0.96)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

private struct ActionButton: View {
  let title: String
  let systemImage: String
  let prominent: Bool
  let action: () -> Void

  var body: some View {
    Group {
      if prominent {
        Button(action: action) {
          Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryCapsuleButtonStyle())
      } else {
        Button(action: action) {
          Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryCapsuleButtonStyle())
      }
    }
  }
}

private struct PrimaryCapsuleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 18)
      .padding(.vertical, 13)
      .foregroundStyle(.white)
      .background(
        LinearGradient(
          colors: [Color(red: 0.93, green: 0.42, blue: 0.25), Color(red: 0.71, green: 0.23, blue: 0.22)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: Capsule()
      )
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.92 : 1)
  }
}

private struct SecondaryCapsuleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 18)
      .padding(.vertical, 13)
      .foregroundStyle(Color(red: 0.19, green: 0.24, blue: 0.29))
      .background(Color.white.opacity(0.82), in: Capsule())
      .overlay(
        Capsule()
          .stroke(Color.white.opacity(0.7), lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.92 : 1)
  }
}

private extension View {
  func cardStyle() -> some View {
    self
      .padding(20)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .stroke(Color.white.opacity(0.45), lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.07), radius: 18, x: 0, y: 10)
  }
}
