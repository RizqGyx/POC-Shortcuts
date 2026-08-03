import SwiftUI
import WidgetKit

/// Live Activities are rendered by a widget extension, not by the app — which is why this
/// fifth target exists. The app can start and end the activity, but the views live here.
@main
struct VoyageFocusWidgetBundle: WidgetBundle {
    var body: some Widget {
        BreakLiveActivity()
    }
}
