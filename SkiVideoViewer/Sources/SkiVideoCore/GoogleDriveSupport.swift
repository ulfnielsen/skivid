import CryptoKit
import Foundation
import Security

struct DriveMedia: Hashable {
    let fileID: String
    let name: String
    let mimeType: String
    let size: Int64
    let accessToken: String

    /// Google Drive accepts OAuth access tokens on its HTTPS media endpoint. Using
    /// this native URL lets AVPlayer perform normal range requests itself.
    var streamingURL: URL {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(fileID)"
        )!
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "access_token", value: accessToken),
        ]
        return components.url!
    }
}

struct DriveLibrary {
    let athletes: [AthleteGroup]
    let mediaByURL: [URL: DriveMedia]
}

struct GoogleDriveClient {
    private static let folderMimeType = "application/vnd.google-apps.folder"

    private let accessToken: String

    static func connect(
        clientSecretsURL: URL,
        presenter: OAuthPresenter
    ) async throws -> GoogleDriveClient {
        let client = try GoogleOAuthClient.load(from: clientSecretsURL)
        let token = try await GoogleOAuth.authorize(client: client, presenter: presenter)
        return GoogleDriveClient(accessToken: token)
    }

    func scanSharedDrive(folderID: String) async throws -> DriveLibrary {
        var entries: [LibraryGrouping.Entry] = []
        var mediaByURL: [URL: DriveMedia] = [:]

        // A clip sitting loose in the chosen root has no athlete folder to be
        // named after, so ask Drive what the root itself is called:
        // `VideoLibrary.scan` names that group after the chosen folder, and this
        // is the closest Drive can come to it. The literal "Unsorted" stood here
        // until 2026-08-09, which was wrong because the name is the grouping
        // *key*, not a caption — a Drive folder genuinely named `Unsorted` and
        // the loose files silently became one athlete.
        //
        // Deliberately non-fatal. The name is a label for one group that many
        // libraries never even produce, so it must not be able to fail a scan
        // that would otherwise succeed — a folder whose *children* are shared
        // with the operator but whose own record is not would list fine here and
        // 403 on the `files.get`. Falling back to the pasted folder id keeps a
        // unique key, which is the whole reason "Unsorted" had to go.
        //
        // UNVERIFIED, and it needs credentials to settle: whether `files.get`
        // returns a name when `folderID` is a Shared Drive's own id rather than
        // a folder inside it. With `try?` the answer stops mattering — either
        // the name arrives or the id is used — which is why this does not wait
        // on someone measuring it.
        let rootName = (try? await folderName(of: folderID)) ?? folderID

        // Both names are carried, not just the athlete's: the event is the
        // folder directly above the athlete, so the recursion has to remember
        // one more level than it used to. `VideoLibrary.scan` reads the same
        // two components out of the path — the rule is one rule, applied to
        // whatever each scanner can see.
        func scan(folderID: String, parentName: String?, grandparentName: String?) async throws {
            for file in try await listChildren(of: folderID) {
                if file.mimeType == Self.folderMimeType {
                    try await scan(
                        folderID: file.id,
                        parentName: file.name,
                        grandparentName: parentName
                    )
                    continue
                }
                // The same list the local library uses, deliberately not a copy.
                // Drive kept its own set until 2026-08-08, still naming avi, mkv
                // and webm after the local one dropped them — so Drive offered
                // files that `AVPlayer` cannot open and the sidebar would not
                // have listed. One source of truth cannot drift like that.
                guard file.canDownload,
                      VideoLibrary.supportedExtensions
                          .contains(URL(fileURLWithPath: file.name).pathExtension.lowercased())
                else {
                    continue
                }

                // The folder hierarchy is absent from this URL: the host is the
                // file id and the path is just `/<name>`. So where a local scan
                // sorts clips by folder-then-name, both inside `LibraryGrouping`
                // and within a group, Drive clips sort by file name alone. Two
                // sibling folders that fold alike (`Andre/`, `André/`) therefore
                // take their winning spelling from whichever folder holds the
                // alphabetically first *file* name, and their clips interleave
                // instead of staying in folder blocks. Deterministic run to run
                // — `pathOrder` is a total order and breaks the file-name tie on
                // the full URL — just not the local scanner's order.
                let streamURL = URL(string: "drivevideo://\(file.id)")!
                    .appendingPathComponent(file.name)
                mediaByURL[streamURL] = DriveMedia(
                    fileID: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    size: Int64(file.size ?? "") ?? 0,
                    accessToken: accessToken
                )
                entries.append(
                    LibraryGrouping.Entry(
                        video: streamURL,
                        athlete: parentName ?? rootName,
                        // A file loose in the chosen root has neither an athlete
                        // folder nor an event; one in `root/Athlete` has an
                        // athlete but no event, exactly as locally. The latter
                        // holds because the top-level call seeds *both* names
                        // nil: seeding `parentName` with the root's own name
                        // instead would read the root as an event one level
                        // down, which is the mistake the local scanner had to
                        // fix. Nothing here can catch that — this comment is the
                        // guard, so keep the seeding as it is.
                        event: grandparentName
                    )
                )
            }
        }

        try await scan(folderID: folderID, parentName: nil, grandparentName: nil)
        return DriveLibrary(
            athletes: LibraryGrouping.group(entries),
            mediaByURL: mediaByURL
        )
    }

    /// The chosen root folder's own name, which is all the loose clips at the
    /// top of it have to be grouped under.
    ///
    /// Throws like every other call here, but the one caller swallows it: see
    /// `scanSharedDrive` for why a label that most libraries never display must
    /// not be able to fail a scan. It costs one request per scan, next to the
    /// many `files.list` calls the walk makes.
    private func folderName(of folderID: String) async throws -> String {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        // Appended through `path` rather than interpolated into the string, so a
        // pasted id that is not URL-safe gets percent-encoded instead of
        // reshaping the request.
        components.path += "/\(folderID)"
        components.queryItems = [
            URLQueryItem(name: "fields", value: "name"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        guard let url = components.url else {
            throw DriveError.api("That Shared Drive folder ID cannot be used in a request to Google.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw DriveClientAPIError.describe(
                data: data,
                response: response,
                action: "open this Shared Drive folder"
            )
        }
        do {
            return try JSONDecoder().decode(DriveFolderName.self, from: data).name
        } catch {
            throw DriveError.api("Google Drive returned an unexpected folder record: \(error.localizedDescription)")
        }
    }

    private func listChildren(of folderID: String) async throws -> [DriveFile] {
        var files: [DriveFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,capabilities(canDownload))"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                throw DriveClientAPIError.describe(
                    data: data,
                    response: response,
                    action: "list this Shared Drive folder"
                )
            }
            let page: DriveListResponse
            do {
                page = try JSONDecoder().decode(DriveListResponse.self, from: data)
            } catch {
                throw DriveError.api("Google Drive returned an unexpected folder listing: \(error.localizedDescription)")
            }
            files.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }
}

/// Its own type rather than a `DriveFile` decode, because the folder record is
/// fetched with `fields=name` alone: everything `DriveFile` requires beyond the
/// name is absent from that response.
private struct DriveFolderName: Decodable {
    let name: String
}

private struct DriveListResponse: Decodable {
    let nextPageToken: String?
    let files: [DriveFile]
}

private struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let capabilities: DriveCapabilities?

    var canDownload: Bool { capabilities?.canDownload ?? false }
}

/// A private copy for the client this file still holds. The shared original
/// moved to GoogleOAuth.swift; this whole file is deleted in a later task, so
/// duplicating six lines for its remaining life beats widening the moved type's
/// access to serve code that is going away.
private struct DriveClientAPIError: Decodable {
    struct Details: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }

    let error: Details?

    static func describe(data: Data, response: URLResponse, action: String) -> DriveError {
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let decoded = try? JSONDecoder().decode(DriveClientAPIError.self, from: data)
        let message = decoded?.error?.message ?? "No detail returned by Google."
        let status = statusCode.map { " (HTTP \($0))" } ?? ""
        return .api("Google Drive could not \(action)\(status): \(message)")
    }
}

private struct DriveCapabilities: Decodable {
    let canDownload: Bool
}

