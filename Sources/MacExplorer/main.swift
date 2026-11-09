import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // `swift run` ile paketlenmeden başlatılsa da normal bir uygulama gibi davran.
    app.setActivationPolicy(.regular)
    app.run()
}
