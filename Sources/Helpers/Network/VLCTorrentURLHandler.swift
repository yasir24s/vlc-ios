/*****************************************************************************
 * VLCTorrentURLHandler.swift: routes magnet: links into the torrent engine
 *****************************************************************************/

import Foundation

class VLCTorrentURLHandler: NSObject, VLCURLHandler {
    var movieURL: URL?
    var subURL: URL?
    var successCallback: URL?
    var errorCallback: URL?
    var fileName: String?

    @objc func canHandleOpen(url: URL, options: [UIApplication.OpenURLOptionsKey: AnyObject]) -> Bool {
        return VLCTorrentPlaybackCoordinator.canHandle(url)
    }

    @objc func performOpen(url: URL, options: [UIApplication.OpenURLOptionsKey: AnyObject]) -> Bool {
        let coordinator = VLCTorrentPlaybackCoordinator.shared
        if VLCTorrentService.isTorrentFile(url) {
            coordinator.streamTorrentFile(atPath: url.path, presenting: nil)
        } else {
            coordinator.streamMagnet(url.absoluteString, presenting: nil)
        }
        return true
    }
}
