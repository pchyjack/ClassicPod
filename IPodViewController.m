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
// iOS sorts "The Beatles" under B, so skip a leading "The ", "A " or "An ".
static NSString *StripArticle(NSString *t) {
    for (NSString *prefix in @[@"the ", @"an ", @"a "]) {
        if (t.length > prefix.length &&
            [t compare:prefix options:NSCaseInsensitiveSearch range:NSMakeRange(0, prefix.length)] == NSOrderedSame) {
            return [t substringFromIndex:prefix.length];
        }
    }
    return t;
}

static NSString *LetterForTitle(NSString *title) {
    title = StripArticle(title ?: @"");
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
@property (nonatomic, strong) AVPlayer *avPlayer;                 // plays the songs' file URLs in-process
@property (nonatomic, copy) NSArray<MPMediaItem *> *queue;
@property (nonatomic, copy) NSArray<NSNumber *> *order;           // play order: indexes into queue
@property (nonatomic) NSInteger orderPos;
@property (nonatomic, strong) MPMediaItem *currentItem;
@property (nonatomic) BOOL isPlaying;
@property (nonatomic) BOOL hasQueue;
@property (nonatomic) BOOL seeking;
@property (nonatomic) NSTimeInterval seekTarget;
@property (nonatomic, strong) UIImage *libraryPreview;
@property (nonatomic) BOOL libraryPreviewTried;
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
@property (nonatomic) BOOL fastDisabled;                          // this list isn't alphabetical
@property (nonatomic, copy) NSArray<NSString *> *fastLetters;     // A...Z, then "#" (numbers and symbols last)
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *fastFirst;
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
    self.backgroundLayer.colors = @[(id)[UIColor colorWithWhite:0.995 alpha:1.0].CGColor,
                                    (id)[UIColor colorWithWhite:0.90 alpha:1.0].CGColor];
    [self.view.layer addSublayer:self.backgroundLayer];

    self.screenFrame = [UIView new];
    self.screenFrame.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    self.screenFrame.layer.cornerRadius = 6;
    self.screenFrame.layer.borderWidth = 1;
    self.screenFrame.layer.borderColor = [UIColor colorWithWhite:0.62 alpha:1.0].CGColor;
    [self.view addSubview:self.screenFrame];

    self.screenView = [IPScreenView new];
    self.screenView.layer.cornerRadius = 2;
    self.screenView.layer.masksToBounds = YES;
    [self.screenFrame addSubview:self.screenView];

    self.dimView = [UIView new];
    self.dimView.backgroundColor = [UIColor blackColor];
    self.dimView.alpha = 0;
    self.dimView.userInteractionEnabled = NO;
    self.dimView.layer.cornerRadius = 2;
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
    CGFloat screenW = frameW - 8;
    CGFloat screenH = round(screenW * 0.75);   // 4:3 LCD
    CGFloat frameH = screenH + 8;
    self.screenFrame.frame = CGRectMake(margin, safe.top + margin, frameW, frameH);
    self.screenView.frame = CGRectMake(4, 4, screenW, screenH);
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
                if ([self playItems:items startIndex:i shuffle:NO]) [self showNowPlaying];
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
        if ([self playItems:items startIndex:0 shuffle:NO]) [self showNowPlaying];
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
    MPMediaItem *item = self.currentItem;
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
                [self reshuffleQueue];
                [self reloadTopMenu];
            }],
            [IPMenuItem itemWithTitle:@"Repeat" detail:repeat action:^{
                if (rm == MPMusicRepeatModeAll)      self.repeatSetting = MPMusicRepeatModeOne;
                else if (rm == MPMusicRepeatModeOne) self.repeatSetting = MPMusicRepeatModeNone;
                else                                 self.repeatSetting = MPMusicRepeatModeAll;
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
    [self reshuffleQueue];
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

// Album art shown beside the main menu, as on the real iPod classic.
- (UIImage *)libraryPreviewImage {
    if (!self.libraryPreview && !self.libraryPreviewTried && [self libraryAuthorized]) {
        self.libraryPreviewTried = YES;
        NSArray<MPMediaItemCollection *> *albums = [MPMediaQuery albumsQuery].collections;
        NSInteger start = albums.count ? (NSInteger)arc4random_uniform((uint32_t)albums.count) : 0;
        for (NSInteger k = 0; k < MIN((NSInteger)albums.count, 40); k++) {
            MPMediaItemCollection *c = albums[(start + k) % albums.count];
            UIImage *img = [c.representativeItem.artwork imageWithSize:CGSizeMake(200, 200)];
            if (img) { self.libraryPreview = img; break; }
        }
    }
    return self.libraryPreview;
}

- (void)reloadAllMenus {
    self.libraryPreviewTried = NO;
    for (IPMenu *m in self.stack) [m reload];
    [self refreshScreen];
}

#pragma mark - Fast-forward / rewind (press and hold Next / Previous)

- (void)startSeeking:(NSInteger)direction {
    if (!self.currentItem) return;
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
    if (!self.currentItem) return;
    [self seekToTime:[self elapsedTime] + self.seekDirection * 8.0];
    [self updateNowPlaying];
    [self.screenView setNeedsDisplay];
}

#pragma mark - Playback (AVPlayer on each song's file URL; no dependence on the system music player)

- (void)shuffleArray:(NSMutableArray *)array {
    for (NSInteger i = (NSInteger)array.count - 1; i > 0; i--) {
        [array exchangeObjectAtIndex:i withObjectAtIndex:(NSInteger)arc4random_uniform((uint32_t)(i + 1))];
    }
}

// Builds the play order. Normal: the list as is. Shuffle Songs: random, chosen song first.
// Shuffle Albums: whole albums in random order, chosen song's album first.
- (void)buildOrderStartingAt:(NSInteger)start {
    NSInteger n = (NSInteger)self.queue.count;
    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:n];
    if (self.shuffleSetting == MPMusicShuffleModeSongs) {
        NSMutableArray<NSNumber *> *rest = [NSMutableArray array];
        for (NSInteger i = 0; i < n; i++) if (i != start) [rest addObject:@(i)];
        [self shuffleArray:rest];
        [order addObject:@(start)];
        [order addObjectsFromArray:rest];
        self.orderPos = 0;
    } else if (self.shuffleSetting == MPMusicShuffleModeAlbums) {
        NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *groups = [NSMutableDictionary dictionary];
        NSMutableArray<NSNumber *> *albumKeys = [NSMutableArray array];
        for (NSInteger i = 0; i < n; i++) {
            NSNumber *key = @(self.queue[i].albumPersistentID);
            if (!groups[key]) {
                groups[key] = [NSMutableArray array];
                [albumKeys addObject:key];
            }
            [groups[key] addObject:@(i)];
        }
        NSNumber *startKey = @(self.queue[start].albumPersistentID);
        NSMutableArray<NSNumber *> *others = [albumKeys mutableCopy];
        [others removeObject:startKey];
        [self shuffleArray:others];

        NSArray<NSNumber *> *first = groups[startKey];
        NSUInteger at = [first indexOfObject:@(start)];
        if (at == NSNotFound) at = 0;
        [order addObjectsFromArray:[first subarrayWithRange:NSMakeRange(at, first.count - at)]];
        [order addObjectsFromArray:[first subarrayWithRange:NSMakeRange(0, at)]];
        for (NSNumber *key in others) [order addObjectsFromArray:groups[key]];
        self.orderPos = 0;
    } else {
        for (NSInteger i = 0; i < n; i++) [order addObject:@(i)];
        self.orderPos = start;
    }
    self.order = order;
}

// Shuffle setting changed while playing: reorder the queue but keep the current song.
- (void)reshuffleQueue {
    if (self.queue.count == 0 || !self.currentItem || self.orderPos >= (NSInteger)self.order.count) return;
    [self buildOrderStartingAt:self.order[self.orderPos].integerValue];
    [self playbackStateChanged];
}

- (AVPlayer *)ensurePlayer {
    if (!self.avPlayer) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:nil];
        [session setActive:YES error:nil];
        self.avPlayer = [AVPlayer new];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(itemDidFinish:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [nc addObserver:self selector:@selector(itemDidFinish:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
        [nc addObserver:self selector:@selector(audioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];

        MPRemoteCommandCenter *rc = [MPRemoteCommandCenter sharedCommandCenter];
        [rc.playCommand addTarget:self action:@selector(remotePlay:)];
        [rc.pauseCommand addTarget:self action:@selector(remotePause:)];
        [rc.togglePlayPauseCommand addTarget:self action:@selector(remoteToggle:)];
        [rc.nextTrackCommand addTarget:self action:@selector(remoteNext:)];
        [rc.previousTrackCommand addTarget:self action:@selector(remotePrevious:)];
    }
    return self.avPlayer;
}

- (MPRemoteCommandHandlerStatus)remotePlay:(MPRemoteCommandEvent *)e {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.isPlaying) [self togglePlayPause]; });
    return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)remotePause:(MPRemoteCommandEvent *)e {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.isPlaying) [self togglePlayPause]; });
    return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)remoteToggle:(MPRemoteCommandEvent *)e {
    dispatch_async(dispatch_get_main_queue(), ^{ [self togglePlayPause]; });
    return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)remoteNext:(MPRemoteCommandEvent *)e {
    dispatch_async(dispatch_get_main_queue(), ^{ [self skipToNext]; });
    return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)remotePrevious:(MPRemoteCommandEvent *)e {
    dispatch_async(dispatch_get_main_queue(), ^{ [self skipToPrevious]; });
    return MPRemoteCommandHandlerStatusSuccess;
}

// Starts the song at `position` in the play order. Songs without a file URL (protected or
// not downloaded) are skipped in `direction`. Returns NO if nothing could be played.
- (BOOL)playPosition:(NSInteger)position direction:(NSInteger)direction {
    NSInteger n = (NSInteger)self.order.count;
    AVPlayer *player = [self ensurePlayer];
    for (NSInteger tries = 0; tries < n; tries++) {
        if (position < 0 || position >= n) {
            if (self.repeatSetting != MPMusicRepeatModeAll) return NO;
            position = ((position % n) + n) % n;
        }
        MPMediaItem *item = self.queue[self.order[position].integerValue];
        NSURL *url = item.assetURL;
        if (url) {
            self.seeking = NO;
            [player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:url]];
            [player play];
            self.orderPos = position;
            self.currentItem = item;
            self.isPlaying = YES;
            self.hasQueue = YES;
            [self updateNowPlayingInfo];
            [self playbackStateChanged];
            return YES;
        }
        position += direction;
    }
    return NO;
}

- (BOOL)playItems:(NSArray<MPMediaItem *> *)items startIndex:(NSUInteger)index shuffle:(BOOL)shuffle {
    if (index >= items.count) return NO;
    if (shuffle) self.shuffleSetting = MPMusicShuffleModeSongs;

    NSArray<MPMediaItem *> *oldQueue = self.queue;
    NSArray<NSNumber *> *oldOrder = self.order;
    NSInteger oldPos = self.orderPos;

    self.queue = items;
    [self buildOrderStartingAt:(NSInteger)index];
    if ([self playPosition:self.orderPos direction:1]) return YES;

    self.queue = oldQueue;      // keep whatever was playing
    self.order = oldOrder;
    self.orderPos = oldPos;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Can\u2019t Play Song"
        message:@"This song is protected or isn\u2019t downloaded to this device."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return NO;
}

- (void)shuffleAllSongs {
    NSArray<MPMediaItem *> *songs = [MPMediaQuery songsQuery].items;
    if (songs.count == 0) return;
    if ([self playItems:songs startIndex:arc4random_uniform((uint32_t)songs.count) shuffle:YES]) [self showNowPlaying];
}

- (NSTimeInterval)elapsedTime {
    if (self.seeking) return self.seekTarget;
    if (!self.avPlayer.currentItem) return 0;
    double t = CMTimeGetSeconds(self.avPlayer.currentTime);
    return (isnan(t) || t < 0) ? 0 : t;
}

- (void)seekToTime:(NSTimeInterval)time {
    if (!self.avPlayer.currentItem) return;
    NSTimeInterval duration = self.currentItem.playbackDuration;
    time = MAX(0, MIN(duration > 1 ? duration - 0.5 : duration, time));
    self.seeking = YES;
    self.seekTarget = time;
    [self.avPlayer seekToTime:CMTimeMakeWithSeconds(time, 600) completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (fabs(self.seekTarget - time) < 0.001) self.seeking = NO;   // only the latest seek clears it
        });
    }];
    [self updateNowPlayingInfo];
}

- (void)togglePlayPause {
    if (!self.avPlayer || !self.currentItem) return;
    if (self.isPlaying) {
        [self.avPlayer pause];
        self.isPlaying = NO;
    } else {
        if (self.currentItem.playbackDuration > 1 && [self elapsedTime] >= self.currentItem.playbackDuration - 0.5) {
            [self seekToTime:0];   // the queue had finished: start this song again
        }
        [self.avPlayer play];
        self.isPlaying = YES;
    }
    [self updateNowPlayingInfo];
    [self playbackStateChanged];
}

- (void)skipToNext {
    if (!self.currentItem) return;
    [self playPosition:self.orderPos + 1 direction:1];
}

- (void)skipToPrevious {
    if (!self.currentItem) return;
    if (self.orderPos > 0 || self.repeatSetting == MPMusicRepeatModeAll) {
        [self playPosition:self.orderPos - 1 direction:-1];
    } else {
        [self seekToTime:0];
    }
}

- (void)itemDidFinish:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (note.object != self.avPlayer.currentItem) return;
        BOOL failed = [note.name isEqualToString:AVPlayerItemFailedToPlayToEndTimeNotification];
        if (self.repeatSetting == MPMusicRepeatModeOne && !failed) {
            [self seekToTime:0];
            [self.avPlayer play];
            self.isPlaying = YES;
            [self updateNowPlayingInfo];
            return;
        }
        if (![self playPosition:self.orderPos + 1 direction:1]) {   // end of the queue
            self.isPlaying = NO;
            [self updateNowPlayingInfo];
            [self playbackStateChanged];
        }
    });
}

- (void)audioInterrupted:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (type == AVAudioSessionInterruptionTypeBegan) {
            self.isPlaying = NO;
        } else if ((options & AVAudioSessionInterruptionOptionShouldResume) && self.currentItem) {
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            [self.avPlayer play];
            self.isPlaying = YES;
        }
        [self updateNowPlayingInfo];
        [self playbackStateChanged];
    });
}

// Lock screen / Control Center
- (void)updateNowPlayingInfo {
    MPMediaItem *item = self.currentItem;
    if (!item) {
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
        return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = item.title ?: @"";
    info[MPMediaItemPropertyArtist] = item.artist ?: @"";
    info[MPMediaItemPropertyAlbumTitle] = item.albumTitle ?: @"";
    info[MPMediaItemPropertyPlaybackDuration] = @(item.playbackDuration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @([self elapsedTime]);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.isPlaying ? 1.0 : 0.0);
    if (item.artwork) info[MPMediaItemPropertyArtwork] = item.artwork;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (void)showNowPlaying {
    if (!self.currentItem) return;
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
    s.previewKind = IPPreviewNone;
    if (s.mode == IPScreenModeMenu && (self.stack.count == 1 || [m.title isEqualToString:@"Music"])) {
        IPMenuItem *sel = (m.selectedIndex < (NSInteger)m.items.count) ? m.items[m.selectedIndex] : nil;
        if ([sel.title isEqualToString:@"Settings"])           s.previewKind = IPPreviewSettings;
        else if ([sel.title isEqualToString:@"Shuffle Songs"]) s.previewKind = IPPreviewShuffle;
        else if ([sel.title isEqualToString:@"Now Playing"])   s.previewKind = IPPreviewNowPlaying;
        else { s.previewKind = IPPreviewArtwork; s.previewImage = [self libraryPreviewImage]; }
    }
    s.items = m.items;
    s.selectedIndex = m.selectedIndex;
    [self updateNowPlaying];
    [s setNeedsDisplay];
}

- (void)updateNowPlaying {
    IPScreenView *s = self.screenView;
    MPMediaItem *item = self.currentItem;
    s.shuffleMode = self.shuffleSetting;
    s.repeatMode = self.repeatSetting;
    s.nowPlayingItem = item;
    s.rating = [self ratingForItem:item];
    s.elapsed = [self elapsedTime];
    s.duration = item.playbackDuration;
    s.playing = self.isPlaying;
    s.queueIndex = item ? self.orderPos : -1;
    s.queueCount = (NSInteger)self.order.count;
}

- (void)tick {
    if (!self.avPlayer) return;
    [self updateNowPlaying];
    [self.screenView setNeedsDisplay];
}

- (void)playbackStateChanged {
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

// Builds the letter index. Returns NO if the list isn't in alphabetical order (e.g. album tracks),
// so fast scrolling is only offered where letters make sense.
- (BOOL)buildFastScrollIndexForTitles:(NSArray<NSString *> *)titles {
    NSMutableArray<NSString *> *letters = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *first = [NSMutableDictionary dictionary];
    NSInteger breaks = 0;
    NSString *previous = nil;
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSString *L = LetterForTitle(titles[i]);
        if (![L isEqualToString:previous] && first[L]) breaks++;   // a letter we've already left
        if (!first[L]) {
            first[L] = @(i);
            [letters addObject:L];
        }
        previous = L;
    }
    if (breaks > (NSInteger)titles.count / 4) return NO;

    [letters sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {   // "#" goes last
        if ([a isEqualToString:@"#"]) return [b isEqualToString:@"#"] ? NSOrderedSame : NSOrderedDescending;
        if ([b isEqualToString:@"#"]) return NSOrderedAscending;
        return [a compare:b];
    }];
    self.fastLetters = letters;
    self.fastFirst = first;
    return YES;
}

// Moving the thumb quickly on a long list (or Cover Flow) jumps by letter, as on the real iPod.
// Returns YES (and sets *result) while fast scrolling is active.
- (BOOL)fastScrollBySteps:(NSInteger)steps titles:(NSArray<NSString *> *)titles current:(NSInteger)current result:(NSInteger *)result {
    if (titles.count < 30 || self.fastDisabled) return NO;

    CFTimeInterval now = CACurrentMediaTime();
    for (NSInteger i = 0; i < labs(steps); i++) [self.stepTimes addObject:@(now)];
    while (self.stepTimes.count > 0 && now - [self.stepTimes.firstObject doubleValue] > 0.4) {
        [self.stepTimes removeObjectAtIndex:0];
    }
    if (!self.fastScrolling && self.stepTimes.count >= 5) {
        if ([self buildFastScrollIndexForTitles:titles]) {
            self.fastScrolling = YES;
        } else {
            self.fastDisabled = YES;
            [self.stepTimes removeAllObjects];
            return NO;
        }
    }
    if (!self.fastScrolling) return NO;

    NSArray<NSString *> *letters = self.fastLetters;
    NSInteger li = [letters indexOfObject:LetterForTitle(titles[MAX(0, MIN((NSInteger)titles.count - 1, current))])];
    if (li == NSNotFound) li = 0;
    li = MAX(0, MIN((NSInteger)letters.count - 1, li + steps));
    NSString *letter = letters[li];
    *result = self.fastFirst[letter].integerValue;
    self.screenView.overlayLetter = letter;
    return YES;
}

#pragma mark - ClickWheelDelegate

- (void)clickWheelDidBeginTouch:(ClickWheelView *)wheel {
    [self wakeBacklight];
}

- (void)clickWheelDidEndTouch:(ClickWheelView *)wheel {
    [self.stepTimes removeAllObjects];
    self.fastDisabled = NO;
    self.fastLetters = nil;
    self.fastFirst = nil;
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
        MPMediaItem *item = self.currentItem;
        switch (s.bottomMode) {
            case IPBottomModeScrub: {
                [self seekToTime:[self elapsedTime] + steps * 4.0];
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
                [self reshuffleQueue];
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
                [self skipToNext];
            }
            break;

        case ClickWheelButtonPrevious:
            if (self.coverFlowActive) {
                self.coverIndex = MAX(0, self.coverIndex - 1);
                [self refreshScreen];
            } else if (CACurrentMediaTime() - self.lastPreviousPress < 1.5) {
                [self skipToPrevious];
                self.lastPreviousPress = 0;
            } else {
                [self seekToTime:0];
                self.lastPreviousPress = CACurrentMediaTime();
            }
            break;

        case ClickWheelButtonPlayPause: {
            if (self.sliderKind) {
                self.sliderKind = 0;
                [self refreshScreen];
            } else if (self.coverFlowActive) {
                if (self.coverIndex >= 0 && self.coverIndex < (NSInteger)self.coverAlbums.count) {
                    if ([self playItems:self.coverAlbums[self.coverIndex].items startIndex:0 shuffle:NO]) [self showNowPlaying];
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
