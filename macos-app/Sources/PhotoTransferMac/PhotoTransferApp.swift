import SwiftUI

@main
struct PhotoTransferApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1220, minHeight: 860)
        }
        .windowResizability(.contentSize)
    }
}
