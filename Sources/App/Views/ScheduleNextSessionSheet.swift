import SwiftUI

/// The quick date shortcuts above the pickers. Pure date math so it can be
/// unit-tested: each one is "N days from today", keeping whatever time of day
/// is already chosen.
enum ScheduleQuickPick: CaseIterable, Identifiable {
    case nextWeek, inTwoWeeks, inFourWeeks

    var id: Self { self }

    var title: String {
        switch self {
        case .nextWeek: return "Next week"
        case .inTwoWeeks: return "In 2 weeks"
        case .inFourWeeks: return "In 4 weeks"
        }
    }

    var days: Int {
        switch self {
        case .nextWeek: return 7
        case .inTwoWeeks: return 14
        case .inFourWeeks: return 28
        }
    }

    /// The day this shortcut points at, with the hour and minute of `current`.
    func date(from now: Date, keepingTimeOf current: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: now) ?? now
        let time = calendar.dateComponents([.hour, .minute], from: current)
        return calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    /// Whether `current` already falls on the day this shortcut points at.
    func matches(_ current: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let day = calendar.date(byAdding: .day, value: days, to: now) else { return false }
        return calendar.isDate(current, inSameDayAs: day)
    }
}

/// The "Schedule next session" sheet: quick date shortcuts, a date, a time and
/// a length. The owner turns the chosen start and length into a calendar event.
///
/// The calendar event carries a title, a start and an end, so those are the
/// only things asked for here.
struct ScheduleNextSessionSheet: View {
    let patientName: String
    let lastSessionDate: Date
    @Binding var start: Date
    @Binding var durationMinutes: Int
    var onCancel: () -> Void
    var onSchedule: () -> Void

    private static let lengthOptions = [30, 45, 50, 60, 90]

    /// The standard lengths, plus the current one if it is somehow not among them.
    private var lengthChoices: [Int] {
        Self.lengthOptions.contains(durationMinutes)
            ? Self.lengthOptions
            : (Self.lengthOptions + [durationMinutes]).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                quickPicks
                HStack(alignment: .top, spacing: 12) {
                    labelled("Date") {
                        DatePicker("Date", selection: $start, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .padding(.horizontal, 12)
                            .themeField()
                    }
                    labelled("Time") {
                        DatePicker("Time", selection: $start, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .padding(.horizontal, 12)
                            .themeField()
                    }
                }
                // Same two-column grid as the date and time above.
                HStack(alignment: .top, spacing: 12) {
                    labelled("Length") {
                        Picker("Length", selection: $durationMinutes) {
                            ForEach(lengthChoices, id: \.self) { minutes in
                                Text("\(minutes) minutes").tag(minutes)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 20)
            footer
        }
        .frame(width: 480)
        .background(Theme.panel.color)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedule next session")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.text.color)
                    .accessibilityAddTraits(.isHeader)
                Text("\(patientName). Last session was \(lastSessionDate.formatted(date: .abbreviated, time: .omitted)).")
                    .font(Theme.Typography.control.weight(.regular))
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.themeIcon)
            .help("Close without scheduling")
        }
        .padding(.top, 22)
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    private var quickPicks: some View {
        HStack(spacing: 8) {
            ForEach(ScheduleQuickPick.allCases) { pick in
                Button(pick.title) {
                    start = pick.date(from: Date(), keepingTimeOf: start)
                }
                .buttonStyle(.themeFilterChip(isOn: pick.matches(start, now: Date())))
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Adds an event to your calendar.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("Schedule", action: onSchedule)
                .buttonStyle(.themePrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).eyebrowStyle()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
