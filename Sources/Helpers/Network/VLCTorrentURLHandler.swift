/*****************************************************************************
 * VLCTorrentURLHandler.swift: routes magnet links and .torrent files into the torrent engine
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
            // Not url.path straight to libtorrent: with open-in-place this is a
            // security-scoped URL, unreadable until access is requested.
            coordinator.openTorrentFile(at: url, presenting: nil)
        } else {
            coordinator.streamMagnet(url.absoluteString, presenting: nil)
        }
        return true
    }
}
