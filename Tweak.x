#import <AVFoundation/AVFoundation.h>

// PleaseDontStopTheMusic  ***TEST BUILD 4***
//
// Base logic = known-good v2.1.0 (otherPlaying -> force MixWithOthers on the
// intruder; leave the primary music app alone so it keeps Now Playing). The
// "latch" experiment from test1/test2 is gone for good.
//
// test4 change, driven by the device logs:
//   TikTok calls `setCategory:Playback withOptions:110`. 110 includes
//   DefaultToSpeaker (0x8), which is ONLY valid for PlayAndRecord. With
//   Playback the call fails and applies nothing, so the session stayed at
//   opts=0 and only our setActive: re-assertion got mixing going. That extra
//   reconfiguration churn happens right in the middle of the PiP activation
//   handshake and is the most likely cause of the FROZEN PiP video (audio
//   keeps playing fine; only the video stalls -> classic symptom of AVKit's
//   PiP layer reacting to an audio-session interruption/route change).
//
//   Fix: when we force mixing, also strip the invalid DefaultToSpeaker bit for
//   non-PlayAndRecord categories. Now TikTok's OWN setCategory succeeds with
//   MixWithOthers, the session settles before activation, and our setActive:
//   re-assertion no longer needs to fire during PiP. If the PiP video still
//   freezes after this, the freeze is intrinsic to MixWithOthers+PiP (an AVKit
//   limitation an audio tweak can't fix) rather than our churn.
//
// Logs: /var/mobile/Documents/PDSTM-<bundleid>.log, else the app's own
// Documents container (Filza search "PDSTM"). Truncates per app launch.

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

        // Preferred shared, Filza-friendly location. Create the dir first
        // (createFileAtPath won't make intermediate directories).
        NSString *dir = @"/var/mobile/Documents";
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *shared = [dir stringByAppendingPathComponent:name];
        if ([fm createFileAtPath:shared contents:[NSData data] attributes:nil]) {
            gLogPath = shared;
        } else {
            // Sandbox denied it: fall back to the app's own Documents container
            // (Filza lists it by app name under Containers/Data/Application).
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

// Add MixWithOthers and drop options that are invalid for the given category
// (DefaultToSpeaker only applies to PlayAndRecord; leaving it on Playback makes
// the whole setCategory call fail). Logs when it actually strips something.
static AVAudioSessionCategoryOptions PDSTMMixOptions(NSString *category, AVAudioSessionCategoryOptions options) {
    options |= AVAudioSessionCategoryOptionMixWithOthers;
    if (![category isEqualToString:AVAudioSessionCategoryPlayAndRecord]
        && (options & AVAudioSessionCategoryOptionDefaultToSpeaker)) {
        options &= ~AVAudioSessionCategoryOptionDefaultToSpeaker;
    }
    return options;
}

// ---------------------------------------------------------------------------
// Hooks — base logic from v2.1.0, plus the DefaultToSpeaker fix and logging.
// ---------------------------------------------------------------------------
%hook AVAudioSession

- (BOOL)setCategory:(NSString *)category error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@  (otherPlaying=%d)", category, self.isOtherAudioPlaying);
    if (self.isOtherAudioPlaying) {
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
    PDSTMLog(@"setCategory:%@ mode:%@ options:%lu  (otherPlaying=%d)",
             category, mode, (unsigned long)options, self.isOtherAudioPlaying);
    if (self.isOtherAudioPlaying) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, mode, options, outError);
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ mode:%@ policy:%ld options:%lu  (otherPlaying=%d)",
             category, mode, (long)policy, (unsigned long)options, self.isOtherAudioPlaying);
    if (self.isOtherAudioPlaying) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, mode, policy, options, outError);
}

- (BOOL)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ withOptions:%lu  (otherPlaying=%d)",
             category, (unsigned long)options, self.isOtherAudioPlaying);
    if (self.isOtherAudioPlaying) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options = PDSTMMixOptions(category, options);
    }
    return %orig(category, options, outError);
}

- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    PDSTMLog(@"setActive:%d  (cat=%@ opts=%lu otherPlaying=%d)",
             active, self.category, (unsigned long)self.categoryOptions, self.isOtherAudioPlaying);
    if (active && self.isOtherAudioPlaying
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
    PDSTMLog(@"setActive:%d withOptions:%lu  (cat=%@ opts=%lu otherPlaying=%d)",
             active, (unsigned long)options, self.category, (unsigned long)self.categoryOptions, self.isOtherAudioPlaying);
    if (active && self.isOtherAudioPlaying
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
    NSLog(@"[PleaseDontStopTheMusic] TEST BUILD 4 loaded in %@", PDSTMBundle());
}
