import AppKit
import ArborCore

/// Drive Properties ▸ File System (FE-188): what the drive's format can and can't do, read off the
/// main thread, with plain-language limits (read-only NTFS, FAT32's 4 GB files, no Trash…) so nothing
/// in Arbor promises what the drive can't deliver. A Mac addition: Windows shows only the format name.
final class FileSystemTab: PropertiesTab, PropertiesTabDebug {
    let title = L10n.tr("File System")
    let view: NSView
    private let model: PropertiesModel
    private let page = SheetPage()
    private let form = SheetForm(labelWidth: 230)
    private let status = SheetLabel.wrapping(L10n.tr("Reading the drive's capabilities…"), secondary: true)
    private var values: [NSTextField] = []
    private let notes = SheetLabel.wrapping("", secondary: false)
    private var work: DispatchWorkItem?
    private(set) var report: VolumeCapabilityReport?

    init(model: PropertiesModel) {
        self.model = model
        view = page
        form.add(SheetLabel.make(L10n.tr("File system capabilities"), bold: true))
        form.add(status)
        form.separator()
        // Rows are built once with placeholder values so the layout doesn't jump when values arrive.
        for row in VolumeCapabilityReport(format: FileSystemCapabilities(typeName: "", isReadOnly: false)).rows {
            let value = SheetLabel.make("…", selectable: true)
            values.append(value)
            form.row(row.label, value)
        }
        form.separator()
        form.add(notes)
        page.embed(form.stack)
        load()
    }

    private func load() {
        guard let url = model.single?.url else { return }
        let work = DispatchWorkItem { [weak self] in
            let report = VolumeCapabilityReport.read(url)
            DispatchQueue.main.async { self?.show(report) }
        }
        self.work = work
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    private func show(_ report: VolumeCapabilityReport?) {
        self.report = report
        guard let report else {
            status.stringValue = L10n.tr("The drive's capabilities couldn't be read. It may have been disconnected.")
            values.forEach { $0.stringValue = L10n.tr("Unknown") }
            return
        }
        status.stringValue = report.isReadOnly ? L10n.tr("This drive is read-only.") : L10n.tr("What this drive's format supports:")
        for (field, row) in zip(values, report.rows) { field.stringValue = row.value }
        let list = report.notes
        notes.stringValue = list.isEmpty ? "No limits worth noting." : list.map { "• " + $0 }.joined(separator: "\n")
    }

    func reload() {}
    func close() { work?.cancel() }

    var debugText: String {
        guard let report else { return "file system: \(status.stringValue)" }
        return (report.rows.map { "\($0.label) \($0.value)" } + ["notes: " + report.notes.joined(separator: " / ")]).joined(separator: "\n")
    }
}
