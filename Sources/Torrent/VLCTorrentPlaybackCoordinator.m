/*****************************************************************************
 * VLCTorrentPlaybackCoordinator.m
 *****************************************************************************/

#import "VLCTorrentPlaybackCoordinator.h"

#import "VLCPlaybackService.h"
#import "VLCTorrentHTTPServer.h"
#import "VLCTorrentFilesViewController.h"
#import "VLCTorrentLibrary.h"
#import "VLCTorrentService.h"

/// Fetching metadata for a magnet means finding peers first, so this can take
/// a while on a cold or thinly seeded swarm.
static NSTimeInterval const kMetadataTimeout = 90.0;
static NSTimeInterval const kMetadataPollInterval = 0.5;

/// Handing libvlc a file with nothing on disk makes its first probe find no
/// duration, so it treats the input as a live stream: no scrubber, and audio
/// placeholder art until pieces land. Fetch a slice of each end first.
///
/// The tail matters as much as the head. Matroska normally stores its Cues --
/// the seek index -- at the *end* of the file, and without them VLC cannot
/// build a timeline no matter how much of the beginning it has.
static int64_t const kPrebufferHeadBytes = 4 * 1024 * 1024;
static int64_t const kPrebufferTailBytes = 1 * 1024 * 1024;
/// Play anyway rather than hang forever on a slow swarm.
static NSTimeInterval const kPrebufferTimeout = 45.0;

/// How long before an episode ends the next one is announced and its head and
/// tail fetched: enough to land on a thin swarm, late enough that scrubbing
/// around mid-episode does not set it off.
static NSTimeInterval const kUpNextLeadTime = 90.0;
/// Recorded when the episode playing is the last one, so the lookup is not
/// repeated on every position tick for its final minute and a half.
static NSInteger const kNoNextFile = -2;

@implementation VLCTorrentPlaybackCoordinator {
    UIAlertController *_progressAlert;
    NSString *_pendingInfoHash;
    NSTimer *_pollTimer;
    NSDate *_startDate;
    NSInteger _prebufferFileIndex;
    NSDate *_prebufferStart;
    __weak UIViewController *_presenter;

    /// The torrent file the player is on, when it is one of ours.
    NSString *_playingInfoHash;
    NSInteger _playingFileIndex;
    /// What was just queued but not yet reached. Until the player switches,
    /// its position ticks still describe the old item, and treating that as an
    /// advance would hand back to the old file and evict the new one.
    NSString *_expectedInfoHash;
    NSInteger _expectedFileIndex;
    /// The next episode already announced and prefetched, so that happens once.
    NSInteger _preparedFileIndex;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        // 0 is a legitimate file index, so idle has to be NSNotFound.
        _prebufferFileIndex = NSNotFound;
        _playingFileIndex = NSNotFound;
        _expectedFileIndex = NSNotFound;
        _preparedFileIndex = NSNotFound;

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self
                   selector:@selector(playbackDidMoveOnToNextItem:)
                       name:VLCPlaybackServicePlaybackDidMoveOnToNextItem
                     object:nil];
        [center addObserver:self
                   selector:@selector(playbackPositionUpdated:)
                       name:VLCPlaybackServicePlaybackPositionUpdated
                     object:nil];
        [center addObserver:self
                   selector:@selector(playbackDidEnd:)
                       name:VLCPlaybackServicePlaybackDidStop
                     object:nil];
        [center addObserver:self
                   selector:@selector(playbackDidEnd:)
                       name:VLCPlaybackServicePlaybackDidFail
                     object:nil];
    }
    return self;
}

+ (VLCTorrentPlaybackCoordinator *)sharedCoordinator
{
    static VLCTorrentPlaybackCoordinator *sharedCoordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedCoordinator = [[VLCTorrentPlaybackCoordinator alloc] init];
    });
    return sharedCoordinator;
}

#pragma mark - Recognition

+ (BOOL)canHandleURL:(NSURL *)url
{
    return [VLCTorrentService isMagnetURL:url] || [VLCTorrentService isTorrentFileURL:url];
}

+ (BOOL)canHandleURLString:(NSString *)urlString
{
    if ([urlString.lowercaseString hasPrefix:@"magnet:"]) {
        return YES;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    return url != nil && [self canHandleURL:url];
}

#pragma mark - Entry points

- (void)streamMagnetURI:(NSString *)magnetURI
   presentingController:(nullable UIViewController *)controller
{
    // A .torrent opened here before carries the file list, so open from that
    // and skip the round trip to the swarm for metadata.
    NSString *hash = [VLCTorrentLibrary infoHashFromMagnetURI:magnetURI];
    NSString *local = hash ? [VLCTorrentLibrary.sharedLibrary torrentFilePathForInfoHash:hash] : nil;
    if (local) {
        [self streamTorrentFileAtPath:local presentingController:controller];
        return;
    }

    [self startEngines];

    NSError *error;
    NSString *infoHash = [VLCTorrentService.sharedService addMagnetURI:magnetURI
                                                                  mode:VLCTorrentModeStream
                                                                 error:&error];
    [self beginWaitingForInfoHash:infoHash error:error controller:controller];
}

- (void)streamTorrentFileAtPath:(NSString *)path
           presentingController:(nullable UIViewController *)controller
{
    [self startEngines];

    NSError *error;
    NSString *infoHash = [VLCTorrentService.sharedService addTorrentFileAtPath:path
                                                                          mode:VLCTorrentModeStream
                                                                         error:&error];
    [self beginWaitingForInfoHash:infoHash error:error controller:controller];
}

- (void)openTorrentFileAtURL:(NSURL *)url
        presentingController:(nullable UIViewController *)controller
{
    // From the Files app this is a security-scoped URL into storage we do not
    // own, unreadable without asking; from AirDrop or Mail it is a copy left in
    // Documents/Inbox, which sits inside the medialibrary's root. Either way,
    // take a copy of our own and let the original go.
    BOOL const scoped = [url startAccessingSecurityScopedResource];
    NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"torrent"]];
    NSError *copyError;
    BOOL const copied = [[NSFileManager defaultManager]
        copyItemAtURL:url toURL:[NSURL fileURLWithPath:staging] error:&copyError];
    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }
    if ([url.path rangeOfString:@"/Documents/Inbox/"].location != NSNotFound) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    }
    if (!copied) {
        NSLog(@"VLCTorrentPlaybackCoordinator: could not read %@: %@", url, copyError);
        [self presentError:NSLocalizedString(@"That .torrent file could not be read.", nil)
                controller:controller];
        return;
    }

    VLCTorrentLibrary *library = VLCTorrentLibrary.sharedLibrary;
    VLCTorrentBookmark *bookmark = [library rememberTorrentFileAtPath:staging];
    if (bookmark) {
        [library markBookmarkOpened:bookmark];
    }
    NSString *stored = bookmark.infoHash ? [library torrentFilePathForInfoHash:bookmark.infoHash] : nil;
    [self streamTorrentFileAtPath:stored ?: staging presentingController:controller];
    // libtorrent has read the file by now; the library kept its own copy.
    [[NSFileManager defaultManager] removeItemAtPath:staging error:nil];
}

- (void)streamFileIndex:(NSInteger)fileIndex
  ofTorrentWithInfoHash:(NSString *)infoHash
   presentingController:(nullable UIViewController *)controller
{
    [self startEngines];

    VLCTorrentInfo *info = [VLCTorrentService.sharedService torrentWithInfoHash:infoHash];
    if (!info) {
        [self presentError:NSLocalizedString(@"That torrent is no longer available.", nil)
                controller:controller];
        return;
    }

    // Metadata is already in hand, but the bytes still are not, so this takes
    // the same buffering path as a fresh magnet.
    _prebufferFileIndex = fileIndex;
    [VLCTorrentService.sharedService streamFileIndex:fileIndex
                               inTorrentWithInfoHash:infoHash];
    [self beginWaitingForInfoHash:infoHash error:nil controller:controller];
}

#pragma mark - Machinery

/// Started lazily: no reason to hold a torrent session open for users who
/// never touch a magnet link.
- (void)startEngines
{
    VLCTorrentService *service = VLCTorrentService.sharedService;
    if (!service.isRunning) {
        [service start];
    }

    VLCTorrentHTTPServer *server = VLCTorrentHTTPServer.sharedServer;
    if (!server.isRunning) {
        NSError *error;
        if (![server startWithError:&error]) {
            NSLog(@"VLCTorrentPlaybackCoordinator: bridge failed to start: %@", error);
        }
    }
}

- (void)beginWaitingForInfoHash:(nullable NSString *)infoHash
                          error:(nullable NSError *)error
                     controller:(nullable UIViewController *)controller
{
    if (!infoHash) {
        [self presentError:error.localizedDescription ?:
            NSLocalizedString(@"That torrent could not be added.", nil)
                controller:controller];
        return;
    }

    _pendingInfoHash = infoHash;
    _startDate = [NSDate date];
    _presenter = controller;
    [self presentProgressOverController:controller];

    // If metadata is already cached from a previous add, this resolves at once.
    [self pollForMetadata];
    if (!_pendingInfoHash) {
        return;
    }

    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:kMetadataPollInterval
                                                  target:self
                                                selector:@selector(pollForMetadata)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)pollForMetadata
{
    NSString *infoHash = _pendingInfoHash;
    if (!infoHash) {
        [self stopPolling];
        return;
    }

    VLCTorrentService *service = VLCTorrentService.sharedService;
    VLCTorrentInfo *info = [service torrentWithInfoHash:infoHash];
    if (!info) {
        [self finishWithError:NSLocalizedString(@"The torrent was removed.", nil)];
        return;
    }

    if (info.state == VLCTorrentStateErrored) {
        [self finishWithError:info.localizedErrorDescription];
        return;
    }

    if (info.hasMetadata) {
        if (_prebufferFileIndex == NSNotFound) {
            // More than one thing to watch means the choice is the user's, not
            // ours. A single-file torrent still just plays.
            NSArray<VLCTorrentFile *> *ordered =
                [service playableFilesInPlaybackOrderForTorrentWithInfoHash:infoHash];
            if (ordered.count > 1) {
                [self presentChooserForInfoHash:infoHash name:info.name];
                return;
            }

            NSInteger fileIndex =
                [service primaryPlayableFileIndexForTorrentWithInfoHash:infoHash];
            if (fileIndex == NSNotFound) {
                // Metadata arrived but nothing in it is playable.
                if ([service filesForTorrentWithInfoHash:infoHash].count > 0) {
                    [self finishWithError:
                        NSLocalizedString(@"This torrent contains no playable media.", nil)];
                }
                return;
            }
            _prebufferFileIndex = fileIndex;
            _prebufferStart = [NSDate date];
            // Registers the pick, and evicts whatever was streamed before it.
            [service streamFileIndex:fileIndex inTorrentWithInfoHash:infoHash];
        }

        float const buffered = [self prebufferProgressForInfoHash:infoHash
                                                        fileIndex:_prebufferFileIndex];
        BOOL const expired = -[_prebufferStart timeIntervalSinceNow] > kPrebufferTimeout;
        if (buffered >= 1.f || expired) {
            if (expired) {
                NSLog(@"VLCTorrentPlaybackCoordinator: prebuffer timed out at %.0f%%, "
                       "starting anyway", buffered * 100.f);
            }
            [self playTorrentWithInfoHash:infoHash
                                fileIndex:_prebufferFileIndex
                                     name:info.name];
            return;
        }

        _progressAlert.message = [NSString stringWithFormat:
            NSLocalizedString(@"Buffering %.0f%%\n%@ - %d peers", nil),
            buffered * 100.f, info.statusDescription, info.peerCount];
        return;
    }

    // Keep the user informed rather than showing a stalled spinner.
    _progressAlert.message = [NSString stringWithFormat:
        NSLocalizedString(@"%@\n%d peers", nil), info.statusDescription, info.peerCount];

    if (-[_startDate timeIntervalSinceNow] > kMetadataTimeout) {
        [self finishWithError:
            NSLocalizedString(@"Timed out finding peers for this torrent.", nil)];
    }
}

/// Asks for the head and tail windows and reports how much of them has landed,
/// 0.0 to 1.0. Re-requesting every tick is deliberate: the deadlines are what
/// pull these pieces to the front of the queue.
- (float)prebufferProgressForInfoHash:(NSString *)infoHash fileIndex:(NSInteger)fileIndex
{
    VLCTorrentService *service = VLCTorrentService.sharedService;

    int64_t const size = [service sizeOfFileIndex:fileIndex inTorrentWithInfoHash:infoHash];
    if (size <= 0) {
        return 0.f;
    }

    int64_t const head = MIN(kPrebufferHeadBytes, size);
    int64_t const tail = MIN(kPrebufferTailBytes, size - head);
    int64_t const tailOffset = size - tail;

    [service requestFileIndex:fileIndex
        inTorrentWithInfoHash:infoHash
                   fileOffset:0
                       length:head];
    if (tail > 0) {
        [service requestFileIndex:fileIndex
            inTorrentWithInfoHash:infoHash
                       fileOffset:tailOffset
                           length:tail];
    }

    int64_t const haveHead = [service availableBytesForFileIndex:fileIndex
                                          inTorrentWithInfoHash:infoHash
                                                     fileOffset:0
                                                      maxLength:head];
    int64_t haveTail = 0;
    if (tail > 0) {
        haveTail = [service availableBytesForFileIndex:fileIndex
                                inTorrentWithInfoHash:infoHash
                                           fileOffset:tailOffset
                                            maxLength:tail];
    }

    return (float)(haveHead + haveTail) / (float)(head + tail);
}

- (void)playTorrentWithInfoHash:(NSString *)infoHash
                      fileIndex:(NSInteger)fileIndex
                           name:(NSString *)name
{
    VLCTorrentService *service = VLCTorrentService.sharedService;
    VLCTorrentHTTPServer *server = VLCTorrentHTTPServer.sharedServer;

    // Queue the whole torrent in playback order, not just the one file, so a
    // season pack runs on into the next episode instead of stopping dead.
    // Stream mode re-prioritises to whichever file is being read, so advancing
    // the playlist redirects the swarm on its own.
    NSArray<VLCTorrentFile *> *ordered =
        [service playableFilesInPlaybackOrderForTorrentWithInfoHash:infoHash];

    VLCMediaList *mediaList = [[VLCMediaList alloc] init];
    NSMutableArray<NSNumber *> *queued = [NSMutableArray array];
    NSInteger startIndex = NSNotFound;
    for (VLCTorrentFile *file in ordered) {
        NSURL *url = [server streamURLForTorrentWithInfoHash:infoHash
                                                   fileIndex:file.index];
        if (!url) {
            continue;
        }
        VLCMedia *media = [VLCMedia mediaWithURL:url];
        media.metaData.title = file.name;
        if (file.index == fileIndex) {
            startIndex = (NSInteger)mediaList.count;
        }
        [mediaList addMedia:media];
        [queued addObject:@(file.index)];
    }

    if (mediaList.count == 0) {
        // Nothing survived the ordering filter; fall back to the one file asked for.
        NSURL *url = [server streamURLForTorrentWithInfoHash:infoHash fileIndex:fileIndex];
        if (!url) {
            [self finishWithError:NSLocalizedString(@"The streaming bridge is unavailable.", nil)];
            return;
        }
        VLCMedia *media = [VLCMedia mediaWithURL:url];
        media.metaData.title = name;
        [mediaList addMedia:media];
        [queued addObject:@(fileIndex)];
        startIndex = 0;
    }
    if (startIndex == NSNotFound) {
        startIndex = 0;
    }

    NSLog(@"VLCTorrentPlaybackCoordinator: playing %lu file(s) from index %ld",
          (unsigned long)mediaList.count, (long)startIndex);

    _pendingInfoHash = nil;
    _prebufferFileIndex = NSNotFound;
    [self stopPolling];

    // The engine already streams this file -- the caller saw to that -- so the
    // player reaching it is an arrival, not an advance needing a handover.
    _expectedInfoHash = infoHash;
    _expectedFileIndex = queued[(NSUInteger)startIndex].integerValue;

    [self dismissProgressWithCompletion:^{
        [[VLCPlaybackService sharedInstance] playMediaList:mediaList
                                                firstIndex:startIndex
                                         subtitlesFilePath:nil];
    }];
}

/// Hands the torrent over to the file list and steps out of the flow: whatever
/// the user picks there re-enters through -streamFileIndex: or -keepFileIndex:.
- (void)presentChooserForInfoHash:(NSString *)infoHash name:(NSString *)name
{
    UIViewController *presenter = [self topViewControllerFrom:_presenter];
    if (!presenter) {
        // Nowhere to show it, so fall back to just playing the first episode.
        NSInteger const first = [VLCTorrentService.sharedService
            primaryPlayableFileIndexForTorrentWithInfoHash:infoHash];
        if (first != NSNotFound) {
            _prebufferFileIndex = first;
            _prebufferStart = [NSDate date];
        }
        return;
    }

    _pendingInfoHash = nil;
    _prebufferFileIndex = NSNotFound;
    [self stopPolling];

    VLCTorrentFilesViewController *files =
        [[VLCTorrentFilesViewController alloc] initWithInfoHash:infoHash title:name];
    files.presentedAsChooser = YES;
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:files];

    [self dismissProgressWithCompletion:^{
        [presenter presentViewController:navigation animated:YES completion:nil];
    }];
}

- (void)finishWithError:(nullable NSString *)message
{
    NSString *infoHash = _pendingInfoHash;
    _pendingInfoHash = nil;
    _prebufferFileIndex = NSNotFound;
    [self stopPolling];

    // Don't leave a half-added torrent burning battery in the background.
    if (infoHash) {
        [VLCTorrentService.sharedService removeTorrentWithInfoHash:infoHash
                                                     deletingFiles:YES];
    }

    __weak VLCTorrentPlaybackCoordinator *weakSelf = self;
    [self dismissProgressWithCompletion:^{
        [weakSelf presentError:message controller:nil];
    }];
}

- (void)stopPolling
{
    [_pollTimer invalidate];
    _pollTimer = nil;
}

#pragma mark - Next episode

/// Brings the engine into line with whatever the player is on. It runs on every
/// position tick as well as on the advance notification, so a notification
/// that lands a moment before the player switches items cannot leave it behind.
- (void)syncWithCurrentMedia
{
    NSString *hash = nil;
    NSInteger index = NSNotFound;
    NSURL *url = VLCPlaybackService.sharedInstance.currentlyPlayingMedia.url;
    if (![VLCTorrentHTTPServer parseStreamURL:url infoHash:&hash fileIndex:&index]) {
        // Something that is not one of our streams, or a stale one from before
        // a relaunch: the access token changes every launch.
        [self resetPlayingState];
        return;
    }

    if (_expectedInfoHash) {
        if ([hash isEqualToString:_expectedInfoHash] && index == _expectedFileIndex) {
            _playingInfoHash = hash;
            _playingFileIndex = index;
            _preparedFileIndex = NSNotFound;
            _expectedInfoHash = nil;
            _expectedFileIndex = NSNotFound;
        }
        // Otherwise the player is still on the old item. Wait for it.
        return;
    }

    if ([hash isEqualToString:_playingInfoHash] && index == _playingFileIndex) {
        return;
    }

    // The player moved on by itself -- end of an episode, or a jump in the play
    // queue. Do the handover a manual pick would have done: the previous file is
    // evicted unless kept, this one goes to top priority, and one evicted earlier
    // is rechecked before its stale pieces can be served.
    NSLog(@"VLCTorrentPlaybackCoordinator: player moved on to file %ld", (long)index);
    [VLCTorrentService.sharedService streamFileIndex:index inTorrentWithInfoHash:hash];
    _playingInfoHash = hash;
    _playingFileIndex = index;
    _preparedFileIndex = NSNotFound;
}

- (void)resetPlayingState
{
    _playingInfoHash = nil;
    _playingFileIndex = NSNotFound;
    _expectedInfoHash = nil;
    _expectedFileIndex = NSNotFound;
    _preparedFileIndex = NSNotFound;
}

- (void)playbackDidMoveOnToNextItem:(NSNotification *)notification
{
    [self syncWithCurrentMedia];
}

- (void)playbackDidEnd:(NSNotification *)notification
{
    [self resetPlayingState];
}

- (void)playbackPositionUpdated:(NSNotification *)notification
{
    [self syncWithCurrentMedia];
    if (_playingInfoHash && !_expectedInfoHash) {
        [self prepareNextEpisodeIfDue];
    }
}

- (void)prepareNextEpisodeIfDue
{
    if (_preparedFileIndex != NSNotFound) {
        return; // already settled for this episode
    }
    VLCPlaybackService *playback = VLCPlaybackService.sharedInstance;
    // With shuffle on, the next item is not the next episode.
    if (playback.isShuffleMode) {
        return;
    }
    int const length = playback.mediaLength.intValue;
    int const played = playback.playedTime.intValue;
    if (length <= 0 || played <= 0) {
        return;
    }
    NSTimeInterval const remaining = (length - played) / 1000.0;
    if (remaining > kUpNextLeadTime) {
        return;
    }

    VLCTorrentFile *next = [self fileAfterIndex:_playingFileIndex
                          inTorrentWithInfoHash:_playingInfoHash];
    _preparedFileIndex = next ? next.index : kNoNextFile;
    if (!next) {
        return;
    }

    BOOL const fetching = [VLCTorrentService.sharedService
        prefetchFileIndex:next.index
    inTorrentWithInfoHash:_playingInfoHash
                headBytes:kPrebufferHeadBytes
                tailBytes:kPrebufferTailBytes
            withinSeconds:remaining];
    NSLog(@"VLCTorrentPlaybackCoordinator: up next is file %ld%@", (long)next.index,
          fetching ? @"" : @" (evicted earlier; fetched at the handover)");

    if ([playback.delegate respondsToSelector:@selector(showStatusMessage:)]) {
        [playback.delegate showStatusMessage:[NSString stringWithFormat:
            NSLocalizedString(@"Up next: %@", nil), next.name.stringByDeletingPathExtension]];
    }
}

- (nullable VLCTorrentFile *)fileAfterIndex:(NSInteger)index
                      inTorrentWithInfoHash:(NSString *)infoHash
{
    NSArray<VLCTorrentFile *> *ordered = [VLCTorrentService.sharedService
        playableFilesInPlaybackOrderForTorrentWithInfoHash:infoHash];
    for (NSUInteger position = 0; position + 1 < ordered.count; position++) {
        if (ordered[position].index == index) {
            return ordered[position + 1];
        }
    }
    return nil;
}

#pragma mark - UI

- (nullable UIViewController *)topViewControllerFrom:(nullable UIViewController *)controller
{
    UIViewController *root = controller;
    if (!root) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    root = window.rootViewController;
                    break;
                }
            }
        }
    }
    while (root.presentedViewController) {
        root = root.presentedViewController;
    }
    return root;
}

- (void)presentProgressOverController:(nullable UIViewController *)controller
{
    UIViewController *host = [self topViewControllerFrom:controller];
    if (!host) {
        return;
    }

    _progressAlert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"Opening torrent", nil)
                         message:NSLocalizedString(@"Contacting the swarm...", nil)
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak VLCTorrentPlaybackCoordinator *weakSelf = self;
    [_progressAlert addAction:
        [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                 style:UIAlertActionStyleCancel
                               handler:^(UIAlertAction *action) {
        [weakSelf finishWithError:nil];
    }]];
    [host presentViewController:_progressAlert animated:YES completion:nil];
}

- (void)dismissProgressWithCompletion:(nullable void (^)(void))completion
{
    UIAlertController *alert = _progressAlert;
    _progressAlert = nil;
    if (!alert) {
        if (completion) {
            completion();
        }
        return;
    }
    [alert dismissViewControllerAnimated:YES completion:completion];
}

- (void)presentError:(nullable NSString *)message
          controller:(nullable UIViewController *)controller
{
    if (!message) {
        return; // user-initiated cancel
    }
    UIViewController *host = [self topViewControllerFrom:controller];
    if (!host) {
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"Torrent", nil)
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

@end
