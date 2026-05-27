#import <AVFoundation/AVFoundation.h>

// PleaseDontStopTheMusic
//
// Goal: let a second app (TikTok, a game, etc.) play audio WITHOUT pausing the
// music that is already playing, while leaving that music app in full control of
// the lock screen / Control Center "Now Playing" transport controls.
//
// Key insight: an audio session that opts into MixWithOthers is treated by iOS
// as a *secondary* source. It will not interrupt others, but it also gives up
// the Now Playing controls. So we must NOT force mixing on the primary music
// app, or its lock-screen skip/pause controls vanish (the old behaviour, and
// exactly the bug we are fixing).
//
// Heuristic: use -isOtherAudioPlaying at the moment an app configures its
// session.
//   * No other audio playing  -> this app is the primary source. Leave it
//     untouched so it keeps Now Playing controls and normal behaviour.
//   * Other audio already playing -> this app is the "intruder". Force it to
//     mix so it joins the existing playback instead of interrupting it (and so
//     it doesn't steal the lock-screen controls from the music app).
//
// IMPORTANT: only ever touch *pure playback* categories. Recording-capable
// sessions (PlayAndRecord / Record) and MultiRoute are used by live streaming,
// VoIP and real-time comms (e.g. TikTok LIVE, which records the mic while it
// plays). Forcing MixWithOthers onto those audio units — and worse, re-applying
// the category on every -setActive: while AVKit is spinning up Picture-in-
// Picture — stalls the audio unit and freezes the video pipeline. So we leave
// them completely alone and only mix the playback-only intruders.

// Returns YES only for the playback-only categories we are safe to force into
// mixing. Anything that can record (or MultiRoute) is left untouched.
static BOOL PDSTMIsMixablePlaybackCategory(NSString *category) {
    return [category isEqualToString:AVAudioSessionCategoryPlayback]
        || [category isEqualToString:AVAudioSessionCategorySoloAmbient]
        || [category isEqualToString:AVAudioSessionCategoryAmbient];
}

%hook AVAudioSession

// Older convenience setter (category only).
- (BOOL)setCategory:(NSString *)category error:(NSError **)outError {
    if (self.isOtherAudioPlaying && PDSTMIsMixablePlaybackCategory(category)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            // SoloAmbient cannot mix; Ambient is the mixable equivalent.
            return %orig(AVAudioSessionCategoryAmbient, outError);
        }
        if ([category isEqualToString:AVAudioSessionCategoryPlayback]) {
            // Route through the mode/options setter (also hooked) so the
            // MixWithOthers option is applied.
            return [self setCategory:category
                                mode:AVAudioSessionModeDefault
                             options:AVAudioSessionCategoryOptionMixWithOthers
                               error:outError];
        }
    }
    return %orig;
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (self.isOtherAudioPlaying && PDSTMIsMixablePlaybackCategory(category)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return %orig(category, mode, options, outError);
}

// Modern setter (iOS 11+). This is the one TikTok and most current apps use,
// and it was previously unhooked — which is why they interrupted background
// audio. Hooking it here is the core fix for the "audio stops" bug.
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    NSLog(@"[PleaseDontStopTheMusic] setCategory cat=%@ mode=%@ opts=%lu otherPlaying=%d mixable=%d",
          category, mode, (unsigned long)options, self.isOtherAudioPlaying,
          PDSTMIsMixablePlaybackCategory(category));
    if (self.isOtherAudioPlaying && PDSTMIsMixablePlaybackCategory(category)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return %orig(category, mode, policy, options, outError);
}

- (BOOL)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (self.isOtherAudioPlaying && PDSTMIsMixablePlaybackCategory(category)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            category = AVAudioSessionCategoryAmbient;
        }
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return %orig(category, options, outError);
}

// Some apps configure their category once (when nothing else is playing) and
// only call -setActive: later. Catch that case at activation time: if other
// audio is playing and we are about to activate a non-mixing interrupting
// session, re-apply the category with MixWithOthers so we don't cut it off.
// This is load-bearing for mixing — without it TikTok interrupts the music.
- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    NSLog(@"[PleaseDontStopTheMusic] setActive:%d cat=%@ mode=%@ opts=%lu otherPlaying=%d",
          active, self.category, self.mode, (unsigned long)self.categoryOptions,
          self.isOtherAudioPlaying);
    if (active && self.isOtherAudioPlaying
        && PDSTMIsMixablePlaybackCategory(self.category)
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
    NSLog(@"[PleaseDontStopTheMusic] setActive:%d withOptions:%lu cat=%@ mode=%@ opts=%lu otherPlaying=%d",
          active, (unsigned long)options, self.category, self.mode,
          (unsigned long)self.categoryOptions, self.isOtherAudioPlaying);
    if (active && self.isOtherAudioPlaying
        && PDSTMIsMixablePlaybackCategory(self.category)
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
    NSLog(@"[PleaseDontStopTheMusic] loaded");
}
