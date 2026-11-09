import AppKit
import ArborCore

/// A date column's day range (FE-039): a calendar for the pointer, From and To for the keyboard.
final class DateRangeFilterView: NSStackView {
    private(set) var range: DayRange?
    var onChange: (DayRange?) -> Void = { _ in }
    /// The caption or a date changed, so the dropdown may need another width.
    var onContentChange: () -> Void = {}
    var firstField: NSView { fromField }

    private let context: GroupingContext
    private let monthCalendar = NSDatePicker()
    private let fromField = NSDatePicker()
    private let toField = NSDatePicker()
    private let status = NSTextField(labelWithString: "")
    private lazy var clearButton = NSButton(title: L10n.tr("Clear Date Range"), target: self, action: #selector(clearRange))

    private var calendar: Calendar { context.calendar }

    init(range: DayRange?, context: GroupingContext) {
        self.range = range
        self.context = context
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        configure(monthCalendar, style: .clockAndCalendar, mode: .range, label: L10n.tr("Calendar"), action: #selector(calendarChanged))
        // No stepper: AppKit's has no accessible name, and the arrow keys already step the focused element.
        configure(fromField, style: .textField, mode: .single, label: L10n.tr("From"), action: #selector(fieldChanged))
        configure(toField, style: .textField, mode: .single, label: L10n.tr("To"), action: #selector(fieldChanged))
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.font = Theme.bodyFont
        status.textColor = Theme.secondaryText
        let fields = NSGridView(views: [[NSTextField(labelWithString: L10n.tr("From")), fromField],
                                        [NSTextField(labelWithString: L10n.tr("To")), toField]])
        fields.rowSpacing = 6
        fields.columnSpacing = 8
        fields.rowAlignment = .firstBaseline
        [monthCalendar, fields, status, clearButton].forEach(addArrangedSubview)
        seedCalendar()
        seedFields()
        showApplied()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// One calendar for all three controls, so what is shown and what is filtered agree.
    private func configure(_ picker: NSDatePicker, style: NSDatePicker.Style, mode: NSDatePicker.Mode, label: String, action: Selector) {
        picker.datePickerStyle = style
        picker.datePickerMode = mode
        picker.datePickerElements = .yearMonthDay
        picker.calendar = calendar
        picker.timeZone = calendar.timeZone
        picker.locale = calendar.locale ?? .current
        picker.font = Theme.bodyFont
        picker.setAccessibilityLabel(label)
        picker.target = self
        picker.action = action
    }

    // Setting values sends no action, so opening the dropdown never creates a filter.
    private func seedCalendar() {
        let selection = range?.pickerSelection(calendar: calendar) ?? (anchor: context.now, span: 0)
        monthCalendar.dateValue = selection.anchor
        monthCalendar.timeInterval = selection.span
    }

    private func seedFields() {
        fromField.dateValue = range?.start ?? context.now
        toField.dateValue = range?.lastInstant ?? context.now
    }

    /// The caption, not the calendar's highlighted day, says whether a filter is active.
    private func showApplied() {
        status.stringValue = range?.title(calendar: calendar) ?? L10n.tr("No date range")
        clearButton.isEnabled = range != nil
    }

    // Only the other controls are re-seeded (`reseed`): resetting the sender would interrupt a drag or typing.
    private func apply(_ candidate: DayRange?, reseed: () -> Void) {
        defer { onContentChange() }
        guard let candidate else {
            status.stringValue = L10n.tr("Choose a range of up to 100 years.")
            return
        }
        let changed = candidate != range
        range = candidate
        showApplied()
        guard changed else { return }
        onChange(candidate)
        reseed()
    }

    @objc private func calendarChanged() {
        apply(DayRange(from: monthCalendar.dateValue, spanning: monthCalendar.timeInterval, calendar: calendar), reseed: seedFields)
    }

    // From and To stay independent: both change one element at a time while a date is typed.
    @objc private func fieldChanged() {
        apply(DayRange(from: fromField.dateValue, through: toField.dateValue, calendar: calendar), reseed: seedCalendar)
    }

    @objc private func clearRange() {
        range = nil
        seedCalendar()
        seedFields()
        showApplied()
        onChange(nil)
        onContentChange()
    }

    // MARK: Scripted checks: set a control and send its real action

    func scriptSelectInCalendar(from day: Date, days: Int) {
        monthCalendar.dateValue = day
        monthCalendar.timeInterval = TimeInterval(days) * 86_400
        monthCalendar.sendAction(monthCalendar.action, to: monthCalendar.target)
    }

    func scriptSetFields(from: Date, to: Date) {
        fromField.dateValue = from
        toField.dateValue = to
        fromField.sendAction(fromField.action, to: fromField.target)
    }
}
