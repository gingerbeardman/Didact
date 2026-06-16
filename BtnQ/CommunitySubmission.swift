//
//  CommunitySubmission.swift
//  BtnQ
//
//  Submits a monitor profile (and its raw DDC capabilities dump) to the project's
//  GitHub so others with the same monitor can use it. The full submission is
//  ALWAYS copied to the clipboard — GitHub's pre-filled-issue URL has a length
//  limit a full profile + capabilities easily exceeds, so the clipboard is the
//  reliable channel and the pre-filled body is a best-effort convenience.
//

import AppKit

enum CommunitySubmission {
    private static let newIssueBase = "https://github.com/gingerbeardman/BtnQ/issues/new"

    /// Returns true if the issue was opened pre-filled, false if it fell back to a
    /// bare issue (body on the clipboard only).
    @discardableResult
    static func submit(config: MonitorConfig, capabilities: String?) -> Bool {
        // Minified (not pretty-printed): pretty JSON triples in size once
        // URL-encoded (~10.7 KB vs ~4.5 KB) and blows past GitHub's pre-fill
        // limit. Compact keeps config + capabilities under it so the body fills.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let caps = capabilities ?? "(monitor returned no capabilities string)"
        let body = """
        Sharing a monitor profile for **\(config.name)** so others with this monitor can use it.

        Profile:

        ```json
        \(json)
        ```

        DDC/CI capabilities string:

        ```
        \(caps)
        ```
        """

        // Always put it on the clipboard — the reliable channel.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)

        let title = "Monitor profile: \(config.name)"
        var prefilled = URLComponents(string: newIssueBase)!
        prefilled.queryItems = [URLQueryItem(name: "title", value: title),
                                URLQueryItem(name: "body", value: body)]

        if let url = prefilled.url, url.absoluteString.count < 8000 {
            NSWorkspace.shared.open(url)
            return true
        }
        var bare = URLComponents(string: newIssueBase)!
        bare.queryItems = [URLQueryItem(name: "title", value: title)]
        if let url = bare.url { NSWorkspace.shared.open(url) }
        return false
    }
}
