/*****************************************************************************
 * VLCTorrentFilesViewController.h: files inside one torrent
 *****************************************************************************/

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VLCTorrentFilesViewController : UIViewController

- (instancetype)initWithInfoHash:(NSString *)infoHash title:(nullable NSString *)title;

@end

NS_ASSUME_NONNULL_END
