/*****************************************************************************
 * VLCTorrentLibrary.h: remembered magnet links
 *****************************************************************************
 * A torrent removed from the session takes its magnet with it, so re-watching
 * something means finding and pasting the link again. This keeps a list of
 * every magnet opened, named after the torrent once metadata reveals one.
 *
 * The list is shared across every device signed into the same iCloud account
 * through NSUbiquitousKeyValueStore, keyed on info hash. iPhone, iPad, Apple TV
 * and the Mac all carry the same bundle identifier, so they resolve to one
 * store with no container or schema to configure. It is also the only durable
 * store tvOS offers, which is what the bundled seed plist worked around.
 *
 * How local and remote disagreements are settled lives in one place --
 * -resolveLocal:cloud:removedAt: in the implementation.
 *****************************************************************************/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VLCTorrentBookmark : NSObject

@property (nonatomic, readonly, copy) NSString *magnetURI;
/// Parsed out of the magnet's xt=urn:btih: parameter; nil if it had none.
@property (nonatomic, readonly, copy, nullable) NSString *infoHash;
/// The torrent's real name once known, otherwise the magnet's dn= or a stub.
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) NSDate *dateAdded;
@property (nonatomic, readonly, nullable) NSDate *lastOpened;

@end

/// Posted on the main thread whenever the list changes.
extern NSNotificationName const VLCTorrentLibraryDidChangeNotification;

@interface VLCTorrentLibrary : NSObject

@property (class, nonatomic, readonly) VLCTorrentLibrary *sharedLibrary;

/// Most recently opened first, so what you watch keeps floating to the top.
@property (nonatomic, readonly) NSArray<VLCTorrentBookmark *> *bookmarks;

/// Records a magnet, or returns the existing entry if its hash is already
/// known. Safe to call on every open.
- (nullable VLCTorrentBookmark *)rememberMagnetURI:(NSString *)magnetURI;

- (void)markBookmarkOpened:(VLCTorrentBookmark *)bookmark;
- (void)renameBookmark:(VLCTorrentBookmark *)bookmark to:(NSString *)name;
- (void)removeBookmark:(VLCTorrentBookmark *)bookmark;

/// Pulls real torrent names in once metadata has arrived for them.
- (void)refreshNamesFromActiveTorrents;

/// Everything as newline-separated magnet links, for sharing out.
- (NSString *)exportedText;
/// Adds every magnet found in arbitrary text. Returns how many were new.
- (NSUInteger)importFromText:(NSString *)text;

+ (nullable NSString *)infoHashFromMagnetURI:(NSString *)magnetURI;
+ (nullable NSString *)displayNameFromMagnetURI:(NSString *)magnetURI;

@end

NS_ASSUME_NONNULL_END
