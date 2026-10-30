import XCTest

/// A damaged record in the data folder, as the sidebar shows it.
final class BackupUITests: AcceptanceCase {
    func test_BACKUP_07() {
        given.samLeeAndADamagedRecordForJaneDoe()

        let sidebar = when.lookAtTheSidebar()

        then(sidebar).saysOneRecordCouldntBeRead()
        then(sidebar).stillListsThePatient("Sam Lee")
        then(when.reviewTheDamagedRecord(from: sidebar)).opensOnScreen()
    }
}
