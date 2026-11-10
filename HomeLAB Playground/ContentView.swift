//
//  ContentView.swift
//  HomeLAB Playground
//
//  REM: First screen = the app's name and its build. No stubs or "coming soon" rows —
//  REM: his rule: if a feature isn't finished, it is left out, not shown dead.
//  REM: Text is 18 pt at the default system size and scales with Dynamic Type
//  REM: (his 18 pt minimum rule).
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        // REM  C-010: the roles are Mac roles ("One Mac app, two roles"); iPhone and iPad keep the About screen.
        #if os(macOS)
        MacRootView()
        #else
        AboutView()
        #endif
    }
}

struct AboutView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("HomeLAB Playground")
                        .font(.system(size: titleSize, weight: .bold))
                        .accessibilityAddTraits(.isHeader)

                    Text("Build \(BuildStamp.buildNumber) · \(BuildStamp.commit)")
                        .font(.system(size: bodySize))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Build \(BuildStamp.buildNumber)")

                    Divider()

                    Text("About")
                        .font(.system(size: bodySize, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)

                    Text("This app uses no third-party code.")
                        .font(.system(size: bodySize))
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#Preview {
    ContentView()
}
