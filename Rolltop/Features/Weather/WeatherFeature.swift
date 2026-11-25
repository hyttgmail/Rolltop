import Foundation

/// Current weather from Open-Meteo for a place the user searches for; off by default;
/// provides `services[.weather]` for the Shelf card and the weather widget.
final class WeatherFeature: FeatureModule {
    static let id: FeatureID = "weather"

    private unowned let context: AppContext
    private let provider: WeatherFeatureProvider

    init(context: AppContext) {
        self.context = context
        provider = WeatherFeatureProvider(settings: context.settings, fetcher: WeatherFeatureSession())
        context.services.register(provider as any WeatherProviding, for: .weather)
    }

    func start() {
        provider.start()
    }

    func stop() {
        provider.stop()
    }

    var settingsPanes: [SettingsPane] {
        let provider = provider
        let settings = context.settings
        return [SettingsPane(id: "weather", title: LocalizedStringResource("Weather", table: "Weather"), symbol: "cloud.sun",
                             sortOrder: 245,
                             keywords: [LocalizedStringResource("weather, forecast, temperature, place, city, location, Open-Meteo",
                                                                table: "Weather", comment: "Settings search keywords, comma separated")]) {
            WeatherSettingsView(provider: provider, settings: settings)
        }]
    }

    var commands: [Command] {
        var commands: [Command] = []
        #if DEBUG
        commands.append(
            // Shows `WeatherReport.sample` (Greenwich) as if weather were on, without any
            // request; `clear=1` removes it. Memory only, settings stay untouched.
            Command(id: "weather.debug-inject", title: "Inject Sample Weather", symbol: "ladybug",
                    arguments: [CommandArgument(name: "clear", title: "Clear", allowedValues: ["1"])],
                    allowedFromURL: true) { [weak self] invocation in
                self?.provider.injected = invocation.string("clear") == "1" ? nil : .sample
            })
        #endif
        return commands
    }
}
