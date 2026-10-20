import Foundation

enum OfficialBossLinkService {
    static let home = URL(string: "https://www.zhipin.com/")!
    static let jobs = URL(string: "https://www.zhipin.com/web/geek/job")!
    static let chat = URL(string: "https://www.zhipin.com/web/geek/chat")!
    static let login = URL(string: "https://www.zhipin.com/web/user/?ka=header-login")!

    static func url(for job: JobListing) -> URL {
        guard let url = URL(string: job.url), isOfficialURL(url) else { return jobs }
        return url
    }

    static func isOfficialURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "zhipin.com" || host.hasSuffix(".zhipin.com")
    }
}
