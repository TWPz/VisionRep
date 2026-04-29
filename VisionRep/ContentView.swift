import SwiftUI

struct ContentView: View {
    @State private var session = WorkoutSessionModel()

    var body: some View {
        WorkoutDashboardView(model: session)
    }
}

#Preview {
    ContentView()
}
