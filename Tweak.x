#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// PleaseDontStopTheMusic  ***TEST BUILD 5***
//
// Base logic = known-good v2.1.0 (otherPlaying -> force MixWithOthers on the
// intruder so it joins the music instead of pausing it; leave the primary
// music app alone so it keeps Now Playing).
//
// THE PiP FIX (test5):
//   The device logs proved the "frozen PiP video" is NOT caused by our
//   reconfiguration churn (that happens at app launch, minutes before the
//   freeze). At the moment PiP freezes, the session is simply
//   `Playback + MixWithOthers + active`. Full-screen video runs fine in that
//   exact state, but PiP does not: AVKit's PiP pipeline needs to OWN the audio
//   route, and a MixWithOthers session is ineligible, so the video stalls while
//   audio keeps playing.
//
//   You cannot have a PiP video AND a mixed (secondary) audio session at the
//   same time -- that's an AVKit limitation, not something an audio tweak can
//   override. So: while PiP is active we STOP forcing mix and let the app own
//   the audio (the stock behaviour PiP is designed for). Result: the PiP video
//   plays normally; the background music pauses for the duration of PiP and
//   resumes when PiP ends. Outside of PiP, everything mixes exactly as before.
//
//   We detect PiP by hooking AVPictureInPictureController start/stop. On start
//   we also proactively drop MixWithOthers from the current session so PiP can
//   grab the route cleanly.
//
// Also completes the options fix: TikTok's `setCategory:Playback withOptions:110`
// failed because 110 carries PlayAndRecord-only bits (AllowBluetooth 0x4,
// DefaultToSpeaker 0x8). We now reduce options to the subset valid for a
// non-record category so the call actually succeeds.
//
// Logs: /var/mobile/Documents/PDSTM-<bundleid>.log, else the app's own
// Documents container (Filza search "PDSTM"). Truncates per app launch.

// Set while Picture-in-Picture is active; suppresses forced mixing so PiP can
// own the audio route (otherwise the PiP video freezes).
static BOOL gInPiP = NO;

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

// Should this app mix right now? Yes if other audio is playing AND we are not
// in PiP (PiP must own the route).
static BOOL PDSTMShouldMix(AVAudioSession *session) {
    return session.isOtherAudioPlaying && !gInPiP;
}

// Add MixWithOthers and drop options that are invalid for a non-record category
// (AllowBluetooth/DefaultToSpeaker/etc. only apply to PlayAndRecord and make the
// whole setCategory call fail for Playback). For PlayAndRecord we keep the
// caller's options untouched aside from adding mix.
static AVAudioSessionCategoryOptions PDSTMMixOptions(NSString *category, AVAudioSessionCategoryOptions options) {
    if ([category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        return options | AVAudioSessionCategoryOptionMixWithOthers;
    }
    // Keep only the bits valid for Playback/Ambient/etc, then force mixing.
    AVAudioSessionCategoryOptions keep = options & AVAudioSessionCategoryOptionDuckOthers;
    return keep | AVAudioSessionCategoryOptionMixWithOthers;
}

// ---------------------------------------------------------------------------
// PiP detection
// ---------------------------------------------------------------------------
@interface AVPictureInPictureController : NSObject
@property (nonatomic, readonly, getter=isPictureInPictureActive) BOOL pictureInPictureActive;
- (void)startPictureInPicture;
- (void)stopPictureInPicture;
@end

%group PiPHooks
%hook AVPictureInPictureController

- (void)startPictureInPicture {
    gInPiP = YES;
    // Proactively hand the audio route back so PiP can render. Removing mix
    // from the active session lets PiP own playback (background music pauses).
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (s.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers) {
        [s setCategory:s.category
                  mode:s.mode
               options:(s.categoryOptions & ~AVAudioSessionCategoryOptionMixWithOthers)
                 error:nil];
    }
    PDSTMLog(@"PiP START -> gInPiP=YES, dropped MixWithOthers so video can play");
    %orig;
}

- (void)stopPictureInPicture {
    gInPiP = NO;
    PDSTMLog(@"PiP STOP -> gInPiP=NO, mixing re-enabled");
    %orig;
}

%end
%end

// AVKit (and AVPictureInPictureController) is often loaded lazily, after our
// %ctor. Install the PiP hooks as soon as the class exists; safe to call from
// anywhere thanks to dispatch_once.
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
    PDSTMLog(@"setCategory:%@  (otherPlaying=%d inPiP=%d)", category, self.isOtherAudioPlaying, gInPiP);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            return %orig(AVAudioSessionCategoryAmbient, outError);
        }
        if ([category isEqualToString:AVAudioSessionCategoryPlayback]) {
            return [self setCategory:category
                                mode:AVAudioSessionModeDefault
                             options:AVAudioSessionCategoryOptionMixWithOthers
                               error:outError];
        }
    }
    return %orig;
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ mode:%@ options:%lu  (otherPlaying=%d inPiP=%d)",
             category, mode, (unsigned long)options, self.isOtherAudioPlaying, gInPiP);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, mode, options, outError);
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ mode:%@ policy:%ld options:%lu  (otherPlaying=%d inPiP=%d)",
             category, mode, (long)policy, (unsigned long)options, self.isOtherAudioPlaying, gInPiP);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, mode, policy, options, outError);
}

- (BOOL)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ withOptions:%lu  (otherPlaying=%d inPiP=%d)",
             category, (unsigned long)options, self.isOtherAudioPlaying, gInPiP);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, options, outError);
}

- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    PDSTMEnsurePiPHooks();
    PDSTMLog(@"setActive:%d  (cat=%@ opts=%lu otherPlaying=%d inPiP=%d)",
             active, self.category, (unsigned long)self.categoryOptions, self.isOtherAudioPlaying, gInPiP);
    if (active && PDSTMShouldMix(self)
        && !(self.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) {
        NSString *cat = self.category;
        if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            cat = AVAudioSessionCategoryAmbient;
        }
        [self setCategory:cat
                     mode:self.mode
                  options:self.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers
                    error:nil];
    }
    return %orig;
}

- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    PDSTMLog(@"setActive:%d withOptions:%lu  (cat=%@ opts=%lu otherPlaying=%d inPiP=%d)",
             active, (unsigned long)options, self.category, (unsigned long)self.categoryOptions, self.isOtherAudioPlaying, gInPiP);
    if (active && PDSTMShouldMix(self)
        && !(self.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) {
        NSString *cat = self.category;
        if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            cat = AVAudioSessionCategoryAmbient;
        }
        [self setCategory:cat
                     mode:self.mode
                  options:self.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers
                    error:nil];
    }
    return %orig;
}

%end

%ctor {
    PDSTMLogSetup();
    PDSTMEnsurePiPHooks();
    NSLog(@"[PleaseDontStopTheMusic] TEST BUILD 5 loaded in %@", PDSTMBundle());
}
