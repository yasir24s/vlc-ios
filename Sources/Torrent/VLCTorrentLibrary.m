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
        [self load];
        // Magnets carry at best a dn= hint, so adopt the torrent's real name
        // as soon as metadata produces one.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(refreshNamesFromActiveTorrents)
                                                     name:VLCTorrentListDidChangeNotification
                                                   object:nil];
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
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                            NSUserDomainMask, YES).firstObject;
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

- (void)sort
{
    [_bookmarks sortUsingComparator:^NSComparisonResult(VLCTorrentBookmark *a,
                                                        VLCTorrentBookmark *b) {
        NSDate *left = a.lastOpened ?: a.dateAdded;
        NSDate *right = b.lastOpened ?: b.dateAdded;
        return [right compare:left];
    }];
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
    NSString *trimmed = [magnetURI stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed.lowercaseString hasPrefix:@"magnet:"]) {
        return nil;
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
    bookmark.dateAdded = [NSDate date];
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

- (void)removeBookmark:(VLCTorrentBookmark *)bookmark
{
    [_bookmarks removeObject:bookmark];
    [self save];
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
        if (![self bookmarkForMagnetURI:magnet] && [self rememberMagnetURI:magnet]) {
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
