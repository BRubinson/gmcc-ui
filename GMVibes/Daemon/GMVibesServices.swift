import SwiftUI
import Observation

/// The app's shared service singletons in one container, injected by a single
/// modifier at every scene root — adding a service later is zero call-site
/// churn. Views keep their existing granular @Environment bindings
/// (GMCCEnvironment / FileTreeStore / DaemonConnectionModel / CatalogStore).
@Observable @MainActor
final class GMVibesServices {
    let env: GMCCEnvironment
    let fileTrees: FileTreeStore
    let daemon: DaemonConnectionModel
    let catalog: CatalogStore
    /// Session recency (one unfiltered FILE_CHANGE_LIST fold).
    let activity: SessionActivityModel
    /// Checked-out branch per instance (.git/HEAD reader + DispatchSource).
    let checkout: CheckoutWatcher

    init() {
        env = GMCCEnvironment()
        fileTrees = FileTreeStore.shared
        daemon = DaemonConnectionModel()
        catalog = CatalogStore()
        activity = SessionActivityModel()
        checkout = CheckoutWatcher()
    }
}

extension View {
    /// Inject the shared GMCC services into a scene's root view in one call.
    func gmccEnv(_ services: GMVibesServices) -> some View {
        self
            .environment(services.env)
            .environment(services.fileTrees)
            .environment(services.daemon)
            .environment(services.catalog)
            .environment(services.activity)
            .environment(services.checkout)
    }
}
