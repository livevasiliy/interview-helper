import SwiftUI

/// Text styles for the Setup and Settings windows, following Apple's macOS typographic scale
/// (Human Interface Guidelines › Typography): body 13 pt for what people read and edit, callout 12 pt for
/// messages that need attention, subheadline 11 pt for explanations under controls. Nothing goes below
/// 11 pt: footnote and caption styles (10 pt) are the HIG minimum and too small for text people must read.
/// The overlay scales from the user's own text-size setting instead (see OverlayView).
enum Typography {
    /// Explanations under a control, hints, short field labels (secondary color).
    static let helper = Font.subheadline
    /// Errors, warnings, status lines and notices: smaller than body, bigger than a hint.
    static let notice = Font.callout
    /// A key cap in the shortcut list.
    static let shortcutKey = Font.system(.callout, design: .monospaced).weight(.semibold)
}
