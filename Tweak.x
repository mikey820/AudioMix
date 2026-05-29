#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// PleaseDontStopTheMusic  ***TEST BUILD 6 (experimental: PiP + bg audio)***
//
// The freeze only happens when we force the PiP app (TikTok) to MixWithOthers.
// With TikTok as the PRIMARY audio owner, PiP renders perfectly (that's stock
// behaviour). The only reason the music stops in that case is that mediaserverd
// hands the exclusive route to TikTok and interrupts everyone else.
//
// This build attempts the one app-level escape the jailbreak makes possible:
// the tweak is injected into the MUSIC app too. So when the PiP app enters PiP
// we let it be primary (PiP works) and, over a Darwin notification, tell the
// music app's copy of this tweak to keep itself alive as a secondary mixer.
// If iOS lets a MixWithOthers app keep playing while another app owns the
// route, you get PiP video AND background music at once.
//
// IF the music still pauses, that proves the route arbitration in mediaserverd
// silences mixers too, and the only remaining path would be a system-daemon
// patch (separate, risky tweak) -- not something an in-app tweak can do.
//
// Everything else = known-good v2.1.0 mixing. Logs:
// /var/mobile/Documents/PDSTM-<bundleid>.log (Filza search "PDSTM").

#define PDSTM_PIP_START CFSTR("com.mikey820.pdstm.pipstart")
#define PDSTM_PIP_STOP  CFSTR("com.mikey820.pdstm.pipstop")

static BOOL gInPiP        = NO;  // this process is showing PiP -> stay primary
static BOOL gIsPiPHost    = NO;  // this process ever hosted PiP (ignore our own broadcast)
static BOOL gKeepAlive    = NO;  // a PiP host elsewhere asked us to keep playing as a mixer
static BOOL gMyActive     = NO;  // our session is currently active

// ---------------------------------------------------------------------------
// Logging (async, never blocks the caller)
// ---------------------------------------------------------------------------
static NSString *PDSTMBundle(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
}

static dispatch_queue_t gLogQ;
static NSString *gLogPath;

static void PDSTMLogSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQ = dispatch_queue_create("com.mikey820.pdstm.log", DISPATCH_QUEUE_SERIAL);
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *name = [NSString stringWithFormat:@"PDSTM-%@.log", PDSTMBundle()];
        NSString *dir = @"/var/mobile/Documents";
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *shared = [dir stringByAppendingPathComponent:name];
        if ([fm createFileAtPath:shared contents:[NSData data] attributes:nil]) {
            gLogPath = shared;
        } else {
            NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            gLogPath = [docs stringByAppendingPathComponent:name];
            [fm createFileAtPath:gLogPath contents:[NSData data] attributes:nil];
        }
        NSLog(@"[PDSTM][%@] log file: %@", PDSTMBundle(), gLogPath);
    });
}

static void PDSTMLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[PDSTM][%@] %@", PDSTMBundle(), msg);
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], msg];
    dispatch_async(gLogQ, ^{
        if (!gLogPath) return;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (fh) {
            @try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch (__unused id e) {}
            [fh closeFile];
        } else {
            [data writeToFile:gLogPath atomically:NO];
        }
    });
}

// Force mixing while a PiP host wants us alive (gKeepAlive), or when other audio
// is playing and we're not the one showing PiP.
static BOOL PDSTMShouldMix(AVAudioSession *session) {
    if (gInPiP) return NO;                 // we're the PiP host: own the route
    if (gKeepAlive) return YES;            // a PiP host elsewhere wants us mixing
    return session.isOtherAudioPlaying;
}

static AVAudioSessionCategoryOptions PDSTMMixOptions(NSString *category, AVAudioSessionCategoryOptions options) {
    if ([category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        return options | AVAudioSessionCategoryOptionMixWithOthers;
    }
    AVAudioSessionCategoryOptions keep = options & AVAudioSessionCategoryOptionDuckOthers;
    return keep | AVAudioSessionCategoryOptionMixWithOthers;
}

// ---------------------------------------------------------------------------
// Cross-app coordination (Darwin notifications)
// ---------------------------------------------------------------------------
static void PDSTMForceSelfMix(BOOL on) {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSString *cat = s.category;
    if (![cat isEqualToString:AVAudioSessionCategoryPlayback]
        && ![cat isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        return; // not an audio-producing session; nothing to keep alive
    }
    AVAudioSessionCategoryOptions opts = s.categoryOptions;
    if (on) opts |= AVAudioSessionCategoryOptionMixWithOthers;
    else    opts &= ~AVAudioSessionCategoryOptionMixWithOthers;
    [s setCategory:cat mode:s.mode options:opts error:nil];
    if (gMyActive) [s setActive:YES error:nil];
    PDSTMLog(@"keep-alive %@: re-applied %@ opts=%lu (active=%d)",
             on ? @"ON" : @"OFF", cat, (unsigned long)opts, gMyActive);
}

static void PDSTMOnPiPStart(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef d) {
    if (gIsPiPHost) return;       // don't react to our own broadcast
    gKeepAlive = YES;
    PDSTMLog(@"<- PiP started in another app: forcing self to mix to survive");
    PDSTMForceSelfMix(YES);
}

static void PDSTMOnPiPStop(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef d) {
    if (gIsPiPHost) return;
    gKeepAlive = NO;
    PDSTMLog(@"<- PiP stopped elsewhere: restoring normal (primary) session");
    PDSTMForceSelfMix(NO);
}

// ---------------------------------------------------------------------------
// PiP detection (installed lazily; AVKit loads on demand)
// ---------------------------------------------------------------------------
@interface AVPictureInPictureController : NSObject
- (void)startPictureInPicture;
- (void)stopPictureInPicture;
@end

%group PiPHooks
%hook AVPictureInPictureController

- (void)startPictureInPicture {
    gInPiP = YES;
    gIsPiPHost = YES;
    // Tell the music app to keep playing as a mixer BEFORE we grab the route.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         PDSTM_PIP_START, NULL, NULL, YES);
    // Give up MixWithOthers ourselves so PiP can own the route and render.
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (s.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers) {
        [s setCategory:s.category mode:s.mode
               options:(s.categoryOptions & ~AVAudioSessionCategoryOptionMixWithOthers) error:nil];
    }
    PDSTMLog(@"PiP START (host) -> primary route, broadcast pipstart");
    %orig;
}

- (void)stopPictureInPicture {
    gInPiP = NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         PDSTM_PIP_STOP, NULL, NULL, YES);
    PDSTMLog(@"PiP STOP (host) -> broadcast pipstop");
    %orig;
}

%end
%end

static void PDSTMEnsurePiPHooks(void) {
    static dispatch_once_t once;
    if (objc_getClass("AVPictureInPictureController")) {
        dispatch_once(&once, ^{
            %init(PiPHooks);
            PDSTMLog(@"AVPictureInPictureController hooks installed");
        });
    }
}

// ---------------------------------------------------------------------------
// AVAudioSession — base logic from v2.1.0, gated by PDSTMShouldMix.
// ---------------------------------------------------------------------------
%hook AVAudioSession

- (BOOL)setCategory:(NSString *)category error:(NSError **)outError {
    PDSTMEnsurePiPHooks();
    PDSTMLog(@"setCategory:%@  (other=%d inPiP=%d keepAlive=%d)", category, self.isOtherAudioPlaying, gInPiP, gKeepAlive);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            return %orig(AVAudioSessionCategoryAmbient, outError);
        }
        if ([category isEqualToString:AVAudioSessionCategoryPlayback]) {
            return [self setCategory:category mode:AVAudioSessionModeDefault
                             options:AVAudioSessionCategoryOptionMixWithOthers error:outError];
        }
    }
    return %orig;
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ mode:%@ options:%lu  (other=%d inPiP=%d keepAlive=%d)",
             category, mode, (unsigned long)options, self.isOtherAudioPlaying, gInPiP, gKeepAlive);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) category = AVAudioSessionCategoryAmbient;
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, mode, options, outError);
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ mode:%@ policy:%ld options:%lu  (other=%d inPiP=%d keepAlive=%d)",
             category, mode, (long)policy, (unsigned long)options, self.isOtherAudioPlaying, gInPiP, gKeepAlive);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) category = AVAudioSessionCategoryAmbient;
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, mode, policy, options, outError);
}

- (BOOL)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ withOptions:%lu  (other=%d inPiP=%d keepAlive=%d)",
             category, (unsigned long)options, self.isOtherAudioPlaying, gInPiP, gKeepAlive);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) category = AVAudioSessionCategoryAmbient;
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, options, outError);
}

- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    PDSTMEnsurePiPHooks();
    gMyActive = active;
    PDSTMLog(@"setActive:%d  (cat=%@ opts=%lu other=%d inPiP=%d keepAlive=%d)",
             active, self.category, (unsigned long)self.categoryOptions, self.isOtherAudioPlaying, gInPiP, gKeepAlive);
    if (active && PDSTMShouldMix(self)
        && !(self.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) {
        NSString *cat = self.category;
        if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient]) cat = AVAudioSessionCategoryAmbient;
        [self setCategory:cat mode:self.mode
                  options:self.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers error:nil];
    }
    return %orig;
}

- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    gMyActive = active;
    PDSTMLog(@"setActive:%d withOptions:%lu  (cat=%@ opts=%lu other=%d inPiP=%d keepAlive=%d)",
             active, (unsigned long)options, self.category, (unsigned long)self.categoryOptions, self.isOtherAudioPlaying, gInPiP, gKeepAlive);
    if (active && PDSTMShouldMix(self)
        && !(self.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) {
        NSString *cat = self.category;
        if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient]) cat = AVAudioSessionCategoryAmbient;
        [self setCategory:cat mode:self.mode
                  options:self.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers error:nil];
    }
    return %orig;
}

%end

%ctor {
    %init; // ungrouped AVAudioSession hooks
    PDSTMLogSetup();
    PDSTMEnsurePiPHooks();
    CFNotificationCenterRef dn = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(dn, NULL, PDSTMOnPiPStart, PDSTM_PIP_START, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(dn, NULL, PDSTMOnPiPStop,  PDSTM_PIP_STOP,  NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    NSLog(@"[PleaseDontStopTheMusic] TEST BUILD 6 loaded in %@", PDSTMBundle());
}
