#import <AVFoundation/AVFoundation.h>

// PleaseDontStopTheMusic  ***TEST BUILD 3 (diagnostic)***
//
// IMPORTANT: the audio-mixing logic below is reverted to be IDENTICAL to the
// shipped, known-good v2.1.0. test1/test2 added a "latch" experiment that broke
// the normal "Spotify playing -> open TikTok -> mixes" case, so it is gone.
// The ONLY thing this build adds over v2.1.0 is logging, and that logging is
// done asynchronously on a background queue so it cannot disturb the timing of
// an app's audio-session setup.
//
// Goal (unchanged): let a second app play audio WITHOUT pausing music that is
// already playing, while leaving the music app in control of the lock-screen
// "Now Playing" transport. Heuristic: if other audio is already playing when an
// app configures its session, force MixWithOthers on that app (the intruder);
// otherwise leave it alone (so the music app keeps its Now Playing controls).
//
// Logs are written to /var/mobile/Documents/PDSTM-<bundleid>.log (browsable in
// Filza). Reproduce a bug, then send that file.

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

// ---------------------------------------------------------------------------
// Hooks — logic identical to v2.1.0, with logging added.
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
        options |= AVAudioSessionCategoryOptionMixWithOthers;
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
        options |= AVAudioSessionCategoryOptionMixWithOthers;
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
        options |= AVAudioSessionCategoryOptionMixWithOthers;
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
    NSLog(@"[PleaseDontStopTheMusic] TEST BUILD 3 loaded in %@", PDSTMBundle());
}
