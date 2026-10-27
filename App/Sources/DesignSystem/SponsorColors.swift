import MioTubeCore
import SwiftUI

extension SponsorCategory {
  /// SponsorBlock's default category colours, so segments read the same as in the browser
  /// extension.
  var color: Color {
    switch self {
    case .sponsor: Color(red: 0, green: 0.83, blue: 0)
    case .selfpromo: Color(red: 1, green: 1, blue: 0)
    case .exclusiveAccess: Color(red: 0, green: 0.54, blue: 0.36)
    case .interaction: Color(red: 0.8, green: 0, blue: 1)
    case .poiHighlight: Color(red: 1, green: 0.09, blue: 0.52)
    case .intro: Color(red: 0, green: 1, blue: 1)
    case .outro: Color(red: 0.01, green: 0.01, blue: 0.93)
    case .preview: Color(red: 0, green: 0.56, blue: 0.84)
    case .hook: Color(red: 0.22, green: 0.34, blue: 0.6)
    case .filler: Color(red: 0.45, green: 0, blue: 1)
    case .chapter: Color.white
    case .musicOfftopic: Color(red: 1, green: 0.6, blue: 0)
    }
  }
}
