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

    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
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
    return NSLocalizedString(@"Tap any file to stream it now or download it to keep. "
                             @"Files marked \u201cfetching\u201d are being downloaded.", nil);
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
    // "Only the files you pick are fetched" is only reassuring if you can see
    // which ones those are.
    NSString *size = [self.byteFormatter stringFromByteCount:file.size];
    content.secondaryText = file.isWanted
        ? [NSString stringWithFormat:NSLocalizedString(@"%@ - fetching", nil), size]
        : size;
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
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:file.name
                         message:[self.byteFormatter stringFromByteCount:file.size]
                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak VLCTorrentFilesViewController *weakSelf = self;
    if (file.isPlayable) {
        [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Stream now", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [weakSelf streamFileIndex:file.index];
        }]];
    }

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

    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
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
