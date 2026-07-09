import Foundation
import Network

let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_clipboardss._tcp", domain: "local."), using: .tcp)

browser.browseResultsChangedHandler = { results, _ in
    print("Results changed. count: \(results.count)")
    for result in results {
        print("Result endpoint: \(result.endpoint)")
        if case .service(let name, _, _, _) = result.endpoint {
            if case let .bonjour(txt) = result.metadata {
                print("TXT dictionary: \(txt.dictionary)")
            } else {
                print("Metadata is not bonjour. It is: \(result.metadata)")
            }
        }
    }
}

browser.start(queue: .main)
print("Starting browser...")
RunLoop.main.run(until: Date().addingTimeInterval(5))
print("Done.")
