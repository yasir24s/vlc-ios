/*****************************************************************************
 * VLCTorrentHTTPServer.m
 *****************************************************************************/

#import "VLCTorrentHTTPServer.h"

#import "VLCTorrentService.h"

#import <CocoaHTTPServer/HTTPConnection.h>
#import <CocoaHTTPServer/HTTPResponse.h>
#import <CocoaHTTPServer/HTTPServer.h>

#include <fcntl.h>
#include <unistd.h>

/// How far ahead of the read cursor to put piece deadlines. Big enough to keep
/// the decoder fed, small enough that a seek doesn't leave a long tail of
/// now-useless requests in flight.
static int64_t const kReadAheadBytes = 16 * 1024 * 1024;

/// Poll interval while waiting for the piece under the read cursor.
static NSTimeInterval const kPieceWaitInterval = 0.15;

/// Guards against another app on the device probing the loopback port.
static NSString *gAccessToken = nil;

#pragma mark - Response

/// Serves one file out of one torrent, asynchronously: returns nil from
/// -readDataOfLength: whenever the bytes under the cursor have not arrived,
/// then pokes the connection once they have.
@interface VLCTorrentStreamResponse : NSObject <HTTPResponse>
- (instancetype)initWithConnection:(HTTPConnection *)connection
                          infoHash:(NSString *)infoHash
                         fileIndex:(NSInteger)fileIndex
                     contentLength:(int64_t)contentLength
                              path:(NSString *)path;
@end

@implementation VLCTorrentStreamResponse {
    __weak HTTPConnection *_connection;
    NSString *_infoHash;
    NSInteger _fileIndex;
    int64_t _contentLength;
    NSString *_path;
    int64_t _offset;
    int _fileDescriptor;
    dispatch_source_t _waitTimer;
    dispatch_queue_t _waitQueue;
}

- (instancetype)initWithConnection:(HTTPConnection *)connection
                          infoHash:(NSString *)infoHash
                         fileIndex:(NSInteger)fileIndex
                     contentLength:(int64_t)contentLength
                              path:(NSString *)path
{
    self = [super init];
    if (self) {
        _connection = connection;
        _infoHash = [infoHash copy];
        _fileIndex = fileIndex;
        _contentLength = contentLength;
        _path = [path copy];
        _offset = 0;
        _fileDescriptor = -1;
        _waitQueue = dispatch_queue_create("org.videolan.vlc.torrent.stream",
                                           DISPATCH_QUEUE_SERIAL);
        [self requestReadAhead];
    }
    return self;
}

- (void)dealloc
{
    [self stopWaiting];
    if (_fileDescriptor >= 0) {
        close(_fileDescriptor);
    }
}

#pragma mark HTTPResponse

- (UInt64)contentLength
{
    return (UInt64)_contentLength;
}

- (UInt64)offset
{
    return (UInt64)_offset;
}

/// Called by HTTPConnection for a Range request, i.e. this is the seek path.
- (void)setOffset:(UInt64)offset
{
    _offset = (int64_t)offset;
    [self stopWaiting];
    [self requestReadAhead];
}

- (BOOL)isDone
{
    return _offset >= _contentLength;
}

- (NSInteger)status
{
    return 200;
}

- (BOOL)isChunked
{
    return NO;
}

- (NSDictionary *)httpHeaders
{
    return @{ @"Content-Type": [self contentType],
              @"Accept-Ranges": @"bytes" };
}

- (NSData *)readDataOfLength:(NSUInteger)length
{
    int64_t const remaining = _contentLength - _offset;
    if (remaining <= 0) {
        return nil;
    }
    int64_t const wanted = MIN((int64_t)length, remaining);

    VLCTorrentService *service = VLCTorrentService.sharedService;
    int64_t const available = [service availableBytesForFileIndex:_fileIndex
                                            inTorrentWithInfoHash:_infoHash
                                                       fileOffset:_offset
                                                        maxLength:wanted];
    if (available <= 0) {
        [self requestReadAhead];
        [self startWaiting];
        return nil;
    }

    if (![self openFileIfNeeded]) {
        // libtorrent has not created the file on disk yet.
        [self startWaiting];
        return nil;
    }

    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)available];
    ssize_t const read = pread(_fileDescriptor, buffer.mutableBytes,
                               (size_t)available, (off_t)_offset);
    if (read <= 0) {
        // Sparse region: the piece is accounted for but not yet flushed.
        [self startWaiting];
        return nil;
    }

    buffer.length = (NSUInteger)read;
    _offset += read;
    [self requestReadAhead];
    return buffer;
}

- (void)connectionDidClose
{
    [self stopWaiting];
    _connection = nil;
    if (_fileDescriptor >= 0) {
        close(_fileDescriptor);
        _fileDescriptor = -1;
    }
}

#pragma mark Internals

- (NSString *)contentType
{
    static NSDictionary<NSString *, NSString *> *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        types = @{
            @"mp4": @"video/mp4",    @"m4v": @"video/mp4",
            @"mkv": @"video/x-matroska",
            @"avi": @"video/x-msvideo",
            @"mov": @"video/quicktime",
            @"webm": @"video/webm",
            @"ts": @"video/mp2t",    @"m2ts": @"video/mp2t",
            @"mpg": @"video/mpeg",   @"mpeg": @"video/mpeg",
            @"flv": @"video/x-flv",
            @"wmv": @"video/x-ms-wmv",
            @"ogv": @"video/ogg",
            @"3gp": @"video/3gpp",
            @"mp3": @"audio/mpeg",
            @"m4a": @"audio/mp4",
            @"flac": @"audio/flac",
            @"aac": @"audio/aac",
            @"ogg": @"audio/ogg",    @"opus": @"audio/opus",
            @"wav": @"audio/wav",
        };
    });
    NSString *type = types[_path.pathExtension.lowercaseString];
    return type ?: @"application/octet-stream";
}

- (BOOL)openFileIfNeeded
{
    if (_fileDescriptor >= 0) {
        return YES;
    }
    _fileDescriptor = open(_path.fileSystemRepresentation, O_RDONLY);
    return _fileDescriptor >= 0;
}

- (void)requestReadAhead
{
    [VLCTorrentService.sharedService requestFileIndex:_fileIndex
                                inTorrentWithInfoHash:_infoHash
                                           fileOffset:_offset
                                               length:kReadAheadBytes];
}

/// Poll until the cursor's piece lands, then wake the connection back up.
- (void)startWaiting
{
    if (_waitTimer) {
        return;
    }

    _waitTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _waitQueue);
    uint64_t const interval = (uint64_t)(kPieceWaitInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(_waitTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, interval / 4);

    __weak VLCTorrentStreamResponse *weakSelf = self;
    dispatch_source_set_event_handler(_waitTimer, ^{
        VLCTorrentStreamResponse *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf checkForAvailableData];
    });
    dispatch_resume(_waitTimer);
}

- (void)checkForAvailableData
{
    HTTPConnection *connection = _connection;
    if (!connection) {
        [self stopWaiting];
        return;
    }

    int64_t const remaining = _contentLength - _offset;
    if (remaining <= 0) {
        [self stopWaiting];
        return;
    }

    int64_t const available =
        [VLCTorrentService.sharedService availableBytesForFileIndex:_fileIndex
                                             inTorrentWithInfoHash:_infoHash
                                                        fileOffset:_offset
                                                         maxLength:remaining];
    if (available <= 0) {
        return;
    }

    [self stopWaiting];
    // Safe from any thread: HTTPConnection re-dispatches onto its own queue.
    [connection responseHasAvailableData:self];
}

- (void)stopWaiting
{
    if (_waitTimer) {
        dispatch_source_cancel(_waitTimer);
        _waitTimer = nil;
    }
}

@end

#pragma mark - Connection

@interface VLCTorrentHTTPConnection : HTTPConnection
@end

@implementation VLCTorrentHTTPConnection

- (BOOL)supportsMethod:(NSString *)method atPath:(NSString *)path
{
    if ([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"]) {
        return YES;
    }
    return [super supportsMethod:method atPath:path];
}

/// Path is /<token>/<infohash>/<fileIndex>/<filename>. The filename is there
/// purely so libvlc sees a familiar extension.
- (NSObject<HTTPResponse> *)httpResponseForMethod:(NSString *)method URI:(NSString *)path
{
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    // ["", token, hash, index, name...]
    if (components.count < 4) {
        return nil;
    }
    if (!gAccessToken || ![components[1] isEqualToString:gAccessToken]) {
        return nil;
    }

    NSString *infoHash = components[2];
    NSInteger fileIndex = components[3].integerValue;

    VLCTorrentService *service = VLCTorrentService.sharedService;
    NSString *filePath = [service pathForFileIndex:fileIndex
                             inTorrentWithInfoHash:infoHash];
    int64_t contentLength = [service sizeOfFileIndex:fileIndex
                               inTorrentWithInfoHash:infoHash];
    if (!filePath || contentLength <= 0) {
        return nil;
    }

    return [[VLCTorrentStreamResponse alloc] initWithConnection:self
                                                       infoHash:infoHash
                                                      fileIndex:fileIndex
                                                  contentLength:contentLength
                                                           path:filePath];
}

@end

#pragma mark - Server

@implementation VLCTorrentHTTPServer {
    HTTPServer *_server;
}

+ (VLCTorrentHTTPServer *)sharedServer
{
    static VLCTorrentHTTPServer *sharedServer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedServer = [[VLCTorrentHTTPServer alloc] init];
    });
    return sharedServer;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _server = [[HTTPServer alloc] init];
        // Loopback only: nothing outside this device can reach it.
        [_server setInterface:@"loopback"];
        [_server setPort:0];
        [_server setConnectionClass:[VLCTorrentHTTPConnection class]];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (BOOL)isRunning
{
    return _server.isRunning;
}

- (uint16_t)port
{
    return _server.listeningPort;
}

- (BOOL)startWithError:(NSError **)error
{
    if (_server.isRunning) {
        return YES;
    }
    if (!gAccessToken) {
        gAccessToken = [NSUUID UUID].UUIDString.lowercaseString;
    }
    BOOL started = [_server start:error];
    if (started) {
        NSLog(@"VLCTorrentHTTPServer: listening on 127.0.0.1:%hu", _server.listeningPort);
    }
    return started;
}

- (void)stop
{
    [_server stop];
}

- (nullable NSURL *)streamURLForTorrentWithInfoHash:(NSString *)infoHash
                                          fileIndex:(NSInteger)fileIndex
{
    if (!_server.isRunning) {
        return nil;
    }

    VLCTorrentService *service = VLCTorrentService.sharedService;
    NSString *filePath = [service pathForFileIndex:fileIndex
                             inTorrentWithInfoHash:infoHash];
    if (!filePath) {
        return nil;
    }

    NSCharacterSet *allowed = [NSCharacterSet URLPathAllowedCharacterSet];
    NSString *name = [filePath.lastPathComponent
        stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"stream";

    NSString *string = [NSString stringWithFormat:@"http://127.0.0.1:%hu/%@/%@/%ld/%@",
                                                  _server.listeningPort, gAccessToken,
                                                  infoHash, (long)fileIndex, name];
    return [NSURL URLWithString:string];
}

- (nullable NSURL *)streamURLForTorrentWithInfoHash:(NSString *)infoHash
{
    NSInteger index = [VLCTorrentService.sharedService
        primaryPlayableFileIndexForTorrentWithInfoHash:infoHash];
    if (index == NSNotFound) {
        return nil;
    }
    return [self streamURLForTorrentWithInfoHash:infoHash fileIndex:index];
}

@end
