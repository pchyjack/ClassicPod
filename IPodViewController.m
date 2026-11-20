#import "IPodViewController.h"
#import "ClickWheelView.h"
#import "IPScreenView.h"
#import "IPMenu.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kClickerKey     = @"ClickerEnabled";
static NSString *const kMainMenuKey    = @"MainMenuItems";
static NSString *const kMusicMenuKey   = @"MusicMenuItems";
static NSString *const kBrightnessKey  = @"Brightness";        // 0.1 ... 1.0
static NSString *const kBacklightKey   = @"BacklightSeconds";  // 0 = always on
static NSString *const kVolumeLimitKey = @"VolumeLimit";       // 0 ... 1
static NSString *const kRatingsKey     = @"Ratings";

static NSArray<NSString *> *MainMenuKeys(void) {
    return @[@"music", @"playlists", @"artists", @"albums", @"songs", @"genres", @"podcasts", @"audiobooks", @"shuffle"];
}

static NSArray<NSString *> *MusicMenuKeys(void) {
    return @[@"coverflow", @"playlists", @"artists", @"albums", @"songs", @"genres", @"composers", @"compilations"];
}

static NSDictionary<NSString *, NSString *> *LibraryTitles(void) {
    return @{@"music": @"Music", @"coverflow": @"Cover Flow", @"playlists": @"Playlists", @"artists": @"Artists",
             @"albums": @"Albums", @"songs": @"Songs", @"genres": @"Genres", @"composers": @"Composers",
             @"compilations": @"Compilations", @"podcasts": @"Podcasts", @"audiobooks": @"Audiobooks",
             @"shuffle": @"Shuffle Songs"};
}

// "#" for digits and symbols, otherwise the first letter A...Z.
static NSString *LetterForTitle(NSString *title) {
    if (title.length == 0) return @"#";
    NSRange r = [title rangeOfComposedCharacterSequenceAtIndex:0];
    NSString *s = [[title substringWithRange:r] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch
                                                                     locale:nil].uppercaseString;
    if (s.length == 1) {
        unichar c = [s characterAtIndex:0];
        if (c >= 'A' && c <= 'Z') return s;
    }
    return @"#";
}

@interface IPodViewController () <ClickWheelDelegate>
@property (nonatomic, strong) CAGradientLayer *backgroundLayer;
@property (nonatomic, strong) UIView *screenFrame;
@property (nonatomic, strong) IPScreenView *screenView;
@property (nonatomic, strong) UIView *dimView;                    // brightness / backlight
@property (nonatomic, strong) ClickWheelView *wheel;
@property (nonatomic, strong) MPVolumeView *volumeView;
@property (nonatomic, strong) MPMusicPlayerController *player;   // nil until the first song is played
@property (nonatomic) BOOL hasQueue;
@property (nonatomic, strong) NSTimer *seekTimer;
@property (nonatomic) NSInteger seekDirection;
@property (nonatomic) CFTimeInterval lastPreviousPress;
@property (nonatomic) MPMusicShuffleMode shuffleSetting;
@property (nonatomic) MPMusicRepeatMode repeatSetting;
@property (nonatomic, strong) NSMutableArray<IPMenu *> *stack;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, strong) NSTimer *bottomModeTimer;
@property (nonatomic, strong) NSTimer *backlightTimer;
@property (nonatomic) BOOL backlightOn;
@property (nonatomic) BOOL nowPlayingActive;
@property (nonatomic) BOOL coverFlowActive;
@property (nonatomic) NSInteger sliderKind;                       // 0 none, 1 brightness, 2 volume limit
@property (nonatomic, copy) NSArray<MPMediaItemCollection *> *coverAlbums;
@property (nonatomic, copy) NSArray<NSString *> *coverTitles;
@property (nonatomic) NSInteger coverIndex;
@property (nonatomic) BOOL fastScrolling;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *stepTimes;
@property (nonatomic) NSInteger queueCount;
@end

@implementation IPodViewController

#pragma mark - Lifecycle

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

- (void)viewDidLoad {
    [super viewDidLoad];

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kClickerKey: @YES,
        kMainMenuKey: @[@"music", @"shuffle"],
        kMusicMenuKey: @[@"coverflow", @"playlists", @"artists", @"albums", @"songs", @"genres", @"composers"],
        kBrightnessKey: @1.0,
        kBacklightKey: @10,
        kVolumeLimitKey: @1.0,
    }];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;

    // Body of the iPod
    self.view.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
    self.backgroundLayer = [CAGradientLayer layer];
    self.backgroundLayer.colors = @[(id)[UIColor colorWithWhite:0.99 alpha:1.0].CGColor,
                                    (id)[UIColor colorWithWhite:0.86 alpha:1.0].CGColor];
    [self.view.layer addSublayer:self.backgroundLayer];

    self.screenFrame = [UIView new];
    self.screenFrame.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.screenFrame.layer.cornerRadius = 8;
    self.screenFrame.layer.borderWidth = 1;
    self.screenFrame.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:1.0].CGColor;
    [self.view addSubview:self.screenFrame];

    self.screenView = [IPScreenView new];
    self.screenView.layer.cornerRadius = 4;
    self.screenView.layer.masksToBounds = YES;
    [self.screenFrame addSubview:self.screenView];

    self.dimView = [UIView new];
    self.dimView.backgroundColor = [UIColor blackColor];
    self.dimView.alpha = 0;
    self.dimView.userInteractionEnabled = NO;
    self.dimView.layer.cornerRadius = 4;
    [self.screenFrame addSubview:self.dimView];

    self.wheel = [ClickWheelView new];
    self.wheel.delegate = self;
    [self.view addSubview:self.wheel];

    self.shuffleSetting = MPMusicShuffleModeOff;
    self.repeatSetting = MPMusicRepeatModeNone;
    self.stepTimes = [NSMutableArray array];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(batteryChanged)
                                                 name:UIDeviceBatteryLevelDidChangeNotification object:nil];

    // Menus
    self.stack = [NSMutableArray array];
    [self.stack addObject:[self makeRootMenu]];
    [self refreshScreen];
    [self wakeBacklight];

    if ([MPMediaLibrary authorizationStatus] == MPMediaLibraryAuthorizationStatusNotDetermined) {
        [MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self reloadAllMenus]; });
        }];
    }

    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick)
                                                    userInfo:nil repeats:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.backgroundLayer.frame = b;
    [CATransaction commit];

    CGFloat margin = 14;
    CGFloat frameW = b.size.width - 2 * margin;
    CGFloat screenW = frameW - 12;
    CGFloat screenH = round(screenW * 0.75);   // 4:3 LCD
    CGFloat frameH = screenH + 12;
    self.screenFrame.frame = CGRectMake(margin, safe.top + margin, frameW, frameH);
    self.screenView.frame = CGRectMake(6, 6, screenW, screenH);
    self.dimView.frame = self.screenView.frame;

    CGFloat availTop = CGRectGetMaxY(self.screenFrame.frame) + 10;
    CGFloat avail = b.size.height - safe.bottom - availTop - 10;
    CGFloat d = MAX(160, MIN(frameW * 0.88, avail));
    self.wheel.frame = CGRectMake((b.size.width - d) / 2.0, availTop + (avail - d) / 2.0, d, d);
}

#pragma mark - Menus

- (BOOL)libraryAuthorized {
    return [MPMediaLibrary authorizationStatus] == MPMediaLibraryAuthorizationStatusAuthorized;
}

- (IPMenu *)makeRootMenu {
    return [IPMenu menuWithTitle:@"iPod" builder:^NSArray<IPMenuItem *> *{
        NSArray *enabled = [[NSUserDefaults standardUserDefaults] arrayForKey:kMainMenuKey];
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *key in MainMenuKeys()) {
            if ([key isEqualToString:@"shuffle"] || ![enabled containsObject:key]) continue;
            [a addObject:[self libraryItemForKey:key]];
        }
        [a addObject:[IPMenuItem itemWithTitle:@"Settings" hasChildren:YES action:^{ [self pushSettingsMenu]; }]];
        if ([enabled containsObject:@"shuffle"]) {
            [a addObject:[IPMenuItem itemWithTitle:@"Shuffle Songs" hasChildren:NO action:^{ [self shuffleAllSongs]; }]];
        }
        if (self.hasQueue) {
            [a addObject:[IPMenuItem itemWithTitle:@"Now Playing" hasChildren:YES action:^{ [self showNowPlaying]; }]];
        }
        return a;
    }];
}

- (void)pushMenuWithTitle:(NSString *)title builder:(IPBuilder)builder {
    self.nowPlayingActive = NO;
    self.coverFlowActive = NO;
    self.sliderKind = 0;
    [self.stack addObject:[IPMenu menuWithTitle:title builder:builder]];
    [self refreshScreen];
}

- (void)popMenu {
    if (self.stack.count > 1) [self.stack removeLastObject];
    [self refreshScreen];
}

// One row of the Main menu / Music menu.
- (IPMenuItem *)libraryItemForKey:(NSString *)key {
    IPAction action = nil;
    if ([key isEqualToString:@"music"])             action = ^{ [self pushMusicMenu]; };
    else if ([key isEqualToString:@"coverflow"])    action = ^{ [self showCoverFlow]; };
    else if ([key isEqualToString:@"playlists"])    action = ^{ [self pushPlaylistsMenu]; };
    else if ([key isEqualToString:@"artists"])      action = ^{ [self pushArtistsMenu]; };
    else if ([key isEqualToString:@"albums"])       action = ^{ [self pushAlbumsMenu]; };
    else if ([key isEqualToString:@"songs"])        action = ^{
        [self pushSongListWithTitle:@"Songs" items:[MPMediaQuery songsQuery].items];
    };
    else if ([key isEqualToString:@"genres"])       action = ^{
        [self pushCollectionsMenuWithTitle:@"Genres" query:^MPMediaQuery *{ return [MPMediaQuery genresQuery]; }
                                     label:^NSString *(MPMediaItem *m) { return m.genre; } fallback:@"Unknown Genre"];
    };
    else if ([key isEqualToString:@"composers"])    action = ^{
        [self pushCollectionsMenuWithTitle:@"Composers" query:^MPMediaQuery *{ return [MPMediaQuery composersQuery]; }
                                     label:^NSString *(MPMediaItem *m) { return m.composer; } fallback:@"Unknown Composer"];
    };
    else if ([key isEqualToString:@"compilations"]) action = ^{
        [self pushCollectionsMenuWithTitle:@"Compilations" query:^MPMediaQuery *{ return [MPMediaQuery compilationsQuery]; }
                                     label:^NSString *(MPMediaItem *m) { return m.albumTitle; } fallback:@"Unknown Album"];
    };
    else if ([key isEqualToString:@"podcasts"])     action = ^{
        [self pushCollectionsMenuWithTitle:@"Podcasts" query:^MPMediaQuery *{ return [MPMediaQuery podcastsQuery]; }
                                     label:^NSString *(MPMediaItem *m) { return m.podcastTitle ?: m.albumTitle; } fallback:@"Podcast"];
    };
    else if ([key isEqualToString:@"audiobooks"])   action = ^{
        [self pushCollectionsMenuWithTitle:@"Audiobooks" query:^MPMediaQuery *{ return [MPMediaQuery audiobooksQuery]; }
                                     label:^NSString *(MPMediaItem *m) { return m.albumTitle ?: m.title; } fallback:@"Audiobook"];
    };
    return [IPMenuItem itemWithTitle:LibraryTitles()[key] hasChildren:YES action:action];
}

- (void)pushMusicMenu {
    [self pushMenuWithTitle:@"Music" builder:^NSArray<IPMenuItem *> *{
        if (![self libraryAuthorized]) {
            return @[[IPMenuItem itemWithTitle:@"Allow Music access" hasChildren:NO action:^{
                [MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus s) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self reloadAllMenus]; });
                }];
            }]];
        }
        NSArray *enabled = [[NSUserDefaults standardUserDefaults] arrayForKey:kMusicMenuKey];
        NSMutableArray *r = [NSMutableArray array];
        for (NSString *key in MusicMenuKeys()) {
            if ([enabled containsObject:key]) [r addObject:[self libraryItemForKey:key]];
        }
        return r;
    }];
}

- (void)pushPlaylistsMenu {
    [self pushMenuWithTitle:@"Playlists" builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray array];
        for (MPMediaItemCollection *c in [MPMediaQuery playlistsQuery].collections) {
            NSString *name = [c valueForProperty:MPMediaPlaylistPropertyName] ?: @"Playlist";
            [r addObject:[self collectionItemWithTitle:name items:c.items]];
        }
        return r;
    }];
}

- (void)pushArtistsMenu {
    [self pushMenuWithTitle:@"Artists" builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray array];
        for (MPMediaItemCollection *c in [MPMediaQuery artistsQuery].collections) {
            MPMediaItem *rep = c.representativeItem;
            NSString *name = rep.artist ?: @"Unknown Artist";
            MPMediaEntityPersistentID pid = rep.artistPersistentID;
            [r addObject:[IPMenuItem itemWithTitle:name hasChildren:YES action:^{
                [self pushArtistNamed:name persistentID:pid allItems:c.items];
            }]];
        }
        return r;
    }];
}

- (void)pushArtistNamed:(NSString *)name persistentID:(MPMediaEntityPersistentID)pid allItems:(NSArray<MPMediaItem *> *)allItems {
    [self pushMenuWithTitle:name builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray array];
        [r addObject:[IPMenuItem itemWithTitle:@"All Songs" hasChildren:YES action:^{
            [self pushSongListWithTitle:name items:allItems];
        }]];
        MPMediaQuery *q = [MPMediaQuery albumsQuery];
        [q addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:@(pid)
                                                               forProperty:MPMediaItemPropertyArtistPersistentID]];
        for (MPMediaItemCollection *c in q.collections) {
            NSString *album = c.representativeItem.albumTitle ?: @"Unknown Album";
            [r addObject:[self collectionItemWithTitle:album items:c.items]];
        }
        return r;
    }];
}

- (void)pushAlbumsMenu {
    [self pushMenuWithTitle:@"Albums" builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray array];
        for (MPMediaItemCollection *c in [MPMediaQuery albumsQuery].collections) {
            NSString *album = c.representativeItem.albumTitle ?: @"Unknown Album";
            [r addObject:[self collectionItemWithTitle:album items:c.items]];
        }
        return r;
    }];
}

// Genres, Composers, Compilations, Podcasts, Audiobooks: a list of groups, each opening its songs.
- (void)pushCollectionsMenuWithTitle:(NSString *)title
                               query:(MPMediaQuery *(^)(void))queryBlock
                               label:(NSString *(^)(MPMediaItem *))labelBlock
                            fallback:(NSString *)fallback {
    [self pushMenuWithTitle:title builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray array];
        for (MPMediaItemCollection *c in queryBlock().collections) {
            NSString *name = labelBlock(c.representativeItem) ?: fallback;
            [r addObject:[self collectionItemWithTitle:name items:c.items]];
        }
        return r;
    }];
}

- (void)pushSongListWithTitle:(NSString *)title items:(NSArray<MPMediaItem *> *)items {
    [self pushMenuWithTitle:title builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray arrayWithCapacity:items.count];
        [items enumerateObjectsUsingBlock:^(MPMediaItem *song, NSUInteger i, BOOL *stop) {
            IPAction play = ^{
                [self playItems:items startIndex:i shuffle:NO];
                [self showNowPlaying];
            };
            IPMenuItem *row = [IPMenuItem itemWithTitle:song.title ?: @"Unknown Song" hasChildren:NO action:play];
            row.playAction = play;
            [r addObject:row];
        }];
        return r;
    }];
}

- (IPMenuItem *)collectionItemWithTitle:(NSString *)title items:(NSArray<MPMediaItem *> *)items {
    IPMenuItem *row = [IPMenuItem itemWithTitle:title hasChildren:YES action:^{
        [self pushSongListWithTitle:title items:items];
    }];
    row.playAction = ^{
        [self playItems:items startIndex:0 shuffle:NO];
        [self showNowPlaying];
    };
    return row;
}

- (NSArray<MPMediaItem *> *)songsWithValue:(id)value forProperty:(NSString *)property {
    MPMediaQuery *q = [MPMediaQuery songsQuery];
    [q addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:value forProperty:property]];
    return q.items;
}

// Press and hold Center on Now Playing: "Browse Artist" / "Browse Album"
- (void)showNowPlayingOptions {
    MPMediaItem *item = self.player.nowPlayingItem;
    if (!item) return;
    [self pushMenuWithTitle:@"Options" builder:^NSArray<IPMenuItem *> *{
        return @[
            [IPMenuItem itemWithTitle:@"Browse Artist" hasChildren:YES action:^{
                NSArray *songs = [self songsWithValue:@(item.artistPersistentID) forProperty:MPMediaItemPropertyArtistPersistentID];
                [self pushArtistNamed:(item.artist ?: @"Unknown Artist") persistentID:item.artistPersistentID allItems:songs];
            }],
            [IPMenuItem itemWithTitle:@"Browse Album" hasChildren:YES action:^{
                NSArray *songs = [self songsWithValue:@(item.albumPersistentID) forProperty:MPMediaItemPropertyAlbumPersistentID];
                [self pushSongListWithTitle:(item.albumTitle ?: @"Album") items:songs];
            }],
        ];
    }];
}

#pragma mark - Settings

- (void)pushChecklistMenuTitle:(NSString *)title keys:(NSArray<NSString *> *)keys defaultsKey:(NSString *)defaultsKey {
    [self pushMenuWithTitle:title builder:^NSArray<IPMenuItem *> *{
        NSArray *enabled = [[NSUserDefaults standardUserDefaults] arrayForKey:defaultsKey];
        NSMutableArray *r = [NSMutableArray array];
        for (NSString *key in keys) {
            BOOL on = [enabled containsObject:key];
            [r addObject:[IPMenuItem itemWithTitle:LibraryTitles()[key] detail:(on ? @"\u2713" : nil) action:^{
                NSMutableArray *list = [[[NSUserDefaults standardUserDefaults] arrayForKey:defaultsKey] mutableCopy] ?: [NSMutableArray array];
                if (on) [list removeObject:key]; else [list addObject:key];
                [[NSUserDefaults standardUserDefaults] setObject:list forKey:defaultsKey];
                [self reloadAllMenus];
            }]];
        }
        return r;
    }];
}

- (void)pushSettingsMenu {
    [self pushMenuWithTitle:@"Settings" builder:^NSArray<IPMenuItem *> *{
        BOOL clicker = [[NSUserDefaults standardUserDefaults] boolForKey:kClickerKey];
        MPMusicShuffleMode sm = self.shuffleSetting;
        NSString *shuffleText = (sm == MPMusicShuffleModeSongs) ? @"Songs" : (sm == MPMusicShuffleModeAlbums ? @"Albums" : @"Off");
        MPMusicRepeatMode rm = self.repeatSetting;
        NSString *repeat = (rm == MPMusicRepeatModeAll) ? @"All" : (rm == MPMusicRepeatModeOne ? @"One" : @"Off");

        return @[
            [IPMenuItem itemWithTitle:@"About" hasChildren:YES action:^{ [self pushAboutMenu]; }],
            [IPMenuItem itemWithTitle:@"Main Menu" hasChildren:YES action:^{
                [self pushChecklistMenuTitle:@"Main Menu" keys:MainMenuKeys() defaultsKey:kMainMenuKey];
            }],
            [IPMenuItem itemWithTitle:@"Music Menu" hasChildren:YES action:^{
                [self pushChecklistMenuTitle:@"Music Menu" keys:MusicMenuKeys() defaultsKey:kMusicMenuKey];
            }],
            [IPMenuItem itemWithTitle:@"Shuffle" detail:shuffleText action:^{
                self.shuffleSetting = (sm == MPMusicShuffleModeSongs) ? MPMusicShuffleModeAlbums
                                    : (sm == MPMusicShuffleModeAlbums ? MPMusicShuffleModeOff : MPMusicShuffleModeSongs);
                if (self.player) self.player.shuffleMode = self.shuffleSetting;
                [self reloadTopMenu];
            }],
            [IPMenuItem itemWithTitle:@"Repeat" detail:repeat action:^{
                if (rm == MPMusicRepeatModeAll)      self.repeatSetting = MPMusicRepeatModeOne;
                else if (rm == MPMusicRepeatModeOne) self.repeatSetting = MPMusicRepeatModeNone;
                else                                 self.repeatSetting = MPMusicRepeatModeAll;
                if (self.player) self.player.repeatMode = self.repeatSetting;
                [self reloadTopMenu];
            }],
            [IPMenuItem itemWithTitle:@"Backlight Timer" hasChildren:YES action:^{ [self pushBacklightMenu]; }],
            [IPMenuItem itemWithTitle:@"Brightness" hasChildren:YES action:^{ [self showSlider:1]; }],
            [IPMenuItem itemWithTitle:@"Clicker" detail:(clicker ? @"On" : @"Off") action:^{
                [[NSUserDefaults standardUserDefaults] setBool:!clicker forKey:kClickerKey];
                [self reloadTopMenu];
            }],
            [IPMenuItem itemWithTitle:@"Volume Limit" hasChildren:YES action:^{ [self showSlider:2]; }],
            [IPMenuItem itemWithTitle:@"Reset Settings" hasChildren:YES action:^{ [self pushResetMenu]; }],
        ];
    }];
}

- (void)pushAboutMenu {
    [self pushMenuWithTitle:@"About" builder:^NSArray<IPMenuItem *> *{
        UIDevice *d = [UIDevice currentDevice];
        NSUInteger songs = [self libraryAuthorized] ? [MPMediaQuery songsQuery].items.count : 0;
        return @[
            [IPMenuItem itemWithTitle:@"Songs" detail:[NSString stringWithFormat:@"%lu", (unsigned long)songs] action:nil],
            [IPMenuItem itemWithTitle:@"Model" detail:d.model action:nil],
            [IPMenuItem itemWithTitle:@"Version" detail:d.systemVersion action:nil],
            [IPMenuItem itemWithTitle:@"Name" detail:d.name action:nil],
        ];
    }];
}

- (void)pushBacklightMenu {
    [self pushMenuWithTitle:@"Backlight Timer" builder:^NSArray<IPMenuItem *> *{
        NSInteger current = [[NSUserDefaults standardUserDefaults] integerForKey:kBacklightKey];
        NSMutableArray *r = [NSMutableArray array];
        for (NSNumber *option in @[@2, @5, @10, @15, @20, @0]) {
            NSInteger secs = option.integerValue;
            NSString *title = (secs == 0) ? @"Always On" : [NSString stringWithFormat:@"%ld Seconds", (long)secs];
            [r addObject:[IPMenuItem itemWithTitle:title detail:(secs == current ? @"\u2713" : nil) action:^{
                [[NSUserDefaults standardUserDefaults] setInteger:secs forKey:kBacklightKey];
                [self wakeBacklight];
                [self reloadTopMenu];
            }]];
        }
        return r;
    }];
}

- (void)pushResetMenu {
    [self pushMenuWithTitle:@"Reset Settings" builder:^NSArray<IPMenuItem *> *{
        return @[
            [IPMenuItem itemWithTitle:@"Cancel" hasChildren:NO action:^{ [self popMenu]; }],
            [IPMenuItem itemWithTitle:@"Reset" hasChildren:NO action:^{
                [self resetAllSettings];
                [self popMenu];
            }],
        ];
    }];
}

- (void)resetAllSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[kClickerKey, kMainMenuKey, kMusicMenuKey, kBrightnessKey, kBacklightKey, kVolumeLimitKey]) {
        [d removeObjectForKey:key];
    }
    self.shuffleSetting = MPMusicShuffleModeOff;
    self.repeatSetting = MPMusicRepeatModeNone;
    if (self.player) {
        self.player.shuffleMode = self.shuffleSetting;
        self.player.repeatMode = self.repeatSetting;
    }
    [self wakeBacklight];
    [self reloadAllMenus];
}

- (void)showSlider:(NSInteger)kind {
    self.sliderKind = kind;
    self.coverFlowActive = NO;
    [self refreshScreen];
}

- (void)showCoverFlow {
    NSArray<MPMediaItemCollection *> *albums = [MPMediaQuery albumsQuery].collections;
    NSMutableArray *titles = [NSMutableArray arrayWithCapacity:albums.count];
    for (MPMediaItemCollection *c in albums) [titles addObject:c.representativeItem.albumTitle ?: @""];
    self.coverAlbums = albums;
    self.coverTitles = titles;
    self.coverIndex = 0;
    self.coverFlowActive = YES;
    [self refreshScreen];
}

- (void)reloadTopMenu {
    [self.stack.lastObject reload];
    [self refreshScreen];
}

- (void)reloadAllMenus {
    for (IPMenu *m in self.stack) [m reload];
    [self refreshScreen];
}

#pragma mark - Fast-forward / rewind (press and hold Next / Previous)

- (void)startSeeking:(NSInteger)direction {
    if (!self.player) return;
    self.seekDirection = direction;
    [self.seekTimer invalidate];
    self.seekTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(seekTick)
                                                    userInfo:nil repeats:YES];
}

- (void)stopSeeking {
    [self.seekTimer invalidate];
    self.seekTimer = nil;
}

- (void)seekTick {
    MPMediaItem *item = self.player.nowPlayingItem;
    if (!item) return;
    NSTimeInterval t = self.player.currentPlaybackTime + self.seekDirection * 8.0;
    self.player.currentPlaybackTime = MAX(0, MIN(item.playbackDuration - 1, t));
    [self updateNowPlaying];
    [self.screenView setNeedsDisplay];
}

#pragma mark - Playback

- (MPMusicPlayerController *)ensurePlayer {
    if (!self.player) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:nil];
        [session setActive:YES error:nil];

        MPMusicPlayerController *p = [MPMusicPlayerController applicationMusicPlayer];
        [p beginGeneratingPlaybackNotifications];
        p.shuffleMode = self.shuffleSetting;
        p.repeatMode = self.repeatSetting;
        self.player = p;

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(playerChanged)
                   name:MPMusicPlayerControllerNowPlayingItemDidChangeNotification object:p];
        [nc addObserver:self selector:@selector(playerChanged)
                   name:MPMusicPlayerControllerPlaybackStateDidChangeNotification object:p];
    }
    return self.player;
}

- (void)playItems:(NSArray<MPMediaItem *> *)items startIndex:(NSUInteger)index shuffle:(BOOL)shuffle {
    if (index >= items.count) return;
    MPMusicPlayerController *p = [self ensurePlayer];
    self.hasQueue = YES;
    self.queueCount = (NSInteger)items.count;
    if (shuffle) self.shuffleSetting = MPMusicShuffleModeSongs;
    [p setQueueWithItemCollection:[MPMediaItemCollection collectionWithItems:items]];
    p.shuffleMode = self.shuffleSetting;
    p.nowPlayingItem = items[index];
    [p play];
}

- (void)shuffleAllSongs {
    NSArray<MPMediaItem *> *songs = [MPMediaQuery songsQuery].items;
    if (songs.count == 0) return;
    [self playItems:songs startIndex:arc4random_uniform((uint32_t)songs.count) shuffle:YES];
    [self showNowPlaying];
}

- (void)togglePlayPause {
    if (!self.player) return;
    if (self.player.playbackState == MPMusicPlaybackStatePlaying) {
        [self.player pause];
    } else if (self.hasQueue) {
        [self.player play];
    }
}

- (void)showNowPlaying {
    self.coverFlowActive = NO;
    self.sliderKind = 0;
    self.nowPlayingActive = YES;
    self.screenView.bottomMode = IPBottomModeProgress;
    [self updateNowPlaying];
    [self refreshScreen];
}

#pragma mark - Ratings (stored in this app; iOS has no public API to change a song's rating)

- (NSString *)ratingKeyForItem:(MPMediaItem *)item {
    return [NSString stringWithFormat:@"%llu", (unsigned long long)item.persistentID];
}

- (NSInteger)ratingForItem:(MPMediaItem *)item {
    if (!item) return 0;
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kRatingsKey];
    NSNumber *n = saved[[self ratingKeyForItem:item]];
    return n ? n.integerValue : (NSInteger)item.rating;
}

- (void)setRating:(NSInteger)rating forItem:(MPMediaItem *)item {
    if (!item) return;
    NSMutableDictionary *saved = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kRatingsKey] mutableCopy]
                                 ?: [NSMutableDictionary dictionary];
    saved[[self ratingKeyForItem:item]] = @(rating);
    [[NSUserDefaults standardUserDefaults] setObject:saved forKey:kRatingsKey];
}

#pragma mark - Backlight / brightness

- (void)applyBacklight {
    float b = [[NSUserDefaults standardUserDefaults] floatForKey:kBrightnessKey];
    CGFloat dim = (1.0 - b) * 0.6;
    if (!self.backlightOn) dim = 0.82;
    self.dimView.alpha = dim;
}

- (void)wakeBacklight {
    BOOL wasOff = !self.backlightOn;
    self.backlightOn = YES;
    [self.backlightTimer invalidate];
    self.backlightTimer = nil;
    NSInteger secs = [[NSUserDefaults standardUserDefaults] integerForKey:kBacklightKey];
    if (secs > 0) {
        self.backlightTimer = [NSTimer scheduledTimerWithTimeInterval:secs target:self
                                                             selector:@selector(backlightTimeout)
                                                             userInfo:nil repeats:NO];
    }
    if (wasOff) {
        [UIView animateWithDuration:0.15 animations:^{ [self applyBacklight]; }];
    } else {
        [self applyBacklight];
    }
}

- (void)backlightTimeout {
    self.backlightTimer = nil;
    self.backlightOn = NO;
    [UIView animateWithDuration:0.5 animations:^{ [self applyBacklight]; }];
}

#pragma mark - Screen updates

- (void)refreshScreen {
    IPMenu *m = self.stack.lastObject;
    IPScreenView *s = self.screenView;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    if (self.sliderKind == 1) {
        s.mode = IPScreenModeSlider;
        s.title = @"Brightness";
        s.sliderCaption = @"Brightness";
        s.sliderValue = ([d floatForKey:kBrightnessKey] - 0.1) / 0.9;
        s.sliderMarker = -1;
    } else if (self.sliderKind == 2) {
        s.mode = IPScreenModeSlider;
        s.title = @"Volume Limit";
        s.sliderCaption = @"Maximum Volume";
        s.sliderValue = [AVAudioSession sharedInstance].outputVolume;
        s.sliderMarker = [d floatForKey:kVolumeLimitKey];
    } else if (self.coverFlowActive) {
        s.mode = IPScreenModeCoverFlow;
        s.title = @"Cover Flow";
        s.coverItems = self.coverAlbums;
        s.coverIndex = self.coverIndex;
    } else if (self.nowPlayingActive) {
        s.mode = IPScreenModeNowPlaying;
        s.title = @"Now Playing";
    } else {
        s.mode = IPScreenModeMenu;
        s.title = m.title;
    }
    s.items = m.items;
    s.selectedIndex = m.selectedIndex;
    [self updateNowPlaying];
    [s setNeedsDisplay];
}

- (void)updateNowPlaying {
    IPScreenView *s = self.screenView;
    s.shuffleMode = self.shuffleSetting;
    s.repeatMode = self.repeatSetting;
    if (!self.player) {
        s.nowPlayingItem = nil;
        s.elapsed = 0;
        s.duration = 0;
        s.playing = NO;
        s.queueIndex = -1;
        s.queueCount = 0;
        s.rating = 0;
        return;
    }
    MPMediaItem *item = self.player.nowPlayingItem;
    s.nowPlayingItem = item;
    s.rating = [self ratingForItem:item];
    NSTimeInterval t = self.player.currentPlaybackTime;
    s.elapsed = (isnan(t) || t < 0) ? 0 : t;
    s.duration = item.playbackDuration;
    s.playing = (self.player.playbackState == MPMusicPlaybackStatePlaying);
    NSUInteger idx = self.player.indexOfNowPlayingItem;
    s.queueIndex = (idx == NSNotFound) ? -1 : (NSInteger)idx;
    s.queueCount = self.queueCount;
}

- (void)tick {
    if (!self.player) return;
    [self updateNowPlaying];
    [self.screenView setNeedsDisplay];
}

- (void)playerChanged {
    [self updateNowPlaying];
    if (self.stack.count == 1) [self reloadTopMenu]; // root shows "Now Playing" only when something is queued
    [self.screenView setNeedsDisplay];
}

- (void)batteryChanged {
    [self.screenView setNeedsDisplay];
}

- (void)scheduleBottomModeReset {
    [self.bottomModeTimer invalidate];
    self.bottomModeTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
                                                          selector:@selector(resetBottomMode)
                                                          userInfo:nil repeats:NO];
}

- (void)resetBottomMode {
    self.screenView.bottomMode = IPBottomModeProgress;
    [self.screenView setNeedsDisplay];
}

#pragma mark - Volume / click

- (void)setSystemVolume:(float)volume {
    if (!self.volumeView) {
        // Hidden volume view, created only when first needed: lets the wheel change the system volume.
        self.volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 200, 40)];
        [self.view addSubview:self.volumeView];
        [self.volumeView layoutIfNeeded];
    }
    for (UIView *sub in self.volumeView.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) {
            UISlider *slider = (UISlider *)sub;
            [slider setValue:volume animated:NO];
            [slider sendActionsForControlEvents:UIControlEventValueChanged];
            [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
            break;
        }
    }
}

- (void)click {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kClickerKey]) {
        AudioServicesPlaySystemSound(1104);
    }
}

#pragma mark - Fast scrolling by letter

// Moving the thumb quickly on a long list (or Cover Flow) jumps by letter, as on the real iPod.
// Returns YES (and sets *result) while fast scrolling is active.
- (BOOL)fastScrollBySteps:(NSInteger)steps titles:(NSArray<NSString *> *)titles current:(NSInteger)current result:(NSInteger *)result {
    if (titles.count < 30) return NO;

    CFTimeInterval now = CACurrentMediaTime();
    for (NSInteger i = 0; i < labs(steps); i++) [self.stepTimes addObject:@(now)];
    while (self.stepTimes.count > 0 && now - [self.stepTimes.firstObject doubleValue] > 0.4) {
        [self.stepTimes removeObjectAtIndex:0];
    }
    if (!self.fastScrolling && self.stepTimes.count >= 5) self.fastScrolling = YES;
    if (!self.fastScrolling) return NO;

    NSMutableArray<NSString *> *letters = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *firstIndex = [NSMutableDictionary dictionary];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSString *L = LetterForTitle(titles[i]);
        if (!firstIndex[L]) {
            firstIndex[L] = @(i);
            [letters addObject:L];
        }
    }
    [letters sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqualToString:@"#"]) return [b isEqualToString:@"#"] ? NSOrderedSame : NSOrderedAscending;
        if ([b isEqualToString:@"#"]) return NSOrderedDescending;
        return [a compare:b];
    }];

    NSInteger li = [letters indexOfObject:LetterForTitle(titles[MAX(0, MIN((NSInteger)titles.count - 1, current))])];
    if (li == NSNotFound) li = 0;
    li = MAX(0, MIN((NSInteger)letters.count - 1, li + steps));
    NSString *letter = letters[li];
    *result = firstIndex[letter].integerValue;
    self.screenView.overlayLetter = letter;
    return YES;
}

#pragma mark - ClickWheelDelegate

- (void)clickWheelDidBeginTouch:(ClickWheelView *)wheel {
    [self wakeBacklight];
}

- (void)clickWheelDidEndTouch:(ClickWheelView *)wheel {
    [self.stepTimes removeAllObjects];
    if (self.fastScrolling || self.screenView.overlayLetter) {
        self.fastScrolling = NO;
        self.screenView.overlayLetter = nil;
        [self refreshScreen];
    }
}

- (void)clickWheel:(ClickWheelView *)wheel didRotateBySteps:(NSInteger)steps {
    [self wakeBacklight];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    // Brightness / Volume Limit screens
    if (self.sliderKind == 1) {
        float b = MAX(0.1f, MIN(1.0f, [d floatForKey:kBrightnessKey] + steps / 20.0f));
        [d setFloat:b forKey:kBrightnessKey];
        [self applyBacklight];
        [self refreshScreen];
        return;
    }
    if (self.sliderKind == 2) {
        float limit = MAX(0.05f, MIN(1.0f, [d floatForKey:kVolumeLimitKey] + steps / 16.0f));
        [d setFloat:limit forKey:kVolumeLimitKey];
        if ([AVAudioSession sharedInstance].outputVolume > limit) [self setSystemVolume:limit];
        [self refreshScreen];
        return;
    }

    // Cover Flow
    if (self.coverFlowActive) {
        NSInteger n = (NSInteger)self.coverAlbums.count;
        NSInteger newIndex;
        if (![self fastScrollBySteps:steps titles:self.coverTitles current:self.coverIndex result:&newIndex]) {
            newIndex = MAX(0, MIN(n - 1, self.coverIndex + steps));
        }
        if (newIndex != self.coverIndex) {
            self.coverIndex = newIndex;
            [self click];
        }
        [self refreshScreen];
        return;
    }

    // Now Playing: the wheel does volume, scrubbing, rating or shuffle depending on the bottom bar
    if (self.nowPlayingActive) {
        IPScreenView *s = self.screenView;
        MPMediaItem *item = self.player.nowPlayingItem;
        switch (s.bottomMode) {
            case IPBottomModeScrub: {
                NSTimeInterval t = self.player.currentPlaybackTime + steps * 4.0;
                self.player.currentPlaybackTime = MAX(0, MIN(item.playbackDuration, t));
                break;
            }
            case IPBottomModeRating: {
                NSInteger r = MAX(0, MIN(5, [self ratingForItem:item] + steps));
                [self setRating:r forItem:item];
                break;
            }
            case IPBottomModeShuffle: {
                NSArray<NSNumber *> *modes = @[@(MPMusicShuffleModeOff), @(MPMusicShuffleModeSongs), @(MPMusicShuffleModeAlbums)];
                NSInteger idx = (NSInteger)[modes indexOfObject:@(self.shuffleSetting)];
                if (idx < 0 || idx > 2) idx = 0;
                idx = MAX(0, MIN(2, idx + steps));
                self.shuffleSetting = (MPMusicShuffleMode)[modes[idx] integerValue];
                if (self.player) self.player.shuffleMode = self.shuffleSetting;
                break;
            }
            default: {
                float current = (s.bottomMode == IPBottomModeVolume) ? s.volume : [AVAudioSession sharedInstance].outputVolume;
                float limit = [d floatForKey:kVolumeLimitKey];
                float v = MAX(0.0f, MIN(limit, current + steps / 16.0f));
                [self setSystemVolume:v];
                s.volume = v;
                s.bottomMode = IPBottomModeVolume;
                break;
            }
        }
        if (s.bottomMode == IPBottomModeVolume) [self scheduleBottomModeReset];
        [self updateNowPlaying];
        [s setNeedsDisplay];
        return;
    }

    // Menus
    IPMenu *m = self.stack.lastObject;
    NSInteger n = (NSInteger)m.items.count;
    NSInteger newIndex;
    NSArray<NSString *> *titles = [m.items valueForKey:@"title"];
    if (![self fastScrollBySteps:steps titles:titles current:m.selectedIndex result:&newIndex]) {
        newIndex = MAX(0, MIN(n - 1, m.selectedIndex + steps));
    }
    if (newIndex != m.selectedIndex) {
        m.selectedIndex = newIndex;
        [self click];
    }
    [self refreshScreen];
}

- (void)clickWheel:(ClickWheelView *)wheel didPressButton:(ClickWheelButton)button {
    [self wakeBacklight];
    [self click];
    switch (button) {
        case ClickWheelButtonMenu:
            if (self.sliderKind) {
                self.sliderKind = 0;
            } else if (self.coverFlowActive) {
                self.coverFlowActive = NO;
            } else if (self.nowPlayingActive) {
                self.nowPlayingActive = NO;
                self.screenView.bottomMode = IPBottomModeProgress;
            } else if (self.stack.count > 1) {
                IPMenu *popped = self.stack.lastObject;
                [self.stack removeLastObject];
                if (popped.returnsToCoverFlow && self.coverAlbums.count > 0) self.coverFlowActive = YES;
            }
            [self refreshScreen];
            break;

        case ClickWheelButtonCenter:
            if (self.sliderKind) {
                // nothing: Menu or Play/Pause leaves the slider
            } else if (self.coverFlowActive) {
                if (self.coverIndex >= 0 && self.coverIndex < (NSInteger)self.coverAlbums.count) {
                    MPMediaItemCollection *album = self.coverAlbums[self.coverIndex];
                    [self pushSongListWithTitle:album.representativeItem.albumTitle ?: @"Album" items:album.items];
                    self.stack.lastObject.returnsToCoverFlow = YES;
                }
            } else if (self.nowPlayingActive) {
                // Press Center repeatedly: scrubber, rating, shuffle, then back to the progress bar
                [self.bottomModeTimer invalidate];
                IPBottomMode next;
                switch (self.screenView.bottomMode) {
                    case IPBottomModeScrub:   next = IPBottomModeRating; break;
                    case IPBottomModeRating:  next = IPBottomModeShuffle; break;
                    case IPBottomModeShuffle: next = IPBottomModeProgress; break;
                    default:                  next = IPBottomModeScrub; break;
                }
                self.screenView.bottomMode = next;
            } else {
                IPMenu *m = self.stack.lastObject;
                if (m.selectedIndex < (NSInteger)m.items.count) {
                    IPMenuItem *item = m.items[m.selectedIndex];
                    if (item.action) item.action();
                }
            }
            break;

        case ClickWheelButtonNext:
            if (self.coverFlowActive) {
                self.coverIndex = MIN((NSInteger)self.coverAlbums.count - 1, self.coverIndex + 1);
                [self refreshScreen];
            } else {
                [self.player skipToNextItem];
            }
            break;

        case ClickWheelButtonPrevious:
            if (self.coverFlowActive) {
                self.coverIndex = MAX(0, self.coverIndex - 1);
                [self refreshScreen];
            } else if (CACurrentMediaTime() - self.lastPreviousPress < 1.5) {
                [self.player skipToPreviousItem];
                self.lastPreviousPress = 0;
            } else {
                [self.player skipToBeginning];
                self.lastPreviousPress = CACurrentMediaTime();
            }
            break;

        case ClickWheelButtonPlayPause: {
            if (self.sliderKind) {
                self.sliderKind = 0;
                [self refreshScreen];
            } else if (self.coverFlowActive) {
                if (self.coverIndex >= 0 && self.coverIndex < (NSInteger)self.coverAlbums.count) {
                    [self playItems:self.coverAlbums[self.coverIndex].items startIndex:0 shuffle:NO];
                    [self showNowPlaying];
                }
            } else {
                IPMenu *m = self.stack.lastObject;
                IPMenuItem *row = (!self.nowPlayingActive && m.selectedIndex < (NSInteger)m.items.count) ? m.items[m.selectedIndex] : nil;
                if (row.playAction) row.playAction(); else [self togglePlayPause];
            }
            break;
        }
    }
    [self updateNowPlaying];
    [self.screenView setNeedsDisplay];
}

- (void)clickWheel:(ClickWheelView *)wheel didHoldButton:(ClickWheelButton)button {
    switch (button) {
        case ClickWheelButtonMenu: // press and hold Menu: straight to the main menu
            [self click];
            self.nowPlayingActive = NO;
            self.coverFlowActive = NO;
            self.sliderKind = 0;
            self.screenView.bottomMode = IPBottomModeProgress;
            if (self.stack.count > 1) [self.stack removeObjectsInRange:NSMakeRange(1, self.stack.count - 1)];
            [self refreshScreen];
            break;
        case ClickWheelButtonNext:     [self startSeeking:1]; break;
        case ClickWheelButtonPrevious: [self startSeeking:-1]; break;
        case ClickWheelButtonCenter:
            if (self.nowPlayingActive) { [self click]; [self showNowPlayingOptions]; }
            break;
        default: break;
    }
}

- (void)clickWheel:(ClickWheelView *)wheel didEndHoldOfButton:(ClickWheelButton)button {
    [self stopSeeking];
}

@end
