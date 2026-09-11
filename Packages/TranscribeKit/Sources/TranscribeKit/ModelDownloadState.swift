/// Where an optional model is in getting onto this Mac: the title and topic
/// models, which Settings can fetch ahead of the first recording.
public enum ModelDownloadState: Equatable, Sendable {
    /// Not on disk yet. Downloads via the model's `download()`.
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}
