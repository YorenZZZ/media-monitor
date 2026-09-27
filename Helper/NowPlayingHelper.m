// System Now Playing bridge. macOS only answers MediaRemote queries from Apple-signed
// processes, so Media Monitor runs `/usr/bin/perl` and has it load this dylib; the
// constructor then streams JSON lines on stdout and takes commands on stdin:
//   toggle | next | previous | seek <seconds>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPidFn)(dispatch_queue_t, void (^)(int));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);
typedef void (*RegisterFn)(dispatch_queue_t);

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id awaitResult(void (^start)(void (^done)(id))) {
    __block id result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    start(^(id value) { result = value; dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
    return result;
}

__attribute__((constructor)) static void run(void) {
    if (!getenv("MEDIA_MONITOR_NOW_PLAYING")) return;
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetInfoFn getInfo = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    GetPidFn getPid = (GetPidFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    GetPlayingFn getPlaying = (GetPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    SendCommandFn sendCommand = (SendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    SetElapsedFn setElapsed = (SetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    if (!getInfo || !getPid || !getPlaying || !sendCommand) { emit(@{@"error": @"MediaRemote unavailable"}); exit(1); }
    // Without this, MediaRemote answers a long-lived client from a cache that stops following the player
    // (抖音 kept reporting a video from minutes earlier, "playing", its clock running past the duration).
    RegisterFn registerForNotifications = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (registerForNotifications) registerForNotifications(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));

    // Commands; EOF means Media Monitor quit, so exit with it.
    [NSThread detachNewThreadWithBlock:^{
        char line[256];
        while (fgets(line, sizeof line, stdin)) {
            if (!strncmp(line, "toggle", 6)) sendCommand(2, nil);
            else if (!strncmp(line, "next", 4)) sendCommand(4, nil);
            else if (!strncmp(line, "previous", 8)) sendCommand(5, nil);
            else if (!strncmp(line, "seek ", 5) && setElapsed) setElapsed(atof(line + 5));
        }
        exit(0);
    }];

    // Poll on a background thread and hand the main thread to dispatch: MediaRemote refreshes its client-side
    // Now Playing state on the main queue, so a main thread stuck in this loop kept serving the first answer forever
    // (抖音 stayed "paused" or "playing" minutes after it changed).
    [NSThread detachNewThreadWithBlock:^{
    dispatch_queue_t q = dispatch_queue_create("now-playing", DISPATCH_QUEUE_SERIAL);
    NSString *lastArtwork = nil;
    while (1) {
        @autoreleasepool {
            NSNumber *pid = awaitResult(^(void (^done)(id)) { getPid(q, ^(int p) { done(@(p)); }); });
            NSMutableDictionary *out = [@{@"pid": pid ?: @0} mutableCopy];
            if (pid.intValue > 0) {
                NSNumber *playing = awaitResult(^(void (^done)(id)) { getPlaying(q, ^(BOOL p) { done(@(p)); }); });
                NSDictionary *info = awaitResult(^(void (^done)(id)) { getInfo(q, ^(NSDictionary *d) { done(d); }); });
                // The three reads are separate; if the Now Playing app changed in between, the metadata
                // may belong to the other app. Drop this sample and read again next tick.
                NSNumber *pidAfter = awaitResult(^(void (^done)(id)) { getPid(q, ^(int p) { done(@(p)); }); });
                if (![pidAfter isEqual:pid]) { usleep(200000); continue; }
                double elapsed = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
                double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
                NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([stamp isKindOfClass:NSDate.class] && rate > 0) elapsed += -[stamp timeIntervalSinceNow] * rate;
                out[@"playing"] = playing ?: @NO;
                out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
                out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                out[@"elapsed"] = @(elapsed);
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:NSData.class] && art.length) {
                    NSString *artId = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash];
                    out[@"artworkId"] = artId;
                    // Send the (large) image only when it changes.
                    if (![artId isEqualToString:lastArtwork]) { out[@"artwork"] = [art base64EncodedStringWithOptions:0]; lastArtwork = artId; }
                }
            }
            emit(out);
        }
        usleep(1000000);
    }
    }];
    dispatch_main();
}
