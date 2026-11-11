import SwiftUI

/// シートの大きさ。Mac のシートは中身の理想の大きさで開くので、高さを持たない一覧（List・Form）は空に潰れる。
/// 決まった大きさで開いて、中身を広げる（iPhone のシートは画面の幅いっぱいなので効かない。iPad は Mac と同じく効く）
enum SheetSize {
    /// 入力欄を並べるシート（依頼・指示・開始）
    case form
    /// 読むものが多いシート（質問・判断・札の詳しく）
    case page
}

extension View {
    @ViewBuilder func sheetSize(_ size: SheetSize) -> some View {
        switch size {
        case .form: presentationSizing(.form)
        case .page: presentationSizing(.page)
        }
    }
}
