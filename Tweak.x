#import <AVFoundation/AVFoundation.h>

// PleaseDontStopTheMusic  ***TEST BUILD 2***
//
// Goal: let a second app (TikTok, Twitter, YouTube, a game, ...) play audio
// WITHOUT pausing the music that is already playing, while leaving that music
// app in full control of the lock screen / Control Center "Now Playing"
// transport controls.
//
// An audio session that opts into MixWithOthers is treated by iOS as a
// *secondary* source: it won't interrupt others, and it gives up the Now
// Playing controls. So we only force mixing on the "intruder" app, never on the
// primary music app (or its lock-screen controls vanish).
//
// -------- test2 changelog --------
//   * RESTORED the setActive: re-assertion that test1 wrongly removed. That
//     hook is what makes normal "Spotify -> TikTok" mixing work: TikTok sets
//     its category before its audio is up, and we re-apply MixWithOthers when
//     it actually activates (when other audio is reliably detected). Removing
//     it in test1 broke that case.
//   * Kept the LATCH: once this process has been seen as a secondary source we
//     remember it, so a transient -isOtherAudioPlaying flicker during a PiP
//     teardown can't make the app re-grab exclusive playback and kill the music.
//   * NEW: writes a log file to a Filza-accessible path (see PDSTMLog) so the
//     PiP-freeze behaviour can be diagnosed on-device without a computer.

// AVAudioSession is effectively a per-process singleton, so a static flag is
// the right scope. Once YES it stays YES for this app's life.
static BOOL gLatchedSecondary = NO;

static NSString *PDSTMBundle(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
}

// ---- File logging (Filza-accessible) ---------------------------------------
// We try a few shared locations first (browsable straight from Filza's root);
// if the app sandbox blocks them we fall back to the app's own Documents dir,
// which Filza lists by app name under
//   /var/mobile/Containers/Data/Application/<UUID>/Documents/
static NSString *gLogPath = nil;

static void PDSTMResolveLogPath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = [NSString stringWithFormat:@"PDSTM-%@.log", PDSTMBundle()];
        NSFileManager *fm = [NSFileManager defaultManager];
        // Preferred shared spots, most-accessible first.
        NSArray<NSString *> *dirs = @[ @"/var/mobile/Documents",
                                       @"/var/mobile/Library/Logs",
                                       @"/var/mobile" ];
        for (NSString *dir in dirs) {
            NSString *p = [dir stringByAppendingPathComponent:name];
            // createFileAtPath returns NO if the sandbox denies the write.
            if ([fm createFileAtPath:p contents:[NSData data] attributes:nil]) {
                gLogPath = p;
                break;
            }
        }
        if (!gLogPath) {
            // Always-writable fallback: the app's own sandbox Documents dir.
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

    PDSTMResolveLogPath();
    if (!gLogPath) return;
    NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                      [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch (__unused id e) {}
        [fh closeFile];
    } else {
        [data writeToFile:gLogPath atomically:NO];
    }
}

// Returns whether this process should mix, latching the decision the first time
// other audio is observed playing while this app touches its session.
static BOOL PDSTMShouldMix(AVAudioSession *session) {
    if (session.isOtherAudioPlaying && !gLatchedSecondary) {
        gLatchedSecondary = YES;
        PDSTMLog(@"latched as SECONDARY source -> forcing MixWithOthers from now on");
    }
    return gLatchedSecondary;
}

%hook AVAudioSession

// Older convenience setter (category only). No options arg, so to add mixing we
// route through the mode/options setter (also hooked).
- (BOOL)setCategory:(NSString *)category error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@  (otherPlaying=%d latched=%d)",
             category, self.isOtherAudioPlaying, gLatchedSecondary);
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
    PDSTMLog(@"setCategory:%@ mode:%@ options:%lu  (otherPlaying=%d latched=%d)",
             category, mode, (unsigned long)options, self.isOtherAudioPlaying, gLatchedSecondary);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return %orig(category, mode, options, outError);
}

// Modern setter (iOS 11+). TikTok and most current apps use this one.
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ mode:%@ policy:%ld options:%lu  (otherPlaying=%d latched=%d)",
             category, mode, (long)policy, (unsigned long)options, self.isOtherAudioPlaying, gLatchedSecondary);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return %orig(category, mode, policy, options, outError);
}

- (BOOL)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    PDSTMLog(@"setCategory:%@ withOptions:%lu  (otherPlaying=%d latched=%d)",
             category, (unsigned long)options, self.isOtherAudioPlaying, gLatchedSecondary);
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return %orig(category, options, outError);
}

// Re-assert mixing at activation time. Many apps (TikTok included) configure
// their category once and only call -setActive: later; this is the hook that
// makes the common "music already playing -> open app -> it mixes" case work.
- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    PDSTMLog(@"setActive:%d  (cat=%@ opts=%lu otherPlaying=%d latched=%d)",
             active, self.category, (unsigned long)self.categoryOptions,
             self.isOtherAudioPlaying, gLatchedSecondary);
    if (active && PDSTMShouldMix(self)
        && !(self.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) {
        NSString *cat = self.category;
        if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            cat = AVAudioSessionCategoryAmbient;
        }
        PDSTMLog(@"  -> re-applying %@ with MixWithOthers before activating", cat);
        [self setCategory:cat
                     mode:self.mode
                  options:self.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers
                    error:nil];
    }
    return %orig;
}

- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    PDSTMLog(@"setActive:%d withOptions:%lu  (cat=%@ opts=%lu otherPlaying=%d latched=%d)",
             active, (unsigned long)options, self.category, (unsigned long)self.categoryOptions,
             self.isOtherAudioPlaying, gLatchedSecondary);
    if (active && PDSTMShouldMix(self)
        && !(self.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) {
        NSString *cat = self.category;
        if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            cat = AVAudioSessionCategoryAmbient;
        }
        PDSTMLog(@"  -> re-applying %@ with MixWithOthers before activating", cat);
        [self setCategory:cat
                     mode:self.mode
                  options:self.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers
                    error:nil];
    }
    return %orig;
}

%end

%ctor {
    NSLog(@"[PleaseDontStopTheMusic] TEST BUILD 2 loaded in %@", PDSTMBundle());
}
