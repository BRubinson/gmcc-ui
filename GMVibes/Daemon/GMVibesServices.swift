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
    /// Checked-out session per instance (DispatchSource push edge +
    /// daemon-side INSTANCE_CURRENT_SESSION resolution).
    let checkout: CheckoutWatcher

    init() {
        env = GMCCEnvironment()
        fileTrees = FileTreeStore.shared
        daemon = DaemonConnectionModel()
        catalog = CatalogStore()
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
            .environment(services.checkout)
    }
}
