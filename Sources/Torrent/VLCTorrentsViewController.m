/*****************************************************************************
 * VLCTorrentsViewController.m
 *****************************************************************************/

#import "VLCTorrentsViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "VLCTorrentFilesViewController.h"
#import "VLCTorrentPlaybackCoordinator.h"
#import "VLCTorrentLibrary.h"
#import "VLCTorrentService.h"

/// Rates and peer counts move continuously and libtorrent posts no alert for
/// every tick, so the list polls while it is on screen and stops when it isn't.
static NSTimeInterval const kRefreshInterval = 1.0;

#pragma mark - Cell

@interface VLCTorrentCell : UITableViewCell
@property (nonatomic, readonly) UIProgressView *progressView;
@end

@implementation VLCTorrentCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier
{
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    if (self) {
        _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_progressView];
        [NSLayoutConstraint activateConstraints:@[
            [_progressView.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [_progressView.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [_progressView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        ]];
        self.detailTextLabel.numberOfLines = 1;
    }
    return self;
}

- (void)applyInfo:(VLCTorrentInfo *)info
{
    self.textLabel.text = info.name;
    self.detailTextLabel.text = info.statusDescription;
    self.progressView.progress = info.progress;

    BOOL const isStream = info.mode == VLCTorrentModeStream;
    self.imageView.image = [UIImage systemImageNamed:isStream ? @"play.circle" : @"arrow.down.circle"];

    switch (info.state) {
        case VLCTorrentStateErrored:
            self.progressView.progressTintColor = UIColor.systemRedColor;
            break;
        case VLCTorrentStatePaused:
            self.progressView.progressTintColor = UIColor.systemGrayColor;
            break;
        case VLCTorrentStateFinished:
        case VLCTorrentStateSeeding:
            self.progressView.progressTintColor = UIColor.systemGreenColor;
            break;
        default:
            self.progressView.progressTintColor = UIColor.systemBlueColor;
            break;
    }
}

@end

#pragma mark - Controller

@interface VLCTorrentsViewController () <UITableViewDataSource, UITableViewDelegate
#if !TARGET_OS_TV
    , UIDocumentPickerDelegate
#endif
>
@property (nonatomic) UITableView *tableView;
@property (nonatomic) UILabel *emptyLabel;
@property (nonatomic) NSArray<VLCTorrentInfo *> *torrents;
@property (nonatomic) NSArray<VLCTorrentBookmark *> *saved;
@property (nonatomic) NSTimer *refreshTimer;
/// Set when the list changed shape while a swipe was open.
@property (nonatomic) BOOL reloadWhenEditingEnds;
@end

@implementation VLCTorrentsViewController

- (instancetype)init
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        // The tab bar reads this before the view ever loads, and tvOS tabs are
        // text-only -- setting it in viewDidLoad leaves an invisible tab.
        self.title = NSLocalizedString(@"Torrents", nil);
        self.tabBarItem.title = NSLocalizedString(@"Torrents", nil);
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = NSLocalizedString(@"Torrents", nil);
#if TARGET_OS_TV
    // tvOS has no systemBackgroundColor; the platform supplies the backdrop.
    self.view.backgroundColor = UIColor.clearColor;
#else
    self.view.backgroundColor = UIColor.systemBackgroundColor;
#endif

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 72;
    [self.tableView registerClass:[VLCTorrentCell class] forCellReuseIdentifier:@"TorrentCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"SavedCell"];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.text = NSLocalizedString(@"No torrents yet.\nAdd a magnet link and it will be saved here for next time.", nil);
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.7],
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(addTorrent)];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refresh)
                                                 name:VLCTorrentListDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refresh)
                                                 name:VLCTorrentLibraryDidChangeNotification
                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_refreshTimer invalidate];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refresh];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:kRefreshInterval
                                                         target:self
                                                       selector:@selector(refresh)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

#pragma mark - Data

- (void)refresh
{
    NSArray<VLCTorrentInfo *> *torrents = [VLCTorrentService.sharedService allTorrents];

    // Anything already running is shown in the active section, so hide its
    // saved twin rather than listing the same torrent twice.
    NSMutableSet<NSString *> *activeHashes = [NSMutableSet set];
    for (VLCTorrentInfo *info in torrents) {
        [activeHashes addObject:info.infoHash.lowercaseString];
    }
    NSMutableArray<VLCTorrentBookmark *> *saved = [NSMutableArray array];
    for (VLCTorrentBookmark *bookmark in VLCTorrentLibrary.sharedLibrary.bookmarks) {
        if (!bookmark.infoHash || ![activeHashes containsObject:bookmark.infoHash]) {
            [saved addObject:bookmark];
        }
    }

    BOOL const sameShape = self.tableView.numberOfSections == 2 &&
        [self.tableView numberOfRowsInSection:0] == (NSInteger)torrents.count &&
        [self.tableView numberOfRowsInSection:1] == (NSInteger)saved.count;

    // Showing a swipe's actions puts the table in editing mode, and a full
    // reload snaps the swipe shut. This used to reload on exactly that
    // condition, once a second, so a swipe closed before it could be tapped.
    // A change of shape now waits for the swipe to close -- and so do the new
    // arrays, or the data source would shrink under rows still on screen.
    if (!sameShape && self.tableView.isEditing) {
        self.reloadWhenEditingEnds = YES;
        return;
    }

    self.torrents = torrents;
    self.saved = saved;
    self.emptyLabel.hidden = torrents.count > 0 || saved.count > 0;

    if (sameShape) {
        // Update visible cells in place, which an open swipe survives.
        for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            if (indexPath.section == 0 && (NSUInteger)indexPath.row < torrents.count) {
                [(VLCTorrentCell *)cell applyInfo:torrents[indexPath.row]];
            } else if (indexPath.section == 1 && (NSUInteger)indexPath.row < saved.count) {
                [self configureSavedCell:cell withBookmark:saved[indexPath.row]];
            }
        }
        return;
    }
    [self.tableView reloadData];
}

#pragma mark - Adding

- (void)addTorrent
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"Add torrent", nil)
                         message:NSLocalizedString(@"Paste a magnet link.", nil)
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"magnet:?xt=urn:btih:...";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        // Offer whatever is on the clipboard, which is nearly always how a
        // magnet link arrives.
#if !TARGET_OS_TV
        NSString *pasted = UIPasteboard.generalPasteboard.string;
        if ([pasted.lowercaseString hasPrefix:@"magnet:"]) {
            field.text = pasted;
        }
#endif
    }];

    __weak VLCTorrentsViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Stream", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf handleMagnet:alert.textFields.firstObject.text stream:YES];
    }]];
#if !TARGET_OS_TV
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Download", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf handleMagnet:alert.textFields.firstObject.text stream:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Open .torrent File\u2026", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf pickTorrentFile];
    }]];
#endif
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#if !TARGET_OS_TV
- (void)pickTorrentFile
{
    UTType *torrent = [UTType typeWithIdentifier:@"org.bittorrent.torrent"]
        ?: [UTType typeWithFilenameExtension:@"torrent"];
    // asCopy hands back a file of our own, so no security scope is involved.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:torrent ? @[torrent] : @[UTTypeData]
                            asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) {
        return;
    }
    [[VLCTorrentPlaybackCoordinator sharedCoordinator] openTorrentFileAtURL:url
                                                       presentingController:self];
    [self refresh];
}
#endif

- (void)handleMagnet:(NSString *)magnet stream:(BOOL)stream
{
    NSString *trimmed = [magnet stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![VLCTorrentPlaybackCoordinator canHandleURLString:trimmed]) {
        [self presentMessage:NSLocalizedString(@"That does not look like a magnet link.", nil)];
        return;
    }

    [VLCTorrentLibrary.sharedLibrary rememberMagnetURI:trimmed];

    if (stream) {
        [[VLCTorrentPlaybackCoordinator sharedCoordinator] streamMagnetURI:trimmed
                                                      presentingController:self];
        return;
    }

    VLCTorrentService *service = VLCTorrentService.sharedService;
    if (!service.isRunning) {
        [service start];
    }
    NSError *error;
    if (![service addMagnetURI:trimmed mode:VLCTorrentModeDownload error:&error]) {
        [self presentMessage:error.localizedDescription];
    }
    [self refresh];
}

#if TARGET_OS_TV
/// Stands in for the swipe actions tvOS has no gesture for.
- (void)presentActionsForTorrent:(VLCTorrentInfo *)info
{
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:info.name
                         message:info.statusDescription
                  preferredStyle:UIAlertControllerStyleAlert];

    __weak VLCTorrentsViewController *weakSelf = self;
    VLCTorrentService *service = VLCTorrentService.sharedService;

    if (info.hasMetadata) {
        [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Choose a file", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            VLCTorrentFilesViewController *files =
                [[VLCTorrentFilesViewController alloc] initWithInfoHash:info.infoHash
                                                                  title:info.name];
            [weakSelf.navigationController pushViewController:files animated:YES];
        }]];
    }

    BOOL const isPaused = info.state == VLCTorrentStatePaused;
    [sheet addAction:[UIAlertAction actionWithTitle:isPaused ? NSLocalizedString(@"Resume", nil)
                                                             : NSLocalizedString(@"Pause", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        if (isPaused) {
            [service resumeTorrentWithInfoHash:info.infoHash];
        } else {
            [service pauseTorrentWithInfoHash:info.infoHash];
        }
        [weakSelf refresh];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Remove", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [service removeTorrentWithInfoHash:info.infoHash deletingFiles:YES];
        [weakSelf refresh];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}
#endif

#pragma mark - Saved torrents

- (void)openBookmark:(VLCTorrentBookmark *)bookmark fromView:(nullable UIView *)view
{
#if TARGET_OS_TV
    UIAlertControllerStyle const style = UIAlertControllerStyleAlert;
#else
    UIAlertControllerStyle const style = UIAlertControllerStyleActionSheet;
#endif
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:bookmark.name
                         message:nil
                  preferredStyle:style];

    __weak VLCTorrentsViewController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Stream", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [VLCTorrentLibrary.sharedLibrary markBookmarkOpened:bookmark];
        [weakSelf handleMagnet:bookmark.magnetURI stream:YES];
    }]];
#if !TARGET_OS_TV
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Download", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [VLCTorrentLibrary.sharedLibrary markBookmarkOpened:bookmark];
        [weakSelf handleMagnet:bookmark.magnetURI stream:NO];
    }]];
#endif
    // tvOS has no swipe actions, so this sheet is its only way to delete.
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Delete\u2026", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [weakSelf confirmDeletionOfBookmark:bookmark fromView:view];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self anchorSheet:sheet toView:view];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)renameBookmark:(VLCTorrentBookmark *)bookmark
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"Rename", nil)
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = bookmark.name;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    __weak VLCTorrentsViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Save", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [VLCTorrentLibrary.sharedLibrary renameBookmark:bookmark
                                                     to:alert.textFields.firstObject.text];
        [weakSelf refresh];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"Torrent", nil)
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? (NSInteger)self.torrents.count : (NSInteger)self.saved.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) {
        return self.torrents.count > 0 ? NSLocalizedString(@"Active", nil) : nil;
    }
    return self.saved.count > 0 ? NSLocalizedString(@"Saved", nil) : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        VLCTorrentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TorrentCell"
                                                               forIndexPath:indexPath];
        [cell applyInfo:self.torrents[indexPath.row]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SavedCell"
                                                            forIndexPath:indexPath];
    [self configureSavedCell:cell withBookmark:self.saved[indexPath.row]];
    return cell;
}

/// Shared by cellForRow and the in-place refresh, so a rename shows straight
/// away instead of waiting for the next full reload.
- (void)configureSavedCell:(UITableViewCell *)cell withBookmark:(VLCTorrentBookmark *)bookmark
{
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = bookmark.name;
    content.image = [UIImage systemImageNamed:@"bookmark"];
    if (bookmark.lastOpened) {
        NSRelativeDateTimeFormatter *formatter = [[NSRelativeDateTimeFormatter alloc] init];
        content.secondaryText = [NSString stringWithFormat:NSLocalizedString(@"Last opened %@", nil),
            [formatter localizedStringForDate:bookmark.lastOpened relativeToDate:[NSDate date]]];
    } else {
        content.secondaryText = NSLocalizedString(@"Not opened yet", nil);
    }
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryNone;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1) {
        [self openBookmark:self.saved[indexPath.row]
                  fromView:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }

    VLCTorrentInfo *info = self.torrents[indexPath.row];
#if TARGET_OS_TV
    // No swipe actions on a remote, so selection has to offer them instead.
    [self presentActionsForTorrent:info];
    return;
#endif
    if (!info.hasMetadata) {
        [self presentMessage:NSLocalizedString(@"Still fetching this torrent's file list.", nil)];
        return;
    }
    VLCTorrentFilesViewController *files =
        [[VLCTorrentFilesViewController alloc] initWithInfoHash:info.infoHash title:info.name];
    [self.navigationController pushViewController:files animated:YES];
}

#if !TARGET_OS_TV
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 1) {
        VLCTorrentBookmark *bookmark = self.saved[indexPath.row];
        __weak VLCTorrentsViewController *weakSelf = self;

        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        // Normal style, painted red, rather than destructive: a destructive
        // action completed with YES makes the table delete the row itself, and
        // nothing has been deleted until the user answers the question below.
        UIContextualAction *deleteAction = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:NSLocalizedString(@"Delete", nil)
                              handler:^(UIContextualAction *action, UIView *view,
                                        void (^completion)(BOOL)) {
            completion(YES);
            [weakSelf confirmDeletionOfBookmark:bookmark fromView:cell];
        }];
        deleteAction.backgroundColor = UIColor.systemRedColor;

        UIContextualAction *rename = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:NSLocalizedString(@"Rename", nil)
                              handler:^(UIContextualAction *action, UIView *view,
                                        void (^completion)(BOOL)) {
            [weakSelf renameBookmark:bookmark];
            completion(YES);
        }];
        rename.backgroundColor = UIColor.systemBlueColor;

        UIContextualAction *copy = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:NSLocalizedString(@"Copy link", nil)
                              handler:^(UIContextualAction *action, UIView *view,
                                        void (^completion)(BOOL)) {
            UIPasteboard.generalPasteboard.string = bookmark.magnetURI;
            completion(YES);
        }];
        copy.backgroundColor = UIColor.systemGrayColor;

        return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, rename, copy]];
    }

    VLCTorrentInfo *info = self.torrents[indexPath.row];
    VLCTorrentService *service = VLCTorrentService.sharedService;
    __weak VLCTorrentsViewController *weakSelf = self;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UIContextualAction *remove = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:NSLocalizedString(@"Remove", nil)
                          handler:^(UIContextualAction *action, UIView *view,
                                    void (^completion)(BOOL)) {
        completion(YES);
        [weakSelf confirmRemovalOfTorrent:info fromView:cell];
    }];
    remove.backgroundColor = UIColor.systemRedColor;

    BOOL const isPaused = info.state == VLCTorrentStatePaused;
    UIContextualAction *toggle = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:isPaused ? NSLocalizedString(@"Resume", nil)
                                           : NSLocalizedString(@"Pause", nil)
                          handler:^(UIContextualAction *action, UIView *view,
                                    void (^completion)(BOOL)) {
        if (isPaused) {
            [service resumeTorrentWithInfoHash:info.infoHash];
        } else {
            [service pauseTorrentWithInfoHash:info.infoHash];
        }
        [weakSelf refresh];
        completion(YES);
    }];
    toggle.backgroundColor = UIColor.systemBlueColor;

    return [UISwipeActionsConfiguration configurationWithActions:@[remove, toggle]];
}
#endif

/// Deleting downloaded media is destructive and easy to do by accident on a
/// swipe, so the files are only removed when explicitly chosen.
- (void)confirmRemovalOfTorrent:(VLCTorrentInfo *)info fromView:(nullable UIView *)view
{
    VLCTorrentService *service = VLCTorrentService.sharedService;
#if TARGET_OS_TV
    UIAlertControllerStyle const removeStyle = UIAlertControllerStyleAlert;
#else
    UIAlertControllerStyle const removeStyle = UIAlertControllerStyleActionSheet;
#endif
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:info.name
                         message:NSLocalizedString(@"Stops it on this device. Its saved link stays in the list.", nil)
                  preferredStyle:removeStyle];

    __weak VLCTorrentsViewController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Remove and keep files", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [service removeTorrentWithInfoHash:info.infoHash deletingFiles:NO];
        [weakSelf refresh];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Remove and delete files", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [service removeTorrentWithInfoHash:info.infoHash deletingFiles:YES];
        [weakSelf refresh];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self anchorSheet:sheet toView:view];
    [self presentViewController:sheet animated:YES completion:nil];
}

/// The library is shared through iCloud now, so where a saved torrent goes
/// away from is a real choice, and it is asked rather than assumed.
- (void)confirmDeletionOfBookmark:(VLCTorrentBookmark *)bookmark fromView:(nullable UIView *)view
{
#if TARGET_OS_TV
    UIAlertControllerStyle const style = UIAlertControllerStyleAlert;
#else
    UIAlertControllerStyle const style = UIAlertControllerStyleActionSheet;
#endif
    // A magnet with no info hash cannot be keyed in the shared store, so it
    // only ever existed on this device.
    BOOL const shareable = bookmark.infoHash != nil;
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Delete \u201c%@\u201d?", nil),
                                                             bookmark.name]
                         message:shareable
            ? NSLocalizedString(@"This device only: your other devices keep it.\nAll devices: it goes from every device signed in to your iCloud account.", nil)
            : NSLocalizedString(@"This link was never shared with your other devices.", nil)
                  preferredStyle:style];

    __weak VLCTorrentsViewController *weakSelf = self;
    VLCTorrentLibrary *library = VLCTorrentLibrary.sharedLibrary;
    [sheet addAction:[UIAlertAction actionWithTitle:shareable
                                                    ? NSLocalizedString(@"Delete on This Device", nil)
                                                    : NSLocalizedString(@"Delete", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [library removeBookmark:bookmark everywhere:NO];
        [weakSelf refresh];
    }]];
    if (shareable) {
        [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Delete on All Devices", nil)
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            [library removeBookmark:bookmark everywhere:YES];
            [weakSelf refresh];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self anchorSheet:sheet toView:view];
    [self presentViewController:sheet animated:YES completion:nil];
}

/// An action sheet on iPad is a popover, and one with a source view but no
/// source rect points at that view's top-left corner, nowhere near the row.
- (void)anchorSheet:(UIAlertController *)sheet toView:(nullable UIView *)view
{
#if !TARGET_OS_TV
    UIView *anchor = view ?: self.tableView;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
#endif
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(nullable NSIndexPath *)indexPath
{
    if (!self.reloadWhenEditingEnds) {
        return;
    }
    self.reloadWhenEditingEnds = NO;
    // Next turn of the run loop, once the table has left editing mode.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

@end
