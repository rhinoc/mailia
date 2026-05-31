import Foundation

enum MailiaAppResources {
    static var bundle: Bundle {
        for url in candidateBundleURLs {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.module
    }

    private static var candidateBundleURLs: [URL] {
        let bundleName = "Mailia_MailiaApp.bundle"
        let mainBundleURL = Bundle.main.bundleURL
        var urls: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(bundleName))
        }
        urls.append(mainBundleURL.appendingPathComponent(bundleName))

        return urls
    }
}
