/*****************************************************************************
 * VLCTorrentService.h: BitTorrent engine for VLC-iOS
 *****************************************************************************
 * One libtorrent session serving two modes:
 *
 * Nothing is fetched when a torrent is added. Files are pulled only when the
 * user picks one, and everything saves into Documents/Torrents -- the
 * medialibrary root -- so kept files appear in the library on their own.
 *
 * A streamed file is transient: it is deleted when the user moves to another
 * episode, unless they asked to keep it. libtorrent has no per-file delete, so
 * eviction removes the file behind its back and the stale have-state is
 * repaired by a recheck, lazily, only if that file is ever opened again.
 *
 * The header is deliberately free of C++ so it can sit in the Swift bridging
 * header. All libtorrent contact lives in VLCTorrentService.mm.
 *****************************************************************************/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VLCTorrentMode) {
    VLCTorrentModeDownload = 0,
    VLCTorrentModeStream = 1,
};

typedef NS_ENUM(NSInteger, VLCTorrentState) {
    VLCTorrentStateCheckingResumeData = 0,
    VLCTorrentStateFetchingMetadata,
    VLCTorrentStateCheckingFiles,
    VLCTorrentStateDownloading,
    VLCTorrentStatePaused,
    VLCTorrentStateFinished,
    VLCTorrentStateSeeding,
    VLCTorrentStateErrored,
};

/// One file inside a torrent.
@interface VLCTorrentFile : NSObject
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString *name;
/// Path relative to the torrent's save directory.
@property (nonatomic, readonly, copy) NSString *relativePath;
@property (nonatomic, readonly) int64_t size;
@property (nonatomic, readonly, getter=isWanted) BOOL wanted;
/// YES when VLC can be expected to play this file.
@property (nonatomic, readonly, getter=isPlayable) BOOL playable;
@end

/// Immutable snapshot of a torrent, safe to hand to the main thread.
@interface VLCTorrentInfo : NSObject
@property (nonatomic, readonly, copy) NSString *infoHash;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) VLCTorrentMode mode;
@property (nonatomic, readonly) VLCTorrentState state;
/// 0.0 - 1.0 over the *wanted* bytes only.
@property (nonatomic, readonly) float progress;
@property (nonatomic, readonly) int64_t wantedBytes;
@property (nonatomic, readonly) int64_t completedBytes;
@property (nonatomic, readonly) int downloadRate;
@property (nonatomic, readonly) int uploadRate;
@property (nonatomic, readonly) int peerCount;
@property (nonatomic, readonly) int seedCount;
@property (nonatomic, readonly) BOOL hasMetadata;
@property (nonatomic, readonly, copy) NSString *savePath;
@property (nonatomic, readonly, copy, nullable) NSString *localizedErrorDescription;
/// Human-readable state line for a table cell.
@property (nonatomic, readonly, copy) NSString *statusDescription;
@end

/// Posted (main thread) when a torrent is added, removed, or changes state.
extern NSNotificationName const VLCTorrentListDidChangeNotification;
/// Posted (main thread) when a download finishes. Observe this to reload the
/// medialibrary. userInfo carries VLCTorrentInfoHashKey and VLCTorrentSavePathKey.
extern NSNotificationName const VLCTorrentDidFinishNotification;
extern NSString *const VLCTorrentInfoHashKey;
extern NSString *const VLCTorrentSavePathKey;

extern NSErrorDomain const VLCTorrentErrorDomain;
typedef NS_ERROR_ENUM(VLCTorrentErrorDomain, VLCTorrentError) {
    VLCTorrentErrorInvalidMagnet = 1,
    VLCTorrentErrorInvalidTorrentFile,
    VLCTorrentErrorInsufficientDiskSpace,
    VLCTorrentErrorDuplicate,
    VLCTorrentErrorSessionNotRunning,
};

@interface VLCTorrentService : NSObject

@property (class, nonatomic, readonly) VLCTorrentService *sharedService;

#pragma mark - Lifecycle

@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// Starts the session and re-adds torrents persisted from previous launches.
- (void)start;
/// Flushes resume data and tears the session down.
- (void)stop;
/// Persists resume data for every torrent. Call when backgrounding.
- (void)saveState;

#pragma mark - Policy

/// Move torrent data over cellular. Default NO: the session is paused while
/// the only route is an expensive one, because the data bill is the user's.
@property (nonatomic) BOOL allowsCellularTransfers;
/// Keep seeding after a download completes. Default NO.
@property (nonatomic) BOOL seedsAfterCompletion;
/// Refuse to add a torrent that would leave less than this much free. Default 2 GB.
@property (nonatomic) int64_t minimumFreeBytes;

#pragma mark - Adding

/// @return the info hash on success, nil on failure.
- (nullable NSString *)addMagnetURI:(NSString *)magnetURI
                               mode:(VLCTorrentMode)mode
                              error:(NSError **)error;

- (nullable NSString *)addTorrentFileAtPath:(NSString *)path
                                       mode:(VLCTorrentMode)mode
                                      error:(NSError **)error;

#pragma mark - Inspection

- (NSArray<VLCTorrentInfo *> *)allTorrents;
- (nullable VLCTorrentInfo *)torrentWithInfoHash:(NSString *)infoHash;
/// Empty until metadata arrives for a magnet.
- (NSArray<VLCTorrentFile *> *)filesForTorrentWithInfoHash:(NSString *)infoHash;

#pragma mark - Control

- (void)pauseTorrentWithInfoHash:(NSString *)infoHash;
- (void)resumeTorrentWithInfoHash:(NSString *)infoHash;
- (void)removeTorrentWithInfoHash:(NSString *)infoHash deletingFiles:(BOOL)deleteFiles;

/// Fetch a file for playback. Transient: the previously streamed file of this
/// torrent is deleted unless it was kept. Re-opening an evicted file triggers
/// a recheck so libtorrent stops believing it still has the data.
- (void)streamFileIndex:(NSInteger)fileIndex inTorrentWithInfoHash:(NSString *)infoHash;

/// Fetch a file and keep it. Never evicted, and it stays in Documents/Torrents
/// where the medialibrary will index it.
- (void)keepFileIndex:(NSInteger)fileIndex inTorrentWithInfoHash:(NSString *)infoHash;

/// YES if the user asked to keep this file.
- (BOOL)isFileKept:(NSInteger)fileIndex inTorrentWithInfoHash:(NSString *)infoHash;
/// YES if this is the file currently being streamed.
- (BOOL)isFileStreaming:(NSInteger)fileIndex inTorrentWithInfoHash:(NSString *)infoHash;

/// Free bytes on the volume holding the download directory.
@property (nonatomic, readonly) int64_t freeDiskBytes;
/// Pauses every torrent when free space falls below minimumFreeBytes, and says
/// so. Checked as data arrives, not just when a torrent is added.
@property (nonatomic, readonly) BOOL pausedForDiskSpace;

/// Restrict a download to a subset of files. Pass nil to want everything.
- (void)setWantedFileIndexes:(nullable NSArray<NSNumber *> *)indexes
      forTorrentWithInfoHash:(NSString *)infoHash;

/// Session-level state, for diagnostics.
- (NSString *)sessionDiagnostics;

#pragma mark - Streaming support

/// Playable files in playback order: natural alphanumeric by path, so
/// "E02" sorts before "E10" rather than after it. Samples and other tiny
/// oddments are left out. Empty without metadata.
- (NSArray<VLCTorrentFile *> *)playableFilesInPlaybackOrderForTorrentWithInfoHash:(NSString *)infoHash;

/// Index of the file playback should start from -- the first in the order
/// above, i.e. episode one rather than whichever file happens to be biggest.
/// NSNotFound without metadata or with nothing playable.
- (NSInteger)primaryPlayableFileIndexForTorrentWithInfoHash:(NSString *)infoHash;

/// Absolute on-disk path of one file. nil until metadata arrives.
- (nullable NSString *)pathForFileIndex:(NSInteger)fileIndex
                  inTorrentWithInfoHash:(NSString *)infoHash;

- (int64_t)sizeOfFileIndex:(NSInteger)fileIndex
     inTorrentWithInfoHash:(NSString *)infoHash;

/// Contiguous bytes already on disk from fileOffset, capped at maxLength.
/// 0 means the piece under the read cursor has not landed yet.
- (int64_t)availableBytesForFileIndex:(NSInteger)fileIndex
                inTorrentWithInfoHash:(NSString *)infoHash
                           fileOffset:(int64_t)fileOffset
                            maxLength:(int64_t)maxLength;

/// Pull this window to the front of the queue: deadlines on the covering
/// pieces, ascending so they arrive in playback order.
- (void)requestFileIndex:(NSInteger)fileIndex
   inTorrentWithInfoHash:(NSString *)infoHash
              fileOffset:(int64_t)fileOffset
                  length:(int64_t)length;

#pragma mark - Paths and helpers

/// Documents/Torrents. Inside the medialibrary root, so downloads land in the library.
@property (nonatomic, readonly, copy) NSString *downloadDirectory;
/// Library/Caches/TorrentStream. Outside the library, purgeable by iOS.
@property (nonatomic, readonly, copy) NSString *streamCacheDirectory;

+ (BOOL)isMagnetURL:(NSURL *)url;
+ (BOOL)isTorrentFileURL:(NSURL *)url NS_SWIFT_NAME(isTorrentFile(_:));

@end

NS_ASSUME_NONNULL_END
