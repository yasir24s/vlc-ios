/*****************************************************************************
 * VLCTorrentPlaybackCoordinator.m
 *****************************************************************************/

#import "VLCTorrentPlaybackCoordinator.h"

#import "VLCPlaybackService.h"
#import "VLCTorrentHTTPServer.h"
#import "VLCTorrentService.h"

/// Fetching metadata for a magnet means finding peers first, so this can take
/// a while on a cold or thinly seeded swarm.
static NSTimeInterval const kMetadataTimeout = 90.0;
static NSTimeInterval const kMetadataPollInterval = 0.5;

@implementation VLCTorrentPlaybackCoordinator {
    UIAlertController *_progressAlert;
    NSString *_pendingInfoHash;
    NSTimer *_pollTimer;
    NSDate *_startDate;
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
    // Metadata is already in hand, so this needs no waiting UI.
    [self playTorrentWithInfoHash:infoHash fileIndex:fileIndex name:info.name];
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
        NSInteger fileIndex =
            [service primaryPlayableFileIndexForTorrentWithInfoHash:infoHash];
        if (fileIndex != NSNotFound) {
            [self playTorrentWithInfoHash:infoHash fileIndex:fileIndex name:info.name];
            return;
        }
        // Metadata arrived but nothing in it is playable: no point waiting.
        if ([service filesForTorrentWithInfoHash:infoHash].count > 0) {
            [self finishWithError:
                NSLocalizedString(@"This torrent contains no playable media.", nil)];
            return;
        }
    }

    // Keep the user informed rather than showing a stalled spinner.
    _progressAlert.message = [NSString stringWithFormat:
        NSLocalizedString(@"%@\n%d peers", nil), info.statusDescription, info.peerCount];

    if (-[_startDate timeIntervalSinceNow] > kMetadataTimeout) {
        [self finishWithError:
            NSLocalizedString(@"Timed out finding peers for this torrent.", nil)];
    }
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
        startIndex = 0;
    }
    if (startIndex == NSNotFound) {
        startIndex = 0;
    }

    NSLog(@"VLCTorrentPlaybackCoordinator: playing %lu file(s) from index %ld",
          (unsigned long)mediaList.count, (long)startIndex);

    _pendingInfoHash = nil;
    [self stopPolling];

    [self dismissProgressWithCompletion:^{
        [[VLCPlaybackService sharedInstance] playMediaList:mediaList
                                                firstIndex:startIndex
                                         subtitlesFilePath:nil];
    }];
}

- (void)finishWithError:(nullable NSString *)message
{
    NSString *infoHash = _pendingInfoHash;
    _pendingInfoHash = nil;
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
