/*****************************************************************************
 * VLCTorrentLibrary.m
 *****************************************************************************/

#import "VLCTorrentLibrary.h"

#import "VLCTorrentService.h"

NSNotificationName const VLCTorrentLibraryDidChangeNotification =
    @"VLCTorrentLibraryDidChangeNotification";

static NSString *const kMagnetKey = @"magnet";
static NSString *const kInfoHashKey = @"infoHash";
static NSString *const kNameKey = @"name";
static NSString *const kAddedKey = @"added";
static NSString *const kOpenedKey = @"opened";

/// One iCloud key per magnet rather than a single key holding the whole list:
/// two devices that each add something while apart both survive the merge,
/// where one shared value would let whichever synced last erase the other's.
static NSString *const kCloudBookmarkPrefix = @"bm.";
/// A removal has to be published, not merely applied. A device that was offline
/// when it happened still holds the magnet and would otherwise put it back.
static NSString *const kCloudTombstonePrefix = @"rm.";

#pragma mark - Bookmark

@interface VLCTorrentBookmark ()
@property (nonatomic, copy) NSString *magnetURI;
@property (nonatomic, copy, nullable) NSString *infoHash;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSDate *dateAdded;
@property (nonatomic, nullable) NSDate *lastOpened;
@end

@implementation VLCTorrentBookmark

- (NSDictionary *)dictionaryRepresentation
{
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    dictionary[kMagnetKey] = self.magnetURI;
    dictionary[kInfoHashKey] = self.infoHash;
    dictionary[kNameKey] = self.name;
    dictionary[kAddedKey] = self.dateAdded;
    dictionary[kOpenedKey] = self.lastOpened;
    return dictionary;
}

+ (nullable VLCTorrentBookmark *)bookmarkWithDictionary:(NSDictionary *)dictionary
{
    NSString *magnet = dictionary[kMagnetKey];
    if (![magnet isKindOfClass:[NSString class]] || magnet.length == 0) {
        return nil;
    }
    VLCTorrentBookmark *bookmark = [[VLCTorrentBookmark alloc] init];
    bookmark.magnetURI = magnet;
    bookmark.infoHash = dictionary[kInfoHashKey];
    bookmark.name = dictionary[kNameKey] ?: magnet;
    bookmark.dateAdded = dictionary[kAddedKey] ?: [NSDate date];
    bookmark.lastOpened = dictionary[kOpenedKey];
    return bookmark;
}

@end

#pragma mark - Library

@implementation VLCTorrentLibrary {
    NSMutableArray<VLCTorrentBookmark *> *_bookmarks;
    /// Info hashes deleted on this device only. Local, never synced: every
    /// other device still lists them.
    NSMutableSet<NSString *> *_hidden;
}

+ (VLCTorrentLibrary *)sharedLibrary
{
    static VLCTorrentLibrary *sharedLibrary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLibrary = [[VLCTorrentLibrary alloc] init];
    });
    return sharedLibrary;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bookmarks = [NSMutableArray array];
        _hidden = [NSMutableSet set];
        [self load];
        [self loadHidden];
        [self importFromSeedSources];
        // Magnets carry at best a dn= hint, so adopt the torrent's real name
        // as soon as metadata produces one.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(refreshNamesFromActiveTorrents)
                                                     name:VLCTorrentListDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(cloudDidChangeExternally:)
                   name:NSUbiquitousKeyValueStoreDidChangeExternallyNotification
                 object:nil];
        [self mergeFromCloud];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Storage

- (NSString *)storePath
{
#if TARGET_OS_TV
    // Application Support is not writable on tvOS -- creating it fails and
    // every save is silently lost. Caches is what the platform actually gives
    // you, which is why VLC keeps its medialibrary there too.
    NSString *support = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                            NSUserDomainMask, YES).firstObject;
#else
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                            NSUserDomainMask, YES).firstObject;
#endif
    NSString *directory = [support stringByAppendingPathComponent:@"Torrents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return [directory stringByAppendingPathComponent:@"library.plist"];
}

- (void)load
{
    NSArray *stored = [NSArray arrayWithContentsOfFile:[self storePath]];
    for (NSDictionary *dictionary in stored) {
        if (![dictionary isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        VLCTorrentBookmark *bookmark = [VLCTorrentBookmark bookmarkWithDictionary:dictionary];
        if (bookmark) {
            [_bookmarks addObject:bookmark];
        }
    }
    [self sort];
}

- (void)save
{
    [self persistLocally];
    [self pushToCloud];
}

/// Writes the on-disk copy and announces the change. Separate from -save so a
/// merge can store the agreed result without immediately re-publishing it.
- (void)persistLocally
{
    NSMutableArray *plist = [NSMutableArray array];
    for (VLCTorrentBookmark *bookmark in _bookmarks) {
        [plist addObject:[bookmark dictionaryRepresentation]];
    }
    if (![plist writeToFile:[self storePath] atomically:YES]) {
        NSLog(@"VLCTorrentLibrary: could not save");
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:VLCTorrentLibraryDidChangeNotification object:self];
    });
}

- (NSString *)hiddenPath
{
    return [[[self storePath] stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"hidden.plist"];
}

- (void)loadHidden
{
    for (id hash in [NSArray arrayWithContentsOfFile:[self hiddenPath]]) {
        if ([hash isKindOfClass:[NSString class]]) {
            [_hidden addObject:[hash lowercaseString]];
        }
    }
}

- (void)saveHidden
{
    if (![_hidden.allObjects writeToFile:[self hiddenPath] atomically:YES]) {
        NSLog(@"VLCTorrentLibrary: could not save the hidden list");
    }
}

/// YES when a passive source must not bring this magnet back: it was deleted
/// here, or deleted everywhere. Only an explicit request overrides either.
- (BOOL)isSuppressed:(NSString *)hash
{
    if ([_hidden containsObject:hash]) {
        return YES;
    }
    return [[self cloudStore] objectForKey:
        [kCloudTombstonePrefix stringByAppendingString:hash]] != nil;
}

- (NSString *)torrentFilesDirectory
{
    NSString *directory = [[[self storePath] stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"files"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return directory;
}

- (NSString *)storedTorrentPathForHash:(NSString *)hash
{
    return [[self torrentFilesDirectory] stringByAppendingPathComponent:
        [hash.lowercaseString stringByAppendingPathExtension:@"torrent"]];
}

- (nullable NSString *)torrentFilePathForInfoHash:(NSString *)infoHash
{
    NSString *path = [self storedTorrentPathForHash:infoHash];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

- (void)removeTorrentFileForInfoHash:(NSString *)hash
{
    [[NSFileManager defaultManager] removeItemAtPath:[self storedTorrentPathForHash:hash]
                                               error:nil];
}

- (void)sort
{
    [_bookmarks sortUsingComparator:^NSComparisonResult(VLCTorrentBookmark *a,
                                                        VLCTorrentBookmark *b) {
        NSDate *left = a.lastOpened ?: a.dateAdded;
        NSDate *right = b.lastOpened ?: b.dateAdded;
        return [right compare:left];
    }];
}

#pragma mark - Shared across devices

/*
 * The library is shared through iCloud's key-value store rather than CloudKit
 * or a document in iCloud Drive. Magnets are a few hundred bytes each, so the
 * store's 1 MB and 1024-key budget is ample, and it needs no container schema
 * and no server. It is also the one durable store tvOS actually offers, which
 * is what the seed-plist workaround existed to paper over.
 *
 * Entries are keyed on info hash, so the same magnet added on two devices is
 * one entry. A magnet with no xt=urn:btih: cannot be keyed and stays local.
 */

- (NSUbiquitousKeyValueStore *)cloudStore
{
    // Non-nil even with no iCloud account -- writes simply never leave the
    // device, so the library keeps working and just stops being shared.
    return [NSUbiquitousKeyValueStore defaultStore];
}

- (void)pushToCloud
{
    NSUbiquitousKeyValueStore *store = [self cloudStore];
    for (VLCTorrentBookmark *bookmark in _bookmarks) {
        if (!bookmark.infoHash) {
            continue;
        }
        [store setDictionary:[bookmark dictionaryRepresentation]
                      forKey:[kCloudBookmarkPrefix
                                 stringByAppendingString:bookmark.infoHash.lowercaseString]];
    }
    [store synchronize];
}

- (void)publishRemovalOf:(VLCTorrentBookmark *)bookmark
{
    if (!bookmark.infoHash) {
        return;
    }
    NSString *hash = bookmark.infoHash.lowercaseString;
    NSUbiquitousKeyValueStore *store = [self cloudStore];
    [store removeObjectForKey:[kCloudBookmarkPrefix stringByAppendingString:hash]];
    // Stored as a time interval rather than an NSDate so the value survives
    // whatever plist round-tripping the store does to it.
    [store setDouble:[NSDate date].timeIntervalSince1970
              forKey:[kCloudTombstonePrefix stringByAppendingString:hash]];
    [store synchronize];
}

- (void)cloudDidChangeExternally:(NSNotification *)notification
{
    // Delivered off the main thread; _bookmarks is touched from the main one.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self mergeFromCloud];
    });
}

- (void)mergeFromCloud
{
    NSDictionary<NSString *, id> *cloud = [[self cloudStore] dictionaryRepresentation];
    if (cloud.count == 0) {
        // First device to run: seed the shared store from what it already has.
        [self pushToCloud];
        return;
    }

    NSMutableDictionary<NSString *, VLCTorrentBookmark *> *mine = [NSMutableDictionary dictionary];
    NSMutableArray<VLCTorrentBookmark *> *unkeyed = [NSMutableArray array];
    for (VLCTorrentBookmark *bookmark in _bookmarks) {
        if (bookmark.infoHash) {
            mine[bookmark.infoHash.lowercaseString] = bookmark;
        } else {
            [unkeyed addObject:bookmark];
        }
    }

    NSMutableDictionary<NSString *, VLCTorrentBookmark *> *theirs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDate *> *removals = [NSMutableDictionary dictionary];
    for (NSString *key in cloud) {
        if ([key hasPrefix:kCloudBookmarkPrefix]) {
            id value = cloud[key];
            if (![value isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            VLCTorrentBookmark *bookmark = [VLCTorrentBookmark bookmarkWithDictionary:value];
            if (bookmark) {
                theirs[[key substringFromIndex:kCloudBookmarkPrefix.length]] = bookmark;
            }
        } else if ([key hasPrefix:kCloudTombstonePrefix]) {
            id value = cloud[key];
            if ([value isKindOfClass:[NSNumber class]]) {
                removals[[key substringFromIndex:kCloudTombstonePrefix.length]] =
                    [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
            }
        }
    }

    NSMutableSet<NSString *> *hashes = [NSMutableSet setWithArray:mine.allKeys];
    [hashes addObjectsFromArray:theirs.allKeys];

    NSMutableArray<VLCTorrentBookmark *> *merged = [NSMutableArray arrayWithArray:unkeyed];
    for (NSString *hash in hashes) {
        // Deleted on this device only: the shared store still lists it for
        // everyone else, it just stays off this device's list.
        if ([_hidden containsObject:hash]) {
            continue;
        }
        VLCTorrentBookmark *keep = [self resolveLocal:mine[hash]
                                                cloud:theirs[hash]
                                            removedAt:removals[hash]];
        if (keep) {
            [merged addObject:keep];
        } else {
            // Another device deleted it everywhere; its local .torrent goes too.
            [self removeTorrentFileForInfoHash:hash];
        }
    }

    _bookmarks = merged;
    [self sort];
    [self persistLocally];
    [self pushToCloud];
}

/// Decides the fate of one magnet during a merge. Called once per info hash
/// seen on this device, in the shared store, or both.
///
/// @param local     what this device already had, or nil if it is new here.
/// @param cloud     what another device published, or nil if only we have it.
/// @param removedAt when some device deleted it, or nil if none did.
/// @return the bookmark to keep, or nil to drop it from the library.
- (nullable VLCTorrentBookmark *)resolveLocal:(nullable VLCTorrentBookmark *)local
                                        cloud:(nullable VLCTorrentBookmark *)cloud
                                    removedAt:(nullable NSDate *)removedAt
{
    // TODO: this is the policy decision -- see the note in the header.
    // Placeholder: additive union, deletions apply only if nothing newer
    // re-added the magnet afterwards.
    VLCTorrentBookmark *keep = local ?: cloud;
    if (removedAt && keep && [keep.dateAdded compare:removedAt] == NSOrderedAscending) {
        return nil;
    }
    return keep;
}

#pragma mark - Access

- (NSArray<VLCTorrentBookmark *> *)bookmarks
{
    return [_bookmarks copy];
}

- (nullable VLCTorrentBookmark *)bookmarkForMagnetURI:(NSString *)magnetURI
{
    NSString *hash = [VLCTorrentLibrary infoHashFromMagnetURI:magnetURI];
    for (VLCTorrentBookmark *bookmark in _bookmarks) {
        if (hash && bookmark.infoHash &&
            [bookmark.infoHash caseInsensitiveCompare:hash] == NSOrderedSame) {
            return bookmark;
        }
        if ([bookmark.magnetURI isEqualToString:magnetURI]) {
            return bookmark;
        }
    }
    return nil;
}

- (nullable VLCTorrentBookmark *)rememberMagnetURI:(NSString *)magnetURI
{
    return [self rememberMagnetURI:magnetURI explicitly:YES];
}

/// `explicitly` means the user asked for this magnet -- pasted it, opened it --
/// which overrides an earlier delete on this device. The bundled seed list and
/// the tvOS upload folder are passive: left to themselves they would put back,
/// on every launch, whatever had been deleted.
- (nullable VLCTorrentBookmark *)rememberMagnetURI:(NSString *)magnetURI
                                        explicitly:(BOOL)explicitly
{
    NSString *trimmed = [magnetURI stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed.lowercaseString hasPrefix:@"magnet:"]) {
        return nil;
    }

    NSString *hash = [VLCTorrentLibrary infoHashFromMagnetURI:trimmed].lowercaseString;
    if (hash) {
        if (!explicitly && [self isSuppressed:hash]) {
            return nil;
        }
        if (explicitly && [_hidden containsObject:hash]) {
            [_hidden removeObject:hash];
            [self saveHidden];
        }
    }

    VLCTorrentBookmark *existing = [self bookmarkForMagnetURI:trimmed];
    if (existing) {
        return existing;
    }

    VLCTorrentBookmark *bookmark = [[VLCTorrentBookmark alloc] init];
    bookmark.magnetURI = trimmed;
    bookmark.infoHash = [VLCTorrentLibrary infoHashFromMagnetURI:trimmed];
    bookmark.name = [VLCTorrentLibrary displayNameFromMagnetURI:trimmed]
        ?: NSLocalizedString(@"Untitled torrent", nil);
    // A passive import has no moment the user chose it, so it carries none: any
    // deletion must beat it. Dated now, a fresh install's seed list would
    // out-date an older delete-everywhere tombstone, win the merge, and put the
    // magnet back on every device.
    bookmark.dateAdded = explicitly ? [NSDate date] : [NSDate distantPast];
    [_bookmarks addObject:bookmark];
    [self sort];
    [self save];
    return bookmark;
}

- (void)markBookmarkOpened:(VLCTorrentBookmark *)bookmark
{
    bookmark.lastOpened = [NSDate date];
    [self sort];
    [self save];
}

- (void)renameBookmark:(VLCTorrentBookmark *)bookmark to:(NSString *)name
{
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return;
    }
    bookmark.name = trimmed;
    [self save];
}

- (void)removeBookmark:(VLCTorrentBookmark *)bookmark everywhere:(BOOL)everywhere
{
    [_bookmarks removeObject:bookmark];
    NSString *hash = bookmark.infoHash.lowercaseString;
    if (hash) {
        [self removeTorrentFileForInfoHash:hash];
        if (everywhere) {
            // Publish before saving: -save republishes what remains, and on
            // its own that says nothing about what just went away.
            [self publishRemovalOf:bookmark];
        } else {
            // Without remembering this, the next merge would fetch it straight
            // back from the shared store.
            [_hidden addObject:hash];
            [self saveHidden];
        }
    }
    [self save];
}

- (nullable VLCTorrentBookmark *)rememberTorrentFileAtPath:(NSString *)path
{
    return [self rememberTorrentFileAtPath:path explicitly:YES];
}

- (nullable VLCTorrentBookmark *)rememberTorrentFileAtPath:(NSString *)path
                                                explicitly:(BOOL)explicitly
{
    NSString *magnet = [VLCTorrentService magnetURIForTorrentFileAtPath:path];
    if (!magnet) {
        return nil;
    }
    VLCTorrentBookmark *bookmark = [self rememberMagnetURI:magnet explicitly:explicitly];
    NSString *hash = bookmark.infoHash.lowercaseString;
    if (hash) {
        // Only the magnet is shared. The .torrent stays on this device because
        // it carries the file list, so opening from it needs no peers at all.
        NSString *copy = [self storedTorrentPathForHash:hash];
        if (![path isEqualToString:copy]) {
            [[NSFileManager defaultManager] removeItemAtPath:copy error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:path toPath:copy error:nil];
        }
    }
    return bookmark;
}

- (void)refreshNamesFromActiveTorrents
{
    BOOL changed = NO;
    NSArray<VLCTorrentInfo *> *active = [VLCTorrentService.sharedService allTorrents];
    for (VLCTorrentInfo *info in active) {
        if (!info.hasMetadata || info.name.length == 0) {
            continue;
        }
        for (VLCTorrentBookmark *bookmark in _bookmarks) {
            if (!bookmark.infoHash ||
                [bookmark.infoHash caseInsensitiveCompare:info.infoHash] != NSOrderedSame) {
                continue;
            }
            if (![bookmark.name isEqualToString:info.name]) {
                bookmark.name = info.name;
                changed = YES;
            }
        }
    }
    if (changed) {
        [self save];
    }
}

/// devicectl cannot reliably write into a tvOS app's real data container, so
/// the list arrives by other means: a plist bundled at build time, and any
/// file dropped into VLC's own Wi-Fi upload directory. Both are imported once
/// and are no-ops when there is nothing new.
- (void)importFromSeedSources
{
    NSUInteger added = 0;

    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"seed-magnets" ofType:@"plist"];
    NSArray *seed = bundled ? [NSArray arrayWithContentsOfFile:bundled] : nil;
    for (NSDictionary *entry in seed) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *magnet = entry[kMagnetKey];
        if (![magnet isKindOfClass:[NSString class]] || [self bookmarkForMagnetURI:magnet]) {
            continue;
        }
        VLCTorrentBookmark *bookmark = [self rememberMagnetURI:magnet explicitly:NO];
        if (!bookmark) {
            continue;
        }
        NSString *name = entry[kNameKey];
        if ([name isKindOfClass:[NSString class]]) {
            bookmark.name = name;
        }
        added++;
    }

    // Anything the user uploads through VLC's existing web interface.
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                           NSUserDomainMask, YES).firstObject;
    NSString *uploads = [caches stringByAppendingPathComponent:@"Upload"];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:uploads error:nil]) {
        NSString *extension = name.pathExtension.lowercaseString;
        NSString *path = [uploads stringByAppendingPathComponent:name];
        // tvOS has no Files app, so VLC's web upload is the only way a .torrent
        // reaches the Apple TV.
        if ([extension isEqualToString:@"torrent"]) {
            NSUInteger const before = _bookmarks.count;
            [self rememberTorrentFileAtPath:path explicitly:NO];
            added += _bookmarks.count - before;
            continue;
        }
        if (![extension isEqualToString:@"txt"] && ![extension isEqualToString:@"magnets"] &&
            ![extension isEqualToString:@"plist"]) {
            continue;
        }
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (text) {
            added += [self importFromText:text explicitly:NO];
        }
    }

    if (added > 0) {
        NSLog(@"[VLCTorrentLibrary] seeded %lu magnet(s)", (unsigned long)added);
        [self save];
    }
}

#pragma mark - Import and export

- (NSString *)exportedText
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (VLCTorrentBookmark *bookmark in _bookmarks) {
        [lines addObject:bookmark.magnetURI];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSUInteger)importFromText:(NSString *)text
{
    return [self importFromText:text explicitly:YES];
}

- (NSUInteger)importFromText:(NSString *)text explicitly:(BOOL)explicitly
{
    // Scan rather than split on newlines, so a page of pasted text works as
    // well as a tidy list.
    NSUInteger added = 0;
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"magnet:\\?[^\\s\"'<>]+"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSArray<NSTextCheckingResult *> *matches =
        [expression matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in matches) {
        NSString *magnet = [text substringWithRange:match.range];
        if (![self bookmarkForMagnetURI:magnet] &&
            [self rememberMagnetURI:magnet explicitly:explicitly]) {
            added++;
        }
    }
    return added;
}

#pragma mark - Magnet parsing

+ (nullable NSString *)infoHashFromMagnetURI:(NSString *)magnetURI
{
    NSRange range = [magnetURI rangeOfString:@"xt=urn:btih:"
                                     options:NSCaseInsensitiveSearch];
    if (range.location == NSNotFound) {
        return nil;
    }
    NSString *rest = [magnetURI substringFromIndex:NSMaxRange(range)];
    NSRange end = [rest rangeOfString:@"&"];
    if (end.location != NSNotFound) {
        rest = [rest substringToIndex:end.location];
    }
    return rest.length > 0 ? rest.lowercaseString : nil;
}

+ (nullable NSString *)displayNameFromMagnetURI:(NSString *)magnetURI
{
    NSRange range = [magnetURI rangeOfString:@"dn=" options:NSCaseInsensitiveSearch];
    if (range.location == NSNotFound) {
        return nil;
    }
    NSString *rest = [magnetURI substringFromIndex:NSMaxRange(range)];
    NSRange end = [rest rangeOfString:@"&"];
    if (end.location != NSNotFound) {
        rest = [rest substringToIndex:end.location];
    }
    rest = [rest stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return rest.stringByRemovingPercentEncoding ?: rest;
}

@end
