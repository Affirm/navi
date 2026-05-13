import SwiftUI

/// Base sizes are multiplied by this scale. Default 1.0, stored in UserDefaults.
private var naviScale: CGFloat {
    CGFloat(UserDefaults.standard.object(forKey: "NaviFontScale") as? Double ?? 1.0)
}

func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
    .system(size: size * naviScale, weight: weight, design: design)
}
