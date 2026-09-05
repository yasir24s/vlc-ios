/*****************************************************************************
 * VLCTorrentFilesViewController.m
 *****************************************************************************/

#import "VLCTorrentFilesViewController.h"

#import "VLCTorrentPlaybackCoordinator.h"
#import "VLCTorrentService.h"

#import "VLCTorrentHTTPServer.h"

@interface VLCTorrentFilesViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic) UITableView *tableView;
@property (nonatomic) NSArray<VLCTorrentFile *> *files;
@property (nonatomic) NSByteCountFormatter *byteFormatter;
@end

@implementation VLCTorrentFilesViewController

- (instancetype)initWithInfoHash:(NSString *)infoHash title:(nullable NSString *)title
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _infoHash = [infoHash copy];
        self.title = title;
        _byteFormatter = [[NSByteCountFormatter alloc] init];
        _byteFormatter.countStyle = NSByteCountFormatterCountStyleFile;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

#if TARGET_OS_TV
    // tvOS has no systemBackgroundColor; the platform supplies the backdrop.
    self.view.backgroundColor = UIColor.clearColor;
#else
    self.view.backgroundColor = UIColor.systemBackgroundColor;
#endif

#if TARGET_OS_TV
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
#else
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
#endif
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"FileCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    if (self.presentedAsChooser) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self
                                                          action:@selector(dismissChooser)];
    }

    [self reload];
}

- (void)dismissChooser
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload
{
    self.files = [VLCTorrentService.sharedService filesForTorrentWithInfoHash:self.infoHash];
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (BOOL)hasPlayAllRow
{
    return self.presentedAsChooser;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.files.count + (self.hasPlayAllRow ? 1 : 0);
}

/// Index into self.files, or NSNotFound for the "Play all" row.
- (NSUInteger)fileIndexForRow:(NSInteger)row
{
    if (self.hasPlayAllRow) {
        return row == 0 ? NSNotFound : (NSUInteger)(row - 1);
    }
    return (NSUInteger)row;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    // Whether everything is being fetched depends on how the torrent was
    // added -- Download wants the lot, Stream only what you open -- so say
    // what is actually happening rather than promising one of the two.
#if TARGET_OS_TV
    return NSLocalizedString(@"Nothing downloads until you pick it, and tvOS "
                             @"keeps nothing permanently \u2014 pick an episode "
                             @"to stream it.", nil);
#else
    return NSLocalizedString(@"Nothing downloads until you pick it. A streamed "
                             @"episode is deleted when you open another one; "
                             @"\u201ckeep\u201d saves it to your VLC library.", nil);
#endif
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FileCell"
                                                            forIndexPath:indexPath];

    NSUInteger const index = [self fileIndexForRow:indexPath.row];
    if (index == NSNotFound) {
        UIListContentConfiguration *playAll = [UIListContentConfiguration cellConfiguration];
        playAll.text = NSLocalizedString(@"Play all from the start", nil);
        playAll.image = [UIImage systemImageNamed:@"play.circle.fill"];
        playAll.textProperties.color = UIColor.systemBlueColor;
        cell.contentConfiguration = playAll;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    VLCTorrentFile *file = self.files[index];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = file.name;
    // Which files cost disk is the whole point now, so say it plainly.
    VLCTorrentService *service = VLCTorrentService.sharedService;
    NSString *size = [self.byteFormatter stringFromByteCount:file.size];
    if ([service isFileKept:file.index inTorrentWithInfoHash:self.infoHash]) {
        content.secondaryText = [NSString stringWithFormat:
            NSLocalizedString(@"%@ - kept", nil), size];
        content.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
    } else if ([service isFileStreaming:file.index inTorrentWithInfoHash:self.infoHash]) {
        content.secondaryText = [NSString stringWithFormat:
            NSLocalizedString(@"%@ - streaming, not kept", nil), size];
        content.image = [UIImage systemImageNamed:@"play.circle.fill"];
    } else {
        content.secondaryText = size;
    }
    if (file.isPlayable) {
        content.image = [UIImage systemImageNamed:@"play.rectangle"];
    } else {
        content.image = [UIImage systemImageNamed:@"doc"];
    }
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSUInteger const index = [self fileIndexForRow:indexPath.row];
    if (index == NSNotFound) {
        [self playAllFromStart];
        return;
    }
    [self presentChoicesForFile:self.files[index]
                       fromCell:[tableView cellForRowAtIndexPath:indexPath]];
}

- (void)playAllFromStart
{
    NSInteger const first = [VLCTorrentService.sharedService
        primaryPlayableFileIndexForTorrentWithInfoHash:self.infoHash];
    if (first == NSNotFound) {
        return;
    }
    [self streamFileIndex:first];
}

/// Stream and download are offered per file rather than as a mode for the whole
/// torrent, so one episode can be playing while another is being kept.
- (void)presentChoicesForFile:(VLCTorrentFile *)file fromCell:(nullable UITableViewCell *)cell
{
#if TARGET_OS_TV
    UIAlertControllerStyle const style = UIAlertControllerStyleAlert;
#else
    UIAlertControllerStyle const style = UIAlertControllerStyleActionSheet;
#endif
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:file.name
                         message:[self.byteFormatter stringFromByteCount:file.size]
                  preferredStyle:style];

    __weak VLCTorrentFilesViewController *weakSelf = self;
    if (file.isPlayable) {
        [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Stream now", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [weakSelf streamFileIndex:file.index];
        }]];
    }

#if !TARGET_OS_TV
    // Deliberately absent on tvOS: there is no persistent local storage to keep
    // anything in, so offering it would be a promise the platform cannot honour.
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Download and keep", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [VLCTorrentService.sharedService keepFileIndex:file.index
                                 inTorrentWithInfoHash:weakSelf.infoHash];
        [weakSelf reload];
        if (weakSelf.presentedAsChooser) {
            [weakSelf dismissChooser];
        }
    }]];
#endif

    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

#if !TARGET_OS_TV
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
#endif
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)streamFileIndex:(NSInteger)fileIndex
{
    NSString *infoHash = self.infoHash;
    VLCTorrentPlaybackCoordinator *coordinator = VLCTorrentPlaybackCoordinator.sharedCoordinator;

    // As a chooser this is presented modally, so get out of the way first or
    // the player has nowhere to appear.
    if (self.presentedAsChooser) {
        [self dismissViewControllerAnimated:YES completion:^{
            [coordinator streamFileIndex:fileIndex
                   ofTorrentWithInfoHash:infoHash
                    presentingController:nil];
        }];
        return;
    }
    [coordinator streamFileIndex:fileIndex
           ofTorrentWithInfoHash:infoHash
            presentingController:self];
}

@end
