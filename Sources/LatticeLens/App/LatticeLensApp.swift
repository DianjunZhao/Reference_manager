import SwiftUI

@main
struct LatticeLensApp: App {
    @StateObject private var viewModel: AppViewModel
    private let initialWindowSize: CGSize

    init() {
        // Resolve the launch configuration at the app boundary so the UI-test
        // process cannot accidentally construct the production dependency
        // graph before fixture mode is applied.
        _viewModel = StateObject(wrappedValue: AppViewModel(
            useFixtureDependencies: AppLaunchConfiguration.usesFixtureDependencies
        ))
        initialWindowSize = AppLaunchConfiguration.fixtureWindowSize ?? CGSize(width: 1_440, height: 900)
    }

    var body: some Scene {
        WindowGroup("LatticeLens") {
            MainWorkspaceView(viewModel: viewModel)
                // v5 supports the documented compact research-cockpit floor;
                // wider layouts remain preferred but must not make every
                // action unreachable below the old 1120pt hard minimum.
                .frame(minWidth: 820, minHeight: 640)
                .task { await viewModel.start() }
        }
        .defaultSize(width: initialWindowSize.width, height: initialWindowSize.height)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("LatticeLens 设置…") { viewModel.presentSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
