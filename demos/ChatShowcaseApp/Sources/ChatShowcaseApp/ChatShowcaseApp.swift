import SwiftUI

@main
struct ChatShowcaseApp: App {
  var body: some Scene {
    WindowGroup {
      ChatView(viewModel: ChatViewModel())
    }
  }
}
