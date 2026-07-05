import SwiftUI

/// Configurable daily trip briefings, delivered as local notifications.
struct NotificationSettingsView: View {
    @AppStorage(BriefingSettings.enabledKey) private var enabled = false
    @AppStorage(BriefingSettings.minutesFromMidnightKey) private var minutesFromMidnight = 450
    @AppStorage(BriefingSettings.prepMinutesKey) private var prepMinutes = 60
    @AppStorage(BriefingSettings.eveningPreviewKey) private var eveningPreview = false

    private var briefingTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: minutesFromMidnight / 60,
                    minute: minutesFromMidnight % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minutesFromMidnight = (components.hour ?? 7) * 60 + (components.minute ?? 30)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Daily trip briefings", isOn: $enabled)
            } footer: {
                Text("Each morning of a trip: the day's stops, the weather and what to wear, and when to wake up and leave.")
            }

            if enabled {
                Section("Timing") {
                    DatePicker("Briefing time", selection: briefingTime, displayedComponents: .hourAndMinute)
                    Picker("Getting-ready time", selection: $prepMinutes) {
                        Text("30 min").tag(30)
                        Text("45 min").tag(45)
                        Text("1 hour").tag(60)
                        Text("1.5 hours").tag(90)
                        Text("2 hours").tag(120)
                    }
                }

                Section {
                    Toggle("Evening preview", isOn: $eveningPreview)
                } footer: {
                    Text("Also get tomorrow's plan the night before at 9 PM — useful for setting an alarm.")
                }
            }
        }
        .navigationTitle("Daily briefings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: enabled) { rescheduleBriefings() }
        .onChange(of: minutesFromMidnight) { rescheduleBriefings() }
        .onChange(of: prepMinutes) { rescheduleBriefings() }
        .onChange(of: eveningPreview) { rescheduleBriefings() }
    }

    private func rescheduleBriefings() {
        Task { await BriefingScheduler.shared.refresh() }
    }
}
