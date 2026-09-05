/*****************************************************************************
 * VLCTorrentService.mm: BitTorrent engine for VLC-iOS
 *****************************************************************************/

#import "VLCTorrentService.h"

#import <Network/Network.h>

#include <algorithm>
#include <atomic>
#include <exception>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/write_resume_data.hpp>

NSNotificationName const VLCTorrentListDidChangeNotification = @"VLCTorrentListDidChangeNotification";
NSNotificationName const VLCTorrentDidFinishNotification = @"VLCTorrentDidFinishNotification";
NSString *const VLCTorrentInfoHashKey = @"VLCTorrentInfoHashKey";
NSString *const VLCTorrentSavePathKey = @"VLCTorrentSavePathKey";
NSErrorDomain const VLCTorrentErrorDomain = @"VLCTorrentErrorDomain";

static NSString *const kResumeFileExtension = @"resume";

namespace {

/// Hex info hash, preferring v1 so it matches what trackers and magnet links use.
std::string HashKey(lt::info_hash_t const &hashes)
{
    std::ostringstream out;
    if (hashes.has_v1()) {
        out << hashes.v1;
    } else {
        out << hashes.v2;
    }
    return out.str();
}

struct Record {
    lt::torrent_handle handle;
    VLCTorrentMode mode = VLCTorrentModeDownload;
    /// Files the user asked to keep. Never evicted.
    std::set<int> keptFiles;
    /// The file currently being streamed, which is transient.
    int streamingFile = -1;
    /// Files whose data we deleted from under libtorrent. Its have-state is
    /// stale for these until a recheck, so re-opening one must force it.
    std::set<int> evictedFiles;
};

NSString *ToNSString(std::string const &s)
{
    NSString *result = [NSString stringWithUTF8String:s.c_str()];
    return result ?: @"";
}

/// Extensions VLC will actually make sense of, used to pick the file to stream
/// and to mark rows in the file picker.
BOOL IsPlayableExtension(NSString *name)
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[
            @"mp4", @"mkv", @"avi", @"mov", @"m4v", @"wmv", @"flv", @"webm",
            @"mpg", @"mpeg", @"m2ts", @"ts", @"ogv", @"3gp", @"rmvb", @"divx",
            @"mp3", @"m4a", @"flac", @"aac", @"ogg", @"opus", @"wav", @"wma",
        ]];
    });
    return [extensions containsObject:name.pathExtension.lowercaseString];
}

} // namespace

#pragma mark - VLCTorrentFile

@implementation VLCTorrentFile

- (instancetype)initWithIndex:(NSInteger)index
                         name:(NSString *)name
                 relativePath:(NSString *)relativePath
                         size:(int64_t)size
                       wanted:(BOOL)wanted
{
    self = [super init];
    if (self) {
        _index = index;
        _name = [name copy];
        _relativePath = [relativePath copy];
        _size = size;
        _wanted = wanted;
        _playable = IsPlayableExtension(name);
    }
    return self;
}

@end

#pragma mark - VLCTorrentInfo

@interface VLCTorrentInfo ()
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) VLCTorrentMode mode;
@property (nonatomic) VLCTorrentState state;
@property (nonatomic) float progress;
@property (nonatomic) int64_t wantedBytes;
@property (nonatomic) int64_t completedBytes;
@property (nonatomic) int downloadRate;
@property (nonatomic) int uploadRate;
@property (nonatomic) int peerCount;
@property (nonatomic) int seedCount;
@property (nonatomic) BOOL hasMetadata;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic, copy, nullable) NSString *localizedErrorDescription;
@end

@implementation VLCTorrentInfo

- (NSString *)statusDescription
{
    switch (self.state) {
        case VLCTorrentStateCheckingResumeData:
            return NSLocalizedString(@"Checking resume data", nil);
        case VLCTorrentStateFetchingMetadata:
            return NSLocalizedString(@"Fetching torrent metadata", nil);
        case VLCTorrentStateCheckingFiles:
            return NSLocalizedString(@"Verifying files", nil);
        case VLCTorrentStatePaused:
            return NSLocalizedString(@"Paused", nil);
        case VLCTorrentStateFinished:
            return NSLocalizedString(@"Completed", nil);
        case VLCTorrentStateSeeding:
            return NSLocalizedString(@"Seeding", nil);
        case VLCTorrentStateErrored:
            return self.localizedErrorDescription ?: NSLocalizedString(@"Failed", nil);
        case VLCTorrentStateDownloading: {
            NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
            formatter.countStyle = NSByteCountFormatterCountStyleFile;
            NSString *rate = [formatter stringFromByteCount:self.downloadRate];
            return [NSString stringWithFormat:
                NSLocalizedString(@"%.0f%% - %@/s - %d peers", nil),
                self.progress * 100.f, rate, self.peerCount];
        }
    }
    return @"";
}

@end

#pragma mark - VLCTorrentService

@implementation VLCTorrentService {
    std::unique_ptr<lt::session> _session;
    std::unordered_map<std::string, Record> _torrents;
    std::atomic<bool> _alertLoopRunning;

    dispatch_queue_t _queue;      // serializes every _session / _torrents touch
    dispatch_queue_t _alertQueue; // hosts the blocking alert loop
    dispatch_semaphore_t _alertLoopStopped;
    nw_path_monitor_t _pathMonitor;
    BOOL _pausedForCellular;
    NSString *_boundInterface;
    dispatch_semaphore_t _firstPathUpdate;
    BOOL _pausedForDiskSpace;
    dispatch_source_t _diskTimer;
}

+ (VLCTorrentService *)sharedService
{
    static VLCTorrentService *sharedService;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[VLCTorrentService alloc] init];
    });
    return sharedService;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("org.videolan.vlc.torrent.session", DISPATCH_QUEUE_SERIAL);
        _alertQueue = dispatch_queue_create("org.videolan.vlc.torrent.alerts", DISPATCH_QUEUE_SERIAL);
        _alertLoopStopped = dispatch_semaphore_create(0);
        _firstPathUpdate = dispatch_semaphore_create(0);
        _alertLoopRunning = false;
        _allowsCellularTransfers = NO;
        _seedsAfterCompletion = NO;
        _minimumFreeBytes = 2LL * 1000 * 1000 * 1000;
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

#pragma mark - Paths

- (NSString *)downloadDirectory
{
#if TARGET_OS_TV
    // tvOS guarantees no persistent local storage, which is why VLC roots its
    // medialibrary in Caches there too. Nothing kept here is truly permanent:
    // the system may purge it whenever it wants the space back.
    NSString *root = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                         NSUserDomainMask, YES).firstObject;
#else
    NSString *root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
#endif
    return [root stringByAppendingPathComponent:@"Torrents"];
}

- (NSString *)streamCacheDirectory
{
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                           NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"TorrentStream"];
}

- (NSString *)resumeDirectory
{
#if TARGET_OS_TV
    NSString *support = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                            NSUserDomainMask, YES).firstObject;
#else
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                            NSUserDomainMask, YES).firstObject;
#endif
    return [support stringByAppendingPathComponent:@"Torrents"];
}

/// One location for everything. Streaming used to save into a purgeable cache
/// and get promoted on keep, but with nothing fetched until it is picked there
/// is no longer a meaningful difference between the two.
- (NSString *)savePathForMode:(VLCTorrentMode)mode
{
    return self.downloadDirectory;
}

/// Mode is recovered on relaunch from which directory the data sits in, so it
/// needs no separate bookkeeping.
- (VLCTorrentMode)modeForSavePath:(std::string const &)savePath
{
    NSString *path = ToNSString(savePath);
    return [path hasPrefix:self.streamCacheDirectory] ? VLCTorrentModeStream
                                                      : VLCTorrentModeDownload;
}

- (BOOL)ensureDirectory:(NSString *)path
{
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:path]) {
        return YES;
    }
    NSError *error;
    if (![manager createDirectoryAtPath:path
            withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"VLCTorrentService: cannot create %@: %@", path, error);
        return NO;
    }
    return YES;
}

#pragma mark - Lifecycle

- (BOOL)isRunning
{
    __block BOOL running = NO;
    dispatch_sync(_queue, ^{
        running = _session != nullptr;
    });
    return running;
}

- (void)start
{
    [self ensureDirectory:self.downloadDirectory];
    [self ensureDirectory:self.streamCacheDirectory];
    [self ensureDirectory:self.resumeDirectory];

    // Learn the route *before* the session exists. Creating it bound to
    // 0.0.0.0 and narrowing afterwards means it briefly opens sockets on
    // every interface -- AWDL, llw0, link-local and each utun VPN tunnel --
    // and announces from them before we can stop it.
    [self startPathMonitor];
    dispatch_semaphore_wait(_firstPathUpdate,
                            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

    dispatch_sync(_queue, ^{
        if (_session) {
            return;
        }

        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::user_agent, "VLC-iOS/4.0 libtorrent/" LIBTORRENT_VERSION);
        // Peer discovery. LSD stays off: it multicasts, which this build has no
        // entitlement for, and it would trip the Local Network prompt for nothing.
        settings.set_bool(lt::settings_pack::enable_dht, true);
        settings.set_bool(lt::settings_pack::enable_lsd, false);
        settings.set_bool(lt::settings_pack::enable_upnp, false);
        settings.set_bool(lt::settings_pack::enable_natpmp, false);
        // One interface, ephemeral port. libtorrent's default is a fixed
        // 0.0.0.0:6881, and if that bind fails the session ends up with no
        // sockets at all, which kills UDP -- so DHT never bootstraps and UDP
        // tracker announces never go out. A NATed mobile client gains nothing
        // from a predictable port anyway.
        settings.set_str(lt::settings_pack::listen_interfaces,
                         [self listenInterfacesSetting]);
        if (_boundInterface.length > 0) {
            settings.set_str(lt::settings_pack::outgoing_interfaces,
                             _boundInterface.UTF8String);
        }
        // Modest limits: this is a phone or tablet, not a seedbox.
        settings.set_int(lt::settings_pack::connections_limit, 100);
        settings.set_int(lt::settings_pack::active_downloads, 4);
        settings.set_int(lt::settings_pack::alert_mask,
                         lt::alert_category::status | lt::alert_category::error |
                         lt::alert_category::storage | lt::alert_category::tracker |
                         lt::alert_category::dht);
        _session = std::make_unique<lt::session>(lt::session_params(settings));
        NSLog(@"VLCTorrentService: session bound to %@", _boundInterface ?: @"(all interfaces)");
    });

    [self startAlertLoop];
    [self startDiskMonitor];
    [self loadPersistedTorrents];
}

/// Runs on _queue, or before the session exists.
- (std::string)listenInterfacesSetting
{
    if (_boundInterface.length > 0) {
        return std::string(_boundInterface.UTF8String) + ":0";
    }
    // Offline, or the route could not be identified in time. Binding
    // everything is worse for privacy but at least keeps the session usable;
    // the next path update narrows it.
    return "0.0.0.0:0,[::]:0";
}

#pragma mark - Alert loop

- (void)startAlertLoop
{
    if (_alertLoopRunning.exchange(true)) {
        return;
    }

    // Take the session pointer once. lt::session is safe to use from any
    // thread, so the loop must NOT hold _queue while it blocks in
    // wait_for_alert -- that would stall the UI's status polling for up to
    // half a second at a time. -stop joins this loop before destroying the
    // session, which is what keeps the raw pointer safe.
    __block lt::session *session = nullptr;
    dispatch_sync(_queue, ^{
        session = _session.get();
    });
    if (!session) {
        _alertLoopRunning = false;
        return;
    }

    __weak VLCTorrentService *weakSelf = self;
    dispatch_async(_alertQueue, ^{
        std::vector<lt::alert *> alerts;
        while (true) {
            VLCTorrentService *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->_alertLoopRunning) {
                break;
            }

            if (!session->wait_for_alert(lt::milliseconds(500))) {
                continue;
            }
            alerts.clear();
            session->pop_alerts(&alerts);
            for (lt::alert *alert : alerts) {
                if (!strongSelf->_alertLoopRunning) {
                    break;
                }
                [strongSelf handleAlert:alert];
            }
        }
        VLCTorrentService *strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_semaphore_signal(strongSelf->_alertLoopStopped);
        }
    });
}

- (void)handleAlert:(lt::alert *)alert
{
    if (auto *added = lt::alert_cast<lt::add_torrent_alert>(alert)) {
        if (added->error) {
            NSLog(@"VLCTorrentService: add failed: %s", added->error.message().c_str());
            return;
        }
        [self postListDidChange];
        return;
    }

    if (auto *metadata = lt::alert_cast<lt::metadata_received_alert>(alert)) {
        // A magnet has become a real torrent, so the file list finally exists.
        // Want none of it: adding a season pack should cost nothing until the
        // user picks something out of it.
        if (metadata->handle.is_valid()) {
            [self wantNothingByDefault:metadata->handle];
        }
        [self postListDidChange];
        return;
    }

    if (auto *finished = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
        [self handleFinishedTorrent:finished->handle];
        return;
    }

    if (auto *failed = lt::alert_cast<lt::torrent_error_alert>(alert)) {
        NSLog(@"VLCTorrentService: torrent error: %s", failed->error.message().c_str());
        [self postListDidChange];
        return;
    }

    if (auto *saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
        [self writeResumeData:saved->params];
        return;
    }

    if (auto *fileError = lt::alert_cast<lt::file_error_alert>(alert)) {
        NSLog(@"[VLCTorrent] FILE ERROR %s: %s",
              fileError->filename(), fileError->error.message().c_str());
        return;
    }

    if (lt::alert_cast<lt::listen_failed_alert>(alert) ||
        lt::alert_cast<lt::tracker_error_alert>(alert) ||
        lt::alert_cast<lt::tracker_reply_alert>(alert) ||
        lt::alert_cast<lt::dht_bootstrap_alert>(alert) ||
        lt::alert_cast<lt::listen_succeeded_alert>(alert)) {
        NSLog(@"[VLCTorrent] net: %s", alert->message().c_str());
        return;
    }

    if (auto *saveFailed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
        // Expected for torrents with nothing worth persisting yet.
        if (saveFailed->error != lt::errors::resume_data_not_modified) {
            NSLog(@"VLCTorrentService: save_resume_data failed: %s",
                  saveFailed->error.message().c_str());
        }
        return;
    }
}

- (void)handleFinishedTorrent:(lt::torrent_handle)handle
{
    if (!handle.is_valid()) {
        return;
    }

    lt::torrent_status status = handle.status();
    std::string key = HashKey(status.info_hashes);
    VLCTorrentMode mode = [self modeForSavePath:status.save_path];

    if (!self.seedsAfterCompletion) {
        handle.pause();
    }
    handle.save_resume_data(lt::torrent_handle::save_info_dict);

    // Streaming torrents live in Caches and must not reach the medialibrary.
    if (mode == VLCTorrentModeDownload) {
        NSString *infoHash = ToNSString(key);
        NSString *savePath = ToNSString(status.save_path);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:VLCTorrentDidFinishNotification
                              object:self
                            userInfo:@{ VLCTorrentInfoHashKey: infoHash,
                                        VLCTorrentSavePathKey: savePath }];
        });
    }
    [self postListDidChange];
}

- (void)postListDidChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:VLCTorrentListDidChangeNotification object:self];
    });
}

#pragma mark - Cellular policy

- (void)startPathMonitor
{
    if (_pathMonitor) {
        return;
    }

    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, _queue);

    __weak VLCTorrentService *weakSelf = self;
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        VLCTorrentService *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf applyCellularPolicyForExpensivePath:nw_path_is_expensive(path)];
        [strongSelf bindToInterface:[VLCTorrentService primaryInterfaceForPath:path]];
        dispatch_semaphore_signal(strongSelf->_firstPathUpdate);
    });
    nw_path_monitor_start(_pathMonitor);
}

/// The interface carrying the default route, in the system's own order of
/// preference. With a VPN up that is the tunnel, which is what we want: one
/// interface, chosen the same way the OS chooses it.
+ (nullable NSString *)primaryInterfaceForPath:(nw_path_t)path
{
    if (nw_path_get_status(path) != nw_path_status_satisfied) {
        return nil;
    }

    __block NSString *name;
    nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
        if (nw_interface_get_type(interface) == nw_interface_type_loopback) {
            return true; // keep looking
        }
        char const *interfaceName = nw_interface_get_name(interface);
        if (interfaceName) {
            name = @(interfaceName);
        }
        return false; // first non-loopback wins
    });
    return name;
}

/// Confine both listening and outgoing connections to one interface.
///
/// The default "0.0.0.0" binds *everything*: AWDL, llw0, link-local, 169.254.x
/// and every utun VPN tunnel. libtorrent then announces from all of them, so a
/// tracker sees the VPN tunnel and the LAN address in the same breath, which is
/// the classic torrent-over-VPN deanonymisation leak. Runs on _queue.
- (void)bindToInterface:(nullable NSString *)interfaceName
{
    if (interfaceName == _boundInterface || [interfaceName isEqualToString:_boundInterface]) {
        return;
    }

    _boundInterface = [interfaceName copy];

    // Before -start creates the session this just records the name, which
    // -listenInterfacesSetting then uses to bind it correctly from birth.
    if (!_session) {
        return;
    }

    lt::settings_pack settings;
    if (interfaceName.length > 0) {
        // Device name rather than address, so libtorrent follows the interface
        // when DHCP hands it a new one.
        std::string const device = interfaceName.UTF8String;
        settings.set_str(lt::settings_pack::listen_interfaces, device + ":0");
        settings.set_str(lt::settings_pack::outgoing_interfaces, device);
        NSLog(@"VLCTorrentService: binding to %@", interfaceName);
    } else {
        // Offline. Naming a device that does not exist means no listen sockets
        // at all, so clear the setting rather than point it at something stale.
        settings.set_str(lt::settings_pack::listen_interfaces, "");
        settings.set_str(lt::settings_pack::outgoing_interfaces, "");
        NSLog(@"VLCTorrentService: no route, unbinding");
    }
    _session->apply_settings(std::move(settings));
}

/// Runs on _queue, courtesy of nw_path_monitor_set_queue.
- (void)applyCellularPolicyForExpensivePath:(BOOL)expensive
{
    if (!_session) {
        return;
    }
    BOOL shouldPause = expensive && !self.allowsCellularTransfers;
    if (shouldPause == _pausedForCellular) {
        return;
    }
    _pausedForCellular = shouldPause;
    if (shouldPause) {
        NSLog(@"VLCTorrentService: pausing session, connection is metered");
        _session->pause();
    } else {
        _session->resume();
    }
    [self postListDidChange];
}

- (void)setAllowsCellularTransfers:(BOOL)allowsCellularTransfers
{
    _allowsCellularTransfers = allowsCellularTransfers;
    // Re-evaluate against the current route rather than waiting for it to change.
    if (allowsCellularTransfers) {
        dispatch_async(_queue, ^{
            [self applyCellularPolicyForExpensivePath:NO];
        });
    }
}

#pragma mark - Adding

- (BOOL)hasRoomForBytes:(int64_t)bytes error:(NSError **)error
{
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfFileSystemForPath:self.downloadDirectory error:nil];
    int64_t freeBytes = [attributes[NSFileSystemFreeSize] longLongValue];
    // bytes is 0 for a magnet with no metadata yet; only the floor applies then.
    if (freeBytes - bytes >= self.minimumFreeBytes) {
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:VLCTorrentErrorDomain
                                     code:VLCTorrentErrorInsufficientDiskSpace
                                 userInfo:@{ NSLocalizedDescriptionKey:
                                     NSLocalizedString(@"Not enough free space on this device.", nil) }];
    }
    return NO;
}

- (nullable NSString *)addTorrentParams:(lt::add_torrent_params)params
                                   mode:(VLCTorrentMode)mode
                                  error:(NSError **)error
{
    if (![self hasRoomForBytes:0 error:error]) {
        return nil;
    }

    NSString *savePath = [self savePathForMode:mode];
    if (![self ensureDirectory:savePath]) {
        return nil;
    }
    params.save_path = savePath.fileSystemRepresentation;

    if (mode == VLCTorrentModeStream) {
        params.flags |= lt::torrent_flags::sequential_download;
    }

    std::string key = HashKey(params.info_hashes);
    if (key.empty()) {
        if (error) {
            *error = [NSError errorWithDomain:VLCTorrentErrorDomain
                                         code:VLCTorrentErrorInvalidMagnet
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         NSLocalizedString(@"That link carries no usable torrent hash.", nil) }];
        }
        return nil;
    }

    __block BOOL duplicate = NO;
    __block BOOL noSession = NO;
    dispatch_sync(_queue, ^{
        if (!_session) {
            noSession = YES;
            return;
        }
        if (_torrents.find(key) != _torrents.end()) {
            duplicate = YES;
            return;
        }
        lt::error_code ec;
        lt::torrent_handle handle = _session->add_torrent(params, ec);
        if (ec || !handle.is_valid()) {
            NSLog(@"VLCTorrentService: add_torrent failed: %s", ec.message().c_str());
            return;
        }
        Record record;
        record.handle = handle;
        record.mode = mode;
        _torrents[key] = record;
    });

    if (noSession) {
        if (error) {
            *error = [NSError errorWithDomain:VLCTorrentErrorDomain
                                         code:VLCTorrentErrorSessionNotRunning
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         NSLocalizedString(@"The torrent engine is not running.", nil) }];
        }
        return nil;
    }
    if (duplicate) {
        if (error) {
            *error = [NSError errorWithDomain:VLCTorrentErrorDomain
                                         code:VLCTorrentErrorDuplicate
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         NSLocalizedString(@"That torrent has already been added.", nil) }];
        }
        // Still hand back the hash: the caller can just show the existing one.
        return ToNSString(key);
    }
    return ToNSString(key);
}

- (nullable NSString *)addMagnetURI:(NSString *)magnetURI
                               mode:(VLCTorrentMode)mode
                              error:(NSError **)error
{
    lt::error_code ec;
    lt::add_torrent_params params = lt::parse_magnet_uri(magnetURI.UTF8String, ec);
    if (ec) {
        if (error) {
            *error = [NSError errorWithDomain:VLCTorrentErrorDomain
                                         code:VLCTorrentErrorInvalidMagnet
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         ToNSString(ec.message()) }];
        }
        return nil;
    }
    return [self addTorrentParams:std::move(params) mode:mode error:error];
}

- (nullable NSString *)addTorrentFileAtPath:(NSString *)path
                                       mode:(VLCTorrentMode)mode
                                      error:(NSError **)error
{
    // libtorrent 2.1 dropped the (filename, error_code&) constructor; the
    // supported entry point throws and hands back a filled add_torrent_params.
    lt::add_torrent_params params;
    try {
        params = lt::load_torrent_file(path.fileSystemRepresentation);
    } catch (std::exception const &exception) {
        if (error) {
            *error = [NSError errorWithDomain:VLCTorrentErrorDomain
                                         code:VLCTorrentErrorInvalidTorrentFile
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         @(exception.what()) }];
        }
        return nil;
    }

    if (![self hasRoomForBytes:(params.ti ? params.ti->total_size() : 0) error:error]) {
        return nil;
    }
    return [self addTorrentParams:std::move(params) mode:mode error:error];
}

#pragma mark - Persistence

- (NSString *)resumePathForKey:(std::string const &)key
{
    return [[self.resumeDirectory stringByAppendingPathComponent:ToNSString(key)]
        stringByAppendingPathExtension:kResumeFileExtension];
}

- (void)writeResumeData:(lt::add_torrent_params const &)params
{
    std::vector<char> buffer = lt::write_resume_data_buf(params);
    NSData *data = [NSData dataWithBytes:buffer.data() length:buffer.size()];
    NSString *path = [self resumePathForKey:HashKey(params.info_hashes)];
    NSError *error;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"VLCTorrentService: cannot persist resume data: %@", error);
    }
}

- (void)saveState
{
    dispatch_sync(_queue, ^{
        if (!_session) {
            return;
        }
        for (auto const &entry : _torrents) {
            lt::torrent_handle const &handle = entry.second.handle;
            if (handle.is_valid() && handle.need_save_resume_data()) {
                handle.save_resume_data(lt::torrent_handle::save_info_dict |
                                        lt::torrent_handle::only_if_modified);
            }
        }
    });
    // The alert loop writes the files as save_resume_data_alerts arrive.
}

- (void)loadPersistedTorrents
{
    NSArray<NSString *> *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:self.resumeDirectory error:nil];
    for (NSString *name in names) {
        if (![name.pathExtension isEqualToString:kResumeFileExtension]) {
            continue;
        }
        NSString *path = [self.resumeDirectory stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) {
            continue;
        }

        lt::error_code ec;
        lt::span<char const> buffer(static_cast<char const *>(data.bytes),
                                    static_cast<std::ptrdiff_t>(data.length));
        lt::add_torrent_params params = lt::read_resume_data(buffer, ec);
        if (ec) {
            NSLog(@"VLCTorrentService: discarding unreadable resume file %@: %s",
                  name, ec.message().c_str());
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            continue;
        }

        VLCTorrentMode mode = [self modeForSavePath:params.save_path];
        std::string key = HashKey(params.info_hashes);
        __block lt::torrent_handle restored;
        dispatch_sync(_queue, ^{
            if (!_session || _torrents.find(key) != _torrents.end()) {
                return;
            }
            lt::error_code addError;
            lt::torrent_handle handle = _session->add_torrent(params, addError);
            if (addError || !handle.is_valid()) {
                return;
            }
            Record record;
            record.handle = handle;
            record.mode = mode;
            [self loadKeptFilesForInfoHash:key into:record];
            _torrents[key] = record;
            restored = handle;
        });

        // A torrent restored from resume data already has its metadata, so it
        // never emits metadata_received_alert and would keep fetching whatever
        // it was fetching under the old rules. Apply the new default -- want
        // nothing but what was kept -- outside the queue, since
        // -wantNothingByDefault: takes it itself.
        if (restored.is_valid()) {
            [self wantNothingByDefault:restored];
        }
    }
    [self postListDidChange];
}

#pragma mark - Inspection

- (VLCTorrentState)stateForStatus:(lt::torrent_status const &)status
{
    if (status.errc) {
        return VLCTorrentStateErrored;
    }
    if (status.flags & lt::torrent_flags::paused) {
        return VLCTorrentStatePaused;
    }
    switch (status.state) {
        case lt::torrent_status::checking_resume_data:
            return VLCTorrentStateCheckingResumeData;
        case lt::torrent_status::downloading_metadata:
            return VLCTorrentStateFetchingMetadata;
        case lt::torrent_status::checking_files:
            return VLCTorrentStateCheckingFiles;
        case lt::torrent_status::downloading:
            return VLCTorrentStateDownloading;
        case lt::torrent_status::finished:
            return VLCTorrentStateFinished;
        case lt::torrent_status::seeding:
            return VLCTorrentStateSeeding;
        default:
            return VLCTorrentStateDownloading;
    }
}

- (VLCTorrentInfo *)infoForRecord:(Record const &)record key:(std::string const &)key
{
    lt::torrent_status status = record.handle.status();
    VLCTorrentInfo *info = [[VLCTorrentInfo alloc] init];
    info.infoHash = ToNSString(key);
    info.name = status.name.empty() ? ToNSString(key) : ToNSString(status.name);
    info.mode = record.mode;
    info.state = [self stateForStatus:status];
    info.progress = status.progress;
    info.wantedBytes = status.total_wanted;
    info.completedBytes = status.total_wanted_done;
    info.downloadRate = status.download_payload_rate;
    info.uploadRate = status.upload_payload_rate;
    info.peerCount = status.num_peers;
    info.seedCount = status.num_seeds;
    info.hasMetadata = status.has_metadata;
    info.savePath = ToNSString(status.save_path);
    if (status.errc) {
        info.localizedErrorDescription = ToNSString(status.errc.message());
    }
    return info;
}

- (NSArray<VLCTorrentInfo *> *)allTorrents
{
    NSMutableArray<VLCTorrentInfo *> *result = [NSMutableArray array];
    dispatch_sync(_queue, ^{
        for (auto const &entry : _torrents) {
            if (!entry.second.handle.is_valid()) {
                continue;
            }
            [result addObject:[self infoForRecord:entry.second key:entry.first]];
        }
    });
    [result sortUsingComparator:^NSComparisonResult(VLCTorrentInfo *a, VLCTorrentInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return result;
}

- (nullable VLCTorrentInfo *)torrentWithInfoHash:(NSString *)infoHash
{
    std::string key = infoHash.UTF8String;
    __block VLCTorrentInfo *info;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found != _torrents.end() && found->second.handle.is_valid()) {
            info = [self infoForRecord:found->second key:found->first];
        }
    });
    return info;
}

- (NSArray<VLCTorrentFile *> *)filesForTorrentWithInfoHash:(NSString *)infoHash
{
    std::string key = infoHash.UTF8String;
    NSMutableArray<VLCTorrentFile *> *files = [NSMutableArray array];
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found == _torrents.end() || !found->second.handle.is_valid()) {
            return;
        }
        lt::torrent_handle const &handle = found->second.handle;
        std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
        if (!info) {
            return; // magnet without metadata yet
        }

        std::vector<lt::download_priority_t> priorities = handle.get_file_priorities();
        lt::file_storage const &storage = info->layout();
        for (int index = 0; index < storage.num_files(); ++index) {
            lt::file_index_t fileIndex{index};
            BOOL wanted = YES;
            if (static_cast<size_t>(index) < priorities.size()) {
                wanted = priorities[static_cast<size_t>(index)] != lt::dont_download;
            }
            [files addObject:[[VLCTorrentFile alloc]
                initWithIndex:index
                         name:ToNSString(std::string(storage.file_name(fileIndex)))
                 relativePath:ToNSString(storage.file_path(fileIndex))
                         size:storage.file_size(fileIndex)
                       wanted:wanted]];
        }
    });
    // Finder-style ordering: localizedStandardCompare: is number-aware, so
    // "Episode 2" precedes "Episode 10" instead of following it.
    [files sortUsingComparator:^NSComparisonResult(VLCTorrentFile *a, VLCTorrentFile *b) {
        return [a.relativePath localizedStandardCompare:b.relativePath];
    }];
    return files;
}

#pragma mark - Control

- (void)withHandleForInfoHash:(NSString *)infoHash
                        block:(void (^)(lt::torrent_handle const &handle))block
{
    std::string key = infoHash.UTF8String;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found != _torrents.end() && found->second.handle.is_valid()) {
            block(found->second.handle);
        }
    });
}

- (void)pauseTorrentWithInfoHash:(NSString *)infoHash
{
    [self withHandleForInfoHash:infoHash block:^(lt::torrent_handle const &handle) {
        // Clearing auto_managed keeps libtorrent's queue from un-pausing it.
        handle.unset_flags(lt::torrent_flags::auto_managed);
        handle.pause();
    }];
    [self postListDidChange];
}

- (void)resumeTorrentWithInfoHash:(NSString *)infoHash
{
    [self withHandleForInfoHash:infoHash block:^(lt::torrent_handle const &handle) {
        handle.set_flags(lt::torrent_flags::auto_managed);
        handle.resume();
    }];
    [self postListDidChange];
}

- (void)removeTorrentWithInfoHash:(NSString *)infoHash deletingFiles:(BOOL)deleteFiles
{
    std::string key = infoHash.UTF8String;
    NSString *resumePath = [self resumePathForKey:key];

    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found == _torrents.end()) {
            return;
        }
        if (_session && found->second.handle.is_valid()) {
            _session->remove_torrent(found->second.handle,
                                     deleteFiles ? lt::session_handle::delete_files
                                                 : lt::remove_flags_t{});
        }
        _torrents.erase(found);
    });

    [[NSFileManager defaultManager] removeItemAtPath:resumePath error:nil];
    [self postListDidChange];
}

/// Runs on _queue. Everything starts unwanted; the user's picks are restored
/// from the kept set so a relaunch does not undo them.
- (void)wantNothingByDefault:(lt::torrent_handle const &)handle
{
    if (!handle.is_valid()) {
        return;
    }
    std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
    if (!info) {
        return;
    }

    std::string const key = HashKey(handle.status().info_hashes);
    __block std::set<int> kept;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found != _torrents.end()) {
            kept = found->second.keptFiles;
        }
    });

    int const fileCount = info->layout().num_files();
    std::vector<lt::download_priority_t> priorities;
    priorities.reserve(static_cast<size_t>(fileCount));
    for (int index = 0; index < fileCount; index++) {
        priorities.push_back(kept.count(index) > 0 ? lt::default_priority
                                                   : lt::dont_download);
    }
    handle.prioritize_files(priorities);
}

- (void)streamFileIndex:(NSInteger)fileIndex inTorrentWithInfoHash:(NSString *)infoHash
{
    int const index = static_cast<int>(fileIndex);
    __block NSString *evictPath;
    __block BOOL needsRecheck = NO;

    dispatch_sync(_queue, ^{
        auto found = _torrents.find(std::string(infoHash.UTF8String));
        if (found == _torrents.end() || !found->second.handle.is_valid()) {
            return;
        }
        Record &record = found->second;
        lt::torrent_handle const &handle = record.handle;

        // Moving on from a transient file discards it. Kept files are exempt,
        // and so is the file being opened.
        int const previous = record.streamingFile;
        if (previous >= 0 && previous != index &&
            record.keptFiles.count(previous) == 0) {
            handle.file_priority(lt::file_index_t{previous}, lt::dont_download);
            evictPath = [self pathForFileIndex:previous handle:handle];
            record.evictedFiles.insert(previous);
        }

        // libtorrent still believes it holds pieces we deleted, so it would
        // never re-fetch them. A recheck is the only way to correct that, and
        // it is only paid when the user actually returns to an evicted file.
        if (record.evictedFiles.erase(index) > 0) {
            needsRecheck = YES;
        }

        record.streamingFile = index;
        handle.file_priority(lt::file_index_t{index}, lt::top_priority);
        handle.set_flags(lt::torrent_flags::sequential_download);
    });

    if (evictPath) {
        NSError *error;
        if ([[NSFileManager defaultManager] removeItemAtPath:evictPath error:&error]) {
            NSLog(@"VLCTorrentService: evicted %@", evictPath.lastPathComponent);
        } else if (error.code != NSFileNoSuchFileError) {
            NSLog(@"VLCTorrentService: could not evict %@: %@", evictPath, error);
        }
    }

    if (needsRecheck) {
        NSLog(@"VLCTorrentService: rechecking, file %d was evicted earlier", index);
        [self withHandleForInfoHash:infoHash block:^(lt::torrent_handle const &handle) {
            handle.force_recheck();
        }];
    }
    [self postListDidChange];
}

/// Runs on _queue with the handle already in hand.
- (nullable NSString *)pathForFileIndex:(int)fileIndex handle:(lt::torrent_handle const &)handle
{
    std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
    if (!info) {
        return nil;
    }
    lt::file_storage const &storage = info->layout();
    if (fileIndex < 0 || fileIndex >= storage.num_files()) {
        return nil;
    }
    NSString *root = ToNSString(handle.status().save_path);
    NSString *relative = ToNSString(storage.file_path(lt::file_index_t{fileIndex}));
    return [root stringByAppendingPathComponent:relative];
}

- (void)keepFileIndex:(NSInteger)fileIndex inTorrentWithInfoHash:(NSString *)infoHash
{
    int const index = static_cast<int>(fileIndex);
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(std::string(infoHash.UTF8String));
        if (found == _torrents.end() || !found->second.handle.is_valid()) {
            return;
        }
        found->second.keptFiles.insert(index);
        found->second.evictedFiles.erase(index);
        // Only ever raise: keeping something must not cancel what is playing.
        found->second.handle.file_priority(lt::file_index_t{index}, lt::top_priority);
    });
    [self persistKeptFiles];
    [self postListDidChange];
}

- (BOOL)isFileKept:(NSInteger)fileIndex inTorrentWithInfoHash:(NSString *)infoHash
{
    __block BOOL kept = NO;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(std::string(infoHash.UTF8String));
        kept = found != _torrents.end() &&
               found->second.keptFiles.count(static_cast<int>(fileIndex)) > 0;
    });
    return kept;
}

- (BOOL)isFileStreaming:(NSInteger)fileIndex inTorrentWithInfoHash:(NSString *)infoHash
{
    __block BOOL streaming = NO;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(std::string(infoHash.UTF8String));
        streaming = found != _torrents.end() &&
                    found->second.streamingFile == static_cast<int>(fileIndex);
    });
    return streaming;
}

#pragma mark - Disk space

- (int64_t)freeDiskBytes
{
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfFileSystemForPath:self.downloadDirectory error:nil];
    return [attributes[NSFileSystemFreeSize] longLongValue];
}

- (BOOL)pausedForDiskSpace
{
    return _pausedForDiskSpace;
}

/// The add-time free-space check said nothing about what happens over the next
/// twelve gigabytes, so watch it as data lands.
- (void)enforceDiskSpaceLimit
{
    BOOL const low = self.freeDiskBytes < self.minimumFreeBytes;
    if (low == _pausedForDiskSpace) {
        return;
    }
    _pausedForDiskSpace = low;

    dispatch_sync(_queue, ^{
        if (!_session) {
            return;
        }
        if (low) {
            NSLog(@"VLCTorrentService: pausing, only %lld bytes free", self.freeDiskBytes);
            _session->pause();
        } else if (!_pausedForCellular) {
            _session->resume();
        }
    });
    [self postListDidChange];
}

- (void)startDiskMonitor
{
    if (_diskTimer) {
        return;
    }
    _diskTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_diskTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              5 * NSEC_PER_SEC, NSEC_PER_SEC);
    __weak VLCTorrentService *weakSelf = self;
    dispatch_source_set_event_handler(_diskTimer, ^{
        [weakSelf enforceDiskSpaceLimit];
    });
    dispatch_resume(_diskTimer);
}

#pragma mark - Kept-file persistence

- (NSString *)keptFilesPath
{
    return [self.resumeDirectory stringByAppendingPathComponent:@"kept.plist"];
}

/// Resume data does not carry our notion of "kept", so it rides alongside.
- (void)persistKeptFiles
{
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *plist = [NSMutableDictionary dictionary];
    dispatch_sync(_queue, ^{
        for (auto const &entry : _torrents) {
            if (entry.second.keptFiles.empty()) {
                continue;
            }
            NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
            for (int index : entry.second.keptFiles) {
                [indexes addObject:@(index)];
            }
            plist[ToNSString(entry.first)] = indexes;
        }
    });
    [plist writeToFile:[self keptFilesPath] atomically:YES];
}

- (void)loadKeptFilesForInfoHash:(std::string const &)key into:(Record &)record
{
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[self keptFilesPath]];
    NSArray<NSNumber *> *indexes = plist[ToNSString(key)];
    for (NSNumber *index in indexes) {
        record.keptFiles.insert(index.intValue);
    }
}

- (void)setWantedFileIndexes:(nullable NSArray<NSNumber *> *)indexes
      forTorrentWithInfoHash:(NSString *)infoHash
{
    NSSet<NSNumber *> *wanted = indexes ? [NSSet setWithArray:indexes] : nil;
    [self withHandleForInfoHash:infoHash block:^(lt::torrent_handle const &handle) {
        std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
        if (!info) {
            return;
        }
        int fileCount = info->layout().num_files();
        std::vector<lt::download_priority_t> priorities;
        priorities.reserve(static_cast<size_t>(fileCount));
        for (int index = 0; index < fileCount; ++index) {
            BOOL isWanted = wanted == nil || [wanted containsObject:@(index)];
            priorities.push_back(isWanted ? lt::default_priority : lt::dont_download);
        }
        handle.prioritize_files(priorities);
    }];
    [self postListDidChange];
}

- (NSString *)sessionDiagnostics
{
    __block NSString *result = @"no session";
    dispatch_sync(_queue, ^{
        if (!_session) {
            return;
        }
        result = [NSString stringWithFormat:
                  @"paused=%d listening=%d dht=%d meteredPause=%d boundTo=%@",
                  _session->is_paused(), _session->is_listening(),
                  _session->is_dht_running(), _pausedForCellular,
                  _boundInterface ?: @"(all)"];
    });
    return result;
}

#pragma mark - Streaming support

- (NSArray<VLCTorrentFile *> *)playableFilesInPlaybackOrderForTorrentWithInfoHash:(NSString *)infoHash
{
    NSArray<VLCTorrentFile *> *all = [self filesForTorrentWithInfoHash:infoHash];

    int64_t largest = 0;
    for (VLCTorrentFile *file in all) {
        if (file.isPlayable && file.size > largest) {
            largest = file.size;
        }
    }
    if (largest == 0) {
        return @[];
    }

    // Season packs hold episodes of comparable size, so anything a fraction of
    // the biggest is a sample, trailer or extra -- exactly the thing that must
    // not become "episode one" just because its name sorts first.
    int64_t const floorSize = largest / 20;
    NSMutableArray<VLCTorrentFile *> *playable = [NSMutableArray array];
    for (VLCTorrentFile *file in all) {
        if (!file.isPlayable || file.size < floorSize) {
            continue;
        }
        if ([file.name rangeOfString:@"sample" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            continue;
        }
        [playable addObject:file];
    }
    // -filesForTorrentWithInfoHash: already returns natural order.
    return playable;
}

- (NSInteger)primaryPlayableFileIndexForTorrentWithInfoHash:(NSString *)infoHash
{
    VLCTorrentFile *first =
        [self playableFilesInPlaybackOrderForTorrentWithInfoHash:infoHash].firstObject;
    return first ? first.index : NSNotFound;
}

- (nullable NSString *)pathForFileIndex:(NSInteger)fileIndex
                  inTorrentWithInfoHash:(NSString *)infoHash
{
    std::string key = infoHash.UTF8String;
    __block NSString *path;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found == _torrents.end() || !found->second.handle.is_valid()) {
            return;
        }
        std::shared_ptr<const lt::torrent_info> info = found->second.handle.torrent_file();
        if (!info) {
            return;
        }
        lt::file_storage const &storage = info->layout();
        if (fileIndex < 0 || fileIndex >= storage.num_files()) {
            return;
        }
        NSString *root = ToNSString(found->second.handle.status().save_path);
        NSString *relative = ToNSString(storage.file_path(lt::file_index_t{static_cast<int>(fileIndex)}));
        path = [root stringByAppendingPathComponent:relative];
    });
    return path;
}

- (int64_t)sizeOfFileIndex:(NSInteger)fileIndex
     inTorrentWithInfoHash:(NSString *)infoHash
{
    std::string key = infoHash.UTF8String;
    __block int64_t size = 0;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found == _torrents.end() || !found->second.handle.is_valid()) {
            return;
        }
        std::shared_ptr<const lt::torrent_info> info = found->second.handle.torrent_file();
        if (!info) {
            return;
        }
        lt::file_storage const &storage = info->layout();
        if (fileIndex < 0 || fileIndex >= storage.num_files()) {
            return;
        }
        size = storage.file_size(lt::file_index_t{static_cast<int>(fileIndex)});
    });
    return size;
}

- (int64_t)availableBytesForFileIndex:(NSInteger)fileIndex
                inTorrentWithInfoHash:(NSString *)infoHash
                           fileOffset:(int64_t)fileOffset
                            maxLength:(int64_t)maxLength
{
    if (maxLength <= 0 || fileOffset < 0) {
        return 0;
    }

    std::string key = infoHash.UTF8String;
    __block int64_t available = 0;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found == _torrents.end() || !found->second.handle.is_valid()) {
            return;
        }
        lt::torrent_handle const &handle = found->second.handle;
        std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
        if (!info) {
            return;
        }
        lt::file_storage const &storage = info->layout();
        if (fileIndex < 0 || fileIndex >= storage.num_files()) {
            return;
        }
        lt::file_index_t const file{static_cast<int>(fileIndex)};
        int64_t const fileSize = storage.file_size(file);
        if (fileOffset >= fileSize) {
            return;
        }
        int64_t const wanted = std::min(maxLength, fileSize - fileOffset);

        // Walk forward from the piece under the cursor for as long as pieces
        // are present, so a single read can drain everything already on disk.
        lt::peer_request const request = info->map_file(file, fileOffset, 0);
        int const pieceLength = info->piece_length();
        int const pieceCount = info->num_pieces();
        int piece = static_cast<int>(request.piece);
        int offsetInPiece = request.start;

        while (available < wanted && piece < pieceCount) {
            if (!handle.have_piece(lt::piece_index_t{piece})) {
                break;
            }
            available += pieceLength - offsetInPiece;
            offsetInPiece = 0;
            piece++;
        }
        available = std::min(available, wanted);
    });
    return available;
}

- (void)requestFileIndex:(NSInteger)fileIndex
   inTorrentWithInfoHash:(NSString *)infoHash
              fileOffset:(int64_t)fileOffset
                  length:(int64_t)length
{
    if (length <= 0) {
        return;
    }

    std::string key = infoHash.UTF8String;
    dispatch_sync(_queue, ^{
        auto found = _torrents.find(key);
        if (found == _torrents.end() || !found->second.handle.is_valid()) {
            return;
        }
        lt::torrent_handle const &handle = found->second.handle;
        std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
        if (!info) {
            return;
        }
        lt::file_storage const &storage = info->layout();
        if (fileIndex < 0 || fileIndex >= storage.num_files()) {
            return;
        }
        lt::file_index_t const file{static_cast<int>(fileIndex)};
        int64_t const fileSize = storage.file_size(file);
        if (fileOffset >= fileSize) {
            return;
        }

        // Priorities belong to -streamFileIndex: and -keepFileIndex: now. This
        // only ever nudges the read window forward, so it cannot undo a pick.

        int64_t const wanted = std::min(length, fileSize - fileOffset);
        lt::peer_request const first = info->map_file(file, fileOffset, 0);
        lt::peer_request const last = info->map_file(file, fileOffset + wanted - 1, 0);
        int const pieceCount = info->num_pieces();

        // Ascending deadlines so the swarm delivers in playback order rather
        // than all at once; the piece under the cursor is the most urgent.
        int rank = 0;
        for (int piece = static_cast<int>(first.piece);
             piece <= static_cast<int>(last.piece) && piece < pieceCount;
             piece++, rank++) {
            if (handle.have_piece(lt::piece_index_t{piece})) {
                continue;
            }
            handle.set_piece_deadline(lt::piece_index_t{piece}, rank * 100);
        }
    });
}

#pragma mark - Helpers

+ (BOOL)isMagnetURL:(NSURL *)url
{
    return [url.scheme caseInsensitiveCompare:@"magnet"] == NSOrderedSame;
}

+ (BOOL)isTorrentFileURL:(NSURL *)url
{
    return [url.pathExtension caseInsensitiveCompare:@"torrent"] == NSOrderedSame;
}

@end
