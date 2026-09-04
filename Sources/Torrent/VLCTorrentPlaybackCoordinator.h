/*****************************************************************************
 * VLCTorrentPlaybackCoordinator.h: turns a magnet link into playback
 *****************************************************************************
 * Bridges the gap between "user pasted a magnet" and "libvlc is playing":
 * add the torrent in stream mode, wait for metadata (which for a magnet means
 * a round trip to the swarm), then hand libvlc a loopback HTTP URL.
 *****************************************************************************/

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VLCTorrentPlaybackCoordinator : NSObject

@property (class, nonatomic, readonly) VLCTorrentPlaybackCoordinator *sharedCoordinator;

/// YES for magnet links and .torrent files, i.e. anything libvlc cannot open
/// itself and that should be routed through the torrent engine instead.
+ (BOOL)canHandleURL:(NSURL *)url NS_SWIFT_NAME(canHandle(_:));
+ (BOOL)canHandleURLString:(NSString *)urlString NS_SWIFT_NAME(canHandle(urlString:));

/// Adds the magnet in stream mode and starts playback once metadata arrives.
/// Presents its own progress and error UI over @c controller, falling back to
/// the key window's root when nil.
- (void)streamMagnetURI:(NSString *)magnetURI
   presentingController:(nullable UIViewController *)controller
    NS_SWIFT_NAME(streamMagnet(_:presenting:));

/// Plays one file of a torrent that has already been added and has metadata.
- (void)streamFileIndex:(NSInteger)fileIndex
  ofTorrentWithInfoHash:(NSString *)infoHash
   presentingController:(nullable UIViewController *)controller
    NS_SWIFT_NAME(streamFile(at:ofTorrent:presenting:));

/// Same, for a .torrent file already on disk.
- (void)streamTorrentFileAtPath:(NSString *)path
           presentingController:(nullable UIViewController *)controller
    NS_SWIFT_NAME(streamTorrentFile(atPath:presenting:));

@end

NS_ASSUME_NONNULL_END
