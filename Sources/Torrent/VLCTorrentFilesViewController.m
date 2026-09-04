/*****************************************************************************
 * VLCTorrentFilesViewController.m
 *****************************************************************************/

#import "VLCTorrentFilesViewController.h"

#import "VLCTorrentPlaybackCoordinator.h"
#import "VLCTorrentService.h"

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

    [self reload];
}

- (void)reload
{
    self.files = [VLCTorrentService.sharedService filesForTorrentWithInfoHash:self.infoHash];
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.files.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return NSLocalizedString(@"Tap a media file to stream it. Swipe to include or "
                             @"exclude a file from the download.", nil);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FileCell"
                                                            forIndexPath:indexPath];
    VLCTorrentFile *file = self.files[indexPath.row];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = file.name;
    content.secondaryText = [self.byteFormatter stringFromByteCount:file.size];
    if (file.isPlayable) {
        content.image = [UIImage systemImageNamed:@"play.rectangle"];
    } else {
        content.image = [UIImage systemImageNamed:@"doc"];
    }
    // Excluded files stay visible but obviously inert.
    content.textProperties.color = file.isWanted ? UIColor.labelColor
                                                 : UIColor.tertiaryLabelColor;
    cell.contentConfiguration = content;

    cell.accessoryType = file.isWanted ? UITableViewCellAccessoryCheckmark
                                       : UITableViewCellAccessoryNone;
    cell.selectionStyle = file.isPlayable ? UITableViewCellSelectionStyleDefault
                                          : UITableViewCellSelectionStyleNone;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    VLCTorrentFile *file = self.files[indexPath.row];
    if (!file.isPlayable) {
        return;
    }
    [[VLCTorrentPlaybackCoordinator sharedCoordinator] streamFileIndex:file.index
                                                 ofTorrentWithInfoHash:self.infoHash
                                                  presentingController:self];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    VLCTorrentFile *file = self.files[indexPath.row];
    __weak VLCTorrentFilesViewController *weakSelf = self;

    UIContextualAction *toggle = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:file.isWanted ? NSLocalizedString(@"Exclude", nil)
                                                : NSLocalizedString(@"Include", nil)
                          handler:^(UIContextualAction *action, UIView *view,
                                    void (^completion)(BOOL)) {
        [weakSelf setFile:file wanted:!file.isWanted];
        completion(YES);
    }];
    toggle.backgroundColor = file.isWanted ? UIColor.systemGrayColor : UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[toggle]];
}

/// libtorrent takes the whole priority vector, so rebuild it from the current
/// checkmarks with this one file flipped.
- (void)setFile:(VLCTorrentFile *)file wanted:(BOOL)wanted
{
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
    for (VLCTorrentFile *candidate in self.files) {
        BOOL const isWanted = candidate.index == file.index ? wanted : candidate.isWanted;
        if (isWanted) {
            [indexes addObject:@(candidate.index)];
        }
    }

    if (indexes.count == 0) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:NSLocalizedString(@"Torrent", nil)
                             message:NSLocalizedString(@"At least one file must be included.", nil)
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [VLCTorrentService.sharedService setWantedFileIndexes:indexes
                                   forTorrentWithInfoHash:self.infoHash];
    [self reload];
}

@end
