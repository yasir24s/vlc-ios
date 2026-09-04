/*****************************************************************************
 * VLCTorrentFilesViewController.h: files inside one torrent
 *****************************************************************************/

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VLCTorrentFilesViewController : UIViewController

- (instancetype)initWithInfoHash:(NSString *)infoHash title:(nullable NSString *)title;

/// Presented modally straight after a magnet resolves, when the torrent turns
/// out to hold more than one playable file. Adds a "Play all from the start"
/// row and a Done button; picking anything dismisses.
@property (nonatomic) BOOL presentedAsChooser;

@end

NS_ASSUME_NONNULL_END
