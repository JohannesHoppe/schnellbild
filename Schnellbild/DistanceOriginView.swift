import SwiftUI

/// The place to sort by distance from: coordinates in any common form or a
/// map link, pasted or typed (`GeoPoint.parse`). Shows what it read before
/// ↩ sorts; nothing goes online.
struct DistanceOriginView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private var point: GeoPoint? { GeoPoint.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sort by Distance").font(.headline)
            Text("Coordinates (48.137, 11.575 or 48°8′14″N 11°34′27″E) or a link from Apple Maps, Google Maps or OpenStreetMap:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Coordinates or map link", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier("distanceOriginField")
                .onSubmit(sort)
            Group {
                if let point {
                    Label(point.text, systemImage: "mappin.and.ellipse")
                        .foregroundStyle(.primary)
                } else if GeoPoint.isShortMapLink(text) {
                    Text("A short link only says where it leads once it is opened online. Open it in the browser and paste the full address.")
                        .foregroundStyle(.secondary)
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No coordinates found").foregroundStyle(.secondary)
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("distanceOriginParsed")
            HStack {
                Spacer()
                Button { model.distanceOriginRequested = false } label: { HStack(spacing: 6) { Text("Cancel"); KeyCap("esc") } }
                    .keyboardShortcut(.cancelAction)
                Button(action: sort) { HStack(spacing: 6) { Text("Sort"); KeyCap("↩") } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(point == nil)
                    .accessibilityIdentifier("distanceOriginSort")
            }
        }
        .padding(20)
        .frame(width: 420)
        // (the pasteboard isn't read by itself: macOS asks the user before an app reads it)
        .onAppear { fieldFocused = true }
    }

    private func sort() {
        guard let point else { return }
        model.distanceOriginRequested = false
        model.setDistanceOrigin(point)
    }
}
