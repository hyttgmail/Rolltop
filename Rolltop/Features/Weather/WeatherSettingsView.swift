import SwiftUI

/// Settings › Weather: the switch (its caption says where the location goes), the current
/// report with Open-Meteo's attribution, and the place search.
struct WeatherSettingsView: View {
    let provider: WeatherFeatureProvider
    let settings: SettingsStore

    @State private var query = ""
    @State private var results: [WeatherFeaturePlace] = []
    @State private var searchFailed = false

    var body: some View {
        let enabled = settings[WeatherFeatureSettings.enabled]
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings[WeatherFeatureSettings.enabled] },
                                     set: { settings[WeatherFeatureSettings.enabled] = $0 })) {
                    Text("Show the weather", tableName: "Weather")
                    Text("Rolltop sends the approximate location of the place you choose to Open-Meteo (open-meteo.com), a free weather service, to get the forecast. Open-Meteo’s servers may log it with your IP address. Nothing is sent while this is off.",
                         tableName: "Weather")
                }
            }
            if enabled {
                currentSection
                placeSection
            }
        }
        .formStyle(.grouped)
        .task(id: query) { await search() }
    }

    @ViewBuilder private var currentSection: some View {
        Section {
            if let report = provider.report {
                LabeledContent {
                    Text(Self.temperature(report.temperature))
                        .font(.title2)
                } label: {
                    Label {
                        Text(report.placeName)
                    } icon: {
                        Image(systemName: report.symbolName)
                    }
                    Text("\(report.condition.localizedName), feels like \(Self.temperature(report.apparentTemperature)), high \(Self.temperature(report.todayHigh)), low \(Self.temperature(report.todayLow))",
                         tableName: "Weather")
                }
            } else if provider.place == nil {
                Text("Choose a place", tableName: "Weather")
                    .foregroundStyle(.secondary)
            } else if provider.lastError == nil {
                Text("Loading…", tableName: "Weather")
                    .foregroundStyle(.secondary)
            }
            if let error = provider.lastError, provider.place != nil {
                Text(error).foregroundStyle(.secondary)
            }
            if provider.report != nil {
                let attribution = provider.attribution
                Link(attribution.text, destination: attribution.url)
            }
        } header: {
            Text("Now", tableName: "Weather")
        }
    }

    @ViewBuilder private var placeSection: some View {
        Section {
            if let place = provider.place {
                LabeledContent {
                    Button {
                        settings.reset(WeatherFeatureSettings.place)
                    } label: {
                        Text("Remove", tableName: "Weather")
                    }
                } label: {
                    Text(place.name)
                    if !place.detail.isEmpty { Text(place.detail) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField(text: $query, prompt: Text("Search for a city", tableName: "Weather")) {
                    Text("Search for a city", tableName: "Weather")
                }
                .labelsHidden()
                Text("What you type is sent to Open-Meteo to find matching places.", tableName: "Weather")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if searchFailed {
                Text("Couldn’t search for places. Try again.", tableName: "Weather")
                    .foregroundStyle(.secondary)
            }
            ForEach(results, id: \.self) { place in
                Button {
                    settings[WeatherFeatureSettings.place] = place
                    query = ""
                    results = []
                } label: {
                    VStack(alignment: .leading) {
                        Text(place.name)
                        if !place.detail.isEmpty {
                            Text(place.detail).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Place", tableName: "Weather")
        } footer: {
            Text("The chosen place is saved with your settings and included in backups.", tableName: "Weather")
        }
    }

    /// Waits for typing to pause, then asks Open-Meteo's place search.
    private func search() async {
        searchFailed = false
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let found = try await provider.searchPlaces(query)
            guard !Task.isCancelled else { return }
            results = found
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchFailed = true
        }
    }

    /// Whole degrees in the user's temperature unit.
    static func temperature(_ value: Measurement<UnitTemperature>) -> String {
        value.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
