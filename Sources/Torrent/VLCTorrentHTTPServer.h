/*****************************************************************************
 * VLCTorrentHTTPServer.h: serves torrent files to libvlc over loopback
 *****************************************************************************
 * libvlc has no torrent input (VLCKit links its modules statically, so a
 * plugin cannot be added to a shipped build). Instead we hand libvlc an
 * ordinary http:// URL on 127.0.0.1 and translate its Range requests into
 * libtorrent piece deadlines, which is what makes seeking work.
 *****************************************************************************/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VLCTorrentHTTPServer : NSObject

@property (class, nonatomic, readonly) VLCTorrentHTTPServer *sharedServer;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
/// Ephemeral, assigned by the kernel. 0 until started.
@property (nonatomic, readonly) uint16_t port;

- (BOOL)startWithError:(NSError **)error;
- (void)stop;

/// URL libvlc should open to play one file out of a torrent.
/// nil if the torrent has no metadata yet or the index is out of range.
- (nullable NSURL *)streamURLForTorrentWithInfoHash:(NSString *)infoHash
                                          fileIndex:(NSInteger)fileIndex;

/// Same, picking the largest playable file in the torrent.
- (nullable NSURL *)streamURLForTorrentWithInfoHash:(NSString *)infoHash;

@end

NS_ASSUME_NONNULL_END
