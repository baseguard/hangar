import SwiftUI

struct ColumnWidth {
    let min: CGFloat
    let ideal: CGFloat
    var max: CGFloat?

    static let time = ColumnWidth(min: 60, ideal: 70, max: 90)
    static let number = ColumnWidth(min: 56, ideal: 72, max: 100)
    static let wideNumber = ColumnWidth(min: 60, ideal: 100, max: 120)
    static let name = ColumnWidth(min: 160, ideal: 260)
    static let address = ColumnWidth(min: 100, ideal: 150)
}

extension TableColumn {
    func width(_ width: ColumnWidth) -> TableColumn<RowValue, Sort, Content, Label> {
        self.width(min: width.min, ideal: width.ideal, max: width.max)
    }
}
