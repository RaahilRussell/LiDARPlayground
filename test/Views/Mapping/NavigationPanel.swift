import SwiftUI

struct NavigationPanel: View {
    @Bindable var navigation: NavigationController
    @State private var destinationName = ""

    init(controller: NavigationController) { self.navigation = controller }
    init(navigation: NavigationController) { self.navigation = navigation }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Walked-path directions", systemImage: "figure.walk")
                .font(.headline)
            Text("Experimental directions follow recorded paths. Keep the phone facing ahead. This cannot replace a mobility aid or confirm a path is safe.")
                .font(.caption).foregroundStyle(.secondary)
            Text(navigation.instruction)
                .font(.body).accessibilityLabel("Directions. \(navigation.instruction)")
            if navigation.routeActive {
                Button("Stop directions", role: .destructive) { navigation.cancelNavigation() }
                    .buttonStyle(.borderedProminent)
            }
            Toggle("Spoken directions", isOn: $navigation.spokenDirections)
            HStack {
                TextField("Destination, for example Bathroom", text: $destinationName)
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("Name this location")
                Button("Mark here") {
                    navigation.addLabel(name: destinationName)
                    if navigation.errorMessage == nil { destinationName = "" }
                }
                .disabled(destinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(navigation.capacityReached)
            ForEach(navigation.graph.labels) { label in
                Button { navigation.navigate(to: label.id) } label: {
                    Label("Go to \(label.name)", systemImage: "location")
                }
            }
            Button("Return to path start") { navigation.navigateToStart() }
                .disabled(navigation.graph.startNodeID == nil)
            if let error = navigation.errorMessage {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            if navigation.capacityReached {
                Text("Path recording is full. Existing directions remain available. Start a new place to record more paths.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
