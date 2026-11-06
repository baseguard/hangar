import Foundation
import HangarSupport
import Testing

struct AppExtensionBundleTests {
    @Test func theShareExtensionHandsFilesOnlyToTheAppItIsIn() {
        let bundled = URL(fileURLWithPath: "/Applications/Hangar.app/Contents/PlugIns/HangarShare.appex")
        let loose = URL(fileURLWithPath: "/Users/someone/Downloads/HangarShare.appex")
        let elsewhere = URL(fileURLWithPath: "/Applications/Hangar.app/Contents/Resources/HangarShare.appex")
        let notAnApp = URL(fileURLWithPath: "/Applications/Hangar/Contents/PlugIns/HangarShare.appex")

        #expect(AppExtensionBundle.containingApp(of: bundled)?.path == "/Applications/Hangar.app")
        #expect(AppExtensionBundle.containingApp(of: loose) == nil)
        #expect(AppExtensionBundle.containingApp(of: elsewhere) == nil)
        #expect(AppExtensionBundle.containingApp(of: notAnApp) == nil)
    }
}
