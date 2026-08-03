import SwiftUI

struct OnboardingView: View {

    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "sailboat.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                Text("Welcome to Voyage Focus")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("Set up Voyage Focus to manage your breaks while you work.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()

                Button {
                    showSetup = true
                } label: {
                    Text("Set Up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(28)
            .navigationDestination(isPresented: $showSetup) {
                PermissionSetupView()
            }
        }
    }
}
