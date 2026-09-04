/*****************************************************************************
 * VLCTorrentsViewController.m
 *****************************************************************************/

#import "VLCTorrentsViewController.h"

#import "VLCTorrentFilesViewController.h"
#import "VLCTorrentPlaybackCoordinator.h"
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

@interface VLCTorrentsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic) UITableView *tableView;
@property (nonatomic) UILabel *emptyLabel;
@property (nonatomic) NSArray<VLCTorrentInfo *> *torrents;
@property (nonatomic) NSTimer *refreshTimer;
@end

@implementation VLCTorrentsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = NSLocalizedString(@"Torrents", nil);
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 72;
    [self.tableView registerClass:[VLCTorrentCell class] forCellReuseIdentifier:@"TorrentCell"];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.text = NSLocalizedString(@"No torrents.\nAdd a magnet link to stream or download.", nil);
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
    self.torrents = [VLCTorrentService.sharedService allTorrents];
    self.emptyLabel.hidden = self.torrents.count > 0;

    // Reload visible rows in place so the table doesn't fight the user's
    // scrolling or dismiss a swipe action every second.
    if (self.tableView.numberOfSections == 1 &&
        [self.tableView numberOfRowsInSection:0] == (NSInteger)self.torrents.count &&
        !self.tableView.isEditing) {
        for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
            VLCTorrentCell *cell = (VLCTorrentCell *)[self.tableView cellForRowAtIndexPath:indexPath];
            if ((NSUInteger)indexPath.row < self.torrents.count) {
                [cell applyInfo:self.torrents[indexPath.row]];
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
        NSString *pasted = UIPasteboard.generalPasteboard.string;
        if ([pasted.lowercaseString hasPrefix:@"magnet:"]) {
            field.text = pasted;
        }
    }];

    __weak VLCTorrentsViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Stream", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf handleMagnet:alert.textFields.firstObject.text stream:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Download", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf handleMagnet:alert.textFields.firstObject.text stream:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleMagnet:(NSString *)magnet stream:(BOOL)stream
{
    NSString *trimmed = [magnet stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![VLCTorrentPlaybackCoordinator canHandleURLString:trimmed]) {
        [self presentMessage:NSLocalizedString(@"That does not look like a magnet link.", nil)];
        return;
    }

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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.torrents.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    VLCTorrentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TorrentCell"
                                                           forIndexPath:indexPath];
    [cell applyInfo:self.torrents[indexPath.row]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    VLCTorrentInfo *info = self.torrents[indexPath.row];
    if (!info.hasMetadata) {
        [self presentMessage:NSLocalizedString(@"Still fetching this torrent's file list.", nil)];
        return;
    }
    VLCTorrentFilesViewController *files =
        [[VLCTorrentFilesViewController alloc] initWithInfoHash:info.infoHash title:info.name];
    [self.navigationController pushViewController:files animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    VLCTorrentInfo *info = self.torrents[indexPath.row];
    VLCTorrentService *service = VLCTorrentService.sharedService;
    __weak VLCTorrentsViewController *weakSelf = self;

    UIContextualAction *remove = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:NSLocalizedString(@"Remove", nil)
                          handler:^(UIContextualAction *action, UIView *view,
                                    void (^completion)(BOOL)) {
        [weakSelf confirmRemovalOfTorrent:info completion:completion];
    }];

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

/// Deleting downloaded media is destructive and easy to do by accident on a
/// swipe, so the files are only removed when explicitly chosen.
- (void)confirmRemovalOfTorrent:(VLCTorrentInfo *)info
                     completion:(void (^)(BOOL))completion
{
    VLCTorrentService *service = VLCTorrentService.sharedService;
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:info.name
                         message:NSLocalizedString(@"Remove this torrent?", nil)
                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak VLCTorrentsViewController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Remove and keep files", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [service removeTorrentWithInfoHash:info.infoHash deletingFiles:NO];
        [weakSelf refresh];
        completion(YES);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Remove and delete files", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [service removeTorrentWithInfoHash:info.infoHash deletingFiles:YES];
        [weakSelf refresh];
        completion(YES);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        completion(NO);
    }]];

    sheet.popoverPresentationController.sourceView = self.tableView;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
