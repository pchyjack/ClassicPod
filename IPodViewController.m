#import "IPodViewController.h"
#import "ClickWheelView.h"
#import "IPScreenView.h"
#import "IPMenu.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

static NSString *const kClickerKey = @"ClickerEnabled";

@interface IPodViewController () <ClickWheelDelegate>
@property (nonatomic, strong) CAGradientLayer *backgroundLayer;
@property (nonatomic, strong) UIView *screenFrame;
@property (nonatomic, strong) IPScreenView *screenView;
@property (nonatomic, strong) ClickWheelView *wheel;
@property (nonatomic, strong) MPVolumeView *volumeView;
@property (nonatomic, strong) MPMusicPlayerController *player;
@property (nonatomic, strong) NSMutableArray<IPMenu *> *stack;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, strong) NSTimer *bottomModeTimer;
@property (nonatomic) BOOL nowPlayingActive;
@property (nonatomic) NSInteger queueCount;
@end

@implementation IPodViewController

#pragma mark - Lifecycle

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

- (void)viewDidLoad {
    [super viewDidLoad];

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kClickerKey: @YES}];
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

    self.wheel = [ClickWheelView new];
    self.wheel.delegate = self;
    [self.view addSubview:self.wheel];

    // Hidden volume view: lets the wheel change the system volume.
    self.volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 200, 40)];
    [self.view addSubview:self.volumeView];

    // Audio
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:nil];

    self.player = [MPMusicPlayerController applicationMusicPlayer];
    [self.player beginGeneratingPlaybackNotifications];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(playerChanged)
               name:MPMusicPlayerControllerNowPlayingItemDidChangeNotification object:self.player];
    [nc addObserver:self selector:@selector(playerChanged)
               name:MPMusicPlayerControllerPlaybackStateDidChangeNotification object:self.player];
    [nc addObserver:self selector:@selector(batteryChanged)
               name:UIDeviceBatteryLevelDidChangeNotification object:nil];

    // Menus
    self.stack = [NSMutableArray array];
    [self.stack addObject:[self makeRootMenu]];
    [self refreshScreen];

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
        NSMutableArray *a = [NSMutableArray array];
        [a addObject:[IPMenuItem itemWithTitle:@"Music" hasChildren:YES action:^{ [self pushMusicMenu]; }]];
        if (self.player.nowPlayingItem) {
            [a addObject:[IPMenuItem itemWithTitle:@"Now Playing" hasChildren:YES action:^{ [self showNowPlaying]; }]];
        }
        [a addObject:[IPMenuItem itemWithTitle:@"Shuffle Songs" hasChildren:NO action:^{ [self shuffleAllSongs]; }]];
        [a addObject:[IPMenuItem itemWithTitle:@"Settings" hasChildren:YES action:^{ [self pushSettingsMenu]; }]];
        return a;
    }];
}

- (void)pushMenuWithTitle:(NSString *)title builder:(IPBuilder)builder {
    [self.stack addObject:[IPMenu menuWithTitle:title builder:builder]];
    [self refreshScreen];
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
        return @[
            [IPMenuItem itemWithTitle:@"Playlists" hasChildren:YES action:^{ [self pushPlaylistsMenu]; }],
            [IPMenuItem itemWithTitle:@"Artists" hasChildren:YES action:^{ [self pushArtistsMenu]; }],
            [IPMenuItem itemWithTitle:@"Albums" hasChildren:YES action:^{ [self pushAlbumsMenu]; }],
            [IPMenuItem itemWithTitle:@"Songs" hasChildren:YES action:^{
                [self pushSongListWithTitle:@"Songs" items:[MPMediaQuery songsQuery].items];
            }],
        ];
    }];
}

- (void)pushPlaylistsMenu {
    [self pushMenuWithTitle:@"Playlists" builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray array];
        for (MPMediaItemCollection *c in [MPMediaQuery playlistsQuery].collections) {
            NSString *name = [c valueForProperty:MPMediaPlaylistPropertyName] ?: @"Playlist";
            [r addObject:[IPMenuItem itemWithTitle:name hasChildren:YES action:^{
                [self pushSongListWithTitle:name items:c.items];
            }]];
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
            [r addObject:[IPMenuItem itemWithTitle:album hasChildren:YES action:^{
                [self pushSongListWithTitle:album items:c.items];
            }]];
        }
        return r;
    }];
}

- (void)pushAlbumsMenu {
    [self pushMenuWithTitle:@"Albums" builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray array];
        for (MPMediaItemCollection *c in [MPMediaQuery albumsQuery].collections) {
            NSString *album = c.representativeItem.albumTitle ?: @"Unknown Album";
            [r addObject:[IPMenuItem itemWithTitle:album hasChildren:YES action:^{
                [self pushSongListWithTitle:album items:c.items];
            }]];
        }
        return r;
    }];
}

- (void)pushSongListWithTitle:(NSString *)title items:(NSArray<MPMediaItem *> *)items {
    [self pushMenuWithTitle:title builder:^NSArray<IPMenuItem *> *{
        NSMutableArray *r = [NSMutableArray arrayWithCapacity:items.count];
        [items enumerateObjectsUsingBlock:^(MPMediaItem *song, NSUInteger i, BOOL *stop) {
            [r addObject:[IPMenuItem itemWithTitle:song.title ?: @"Unknown Song" hasChildren:NO action:^{
                [self playItems:items startIndex:i shuffle:NO];
                [self showNowPlaying];
            }]];
        }];
        return r;
    }];
}

- (void)pushSettingsMenu {
    [self pushMenuWithTitle:@"Settings" builder:^NSArray<IPMenuItem *> *{
        BOOL clicker = [[NSUserDefaults standardUserDefaults] boolForKey:kClickerKey];
        NSString *shuffle = (self.player.shuffleMode == MPMusicShuffleModeOff ||
                             self.player.shuffleMode == MPMusicShuffleModeDefault) ? @"Off" : @"Songs";
        MPMusicRepeatMode rm = self.player.repeatMode;
        NSString *repeat = (rm == MPMusicRepeatModeAll) ? @"All" : (rm == MPMusicRepeatModeOne ? @"One" : @"Off");

        return @[
            [IPMenuItem itemWithTitle:@"Shuffle" detail:shuffle action:^{
                BOOL on = ![shuffle isEqualToString:@"Off"];
                self.player.shuffleMode = on ? MPMusicShuffleModeOff : MPMusicShuffleModeSongs;
                [self reloadTopMenu];
            }],
            [IPMenuItem itemWithTitle:@"Repeat" detail:repeat action:^{
                if (rm == MPMusicRepeatModeAll)      self.player.repeatMode = MPMusicRepeatModeOne;
                else if (rm == MPMusicRepeatModeOne) self.player.repeatMode = MPMusicRepeatModeNone;
                else                                 self.player.repeatMode = MPMusicRepeatModeAll;
                [self reloadTopMenu];
            }],
            [IPMenuItem itemWithTitle:@"Clicker" detail:(clicker ? @"On" : @"Off") action:^{
                [[NSUserDefaults standardUserDefaults] setBool:!clicker forKey:kClickerKey];
                [self reloadTopMenu];
            }],
        ];
    }];
}

- (void)reloadTopMenu {
    [self.stack.lastObject reload];
    [self refreshScreen];
}

- (void)reloadAllMenus {
    for (IPMenu *m in self.stack) [m reload];
    [self refreshScreen];
}

#pragma mark - Playback

- (void)playItems:(NSArray<MPMediaItem *> *)items startIndex:(NSUInteger)index shuffle:(BOOL)shuffle {
    if (index >= items.count) return;
    self.queueCount = (NSInteger)items.count;
    [self.player setQueueWithItemCollection:[MPMediaItemCollection collectionWithItems:items]];
    if (shuffle) self.player.shuffleMode = MPMusicShuffleModeSongs;
    self.player.nowPlayingItem = items[index];
    [self.player play];
}

- (void)shuffleAllSongs {
    NSArray<MPMediaItem *> *songs = [MPMediaQuery songsQuery].items;
    if (songs.count == 0) return;
    [self playItems:songs startIndex:arc4random_uniform((uint32_t)songs.count) shuffle:YES];
    [self showNowPlaying];
}

- (void)togglePlayPause {
    if (self.player.playbackState == MPMusicPlaybackStatePlaying) {
        [self.player pause];
    } else if (self.player.nowPlayingItem) {
        [self.player play];
    }
}

- (void)showNowPlaying {
    self.nowPlayingActive = YES;
    self.screenView.bottomMode = IPBottomModeProgress;
    [self updateNowPlaying];
    [self refreshScreen];
}

#pragma mark - Screen updates

- (void)refreshScreen {
    IPMenu *m = self.stack.lastObject;
    self.screenView.mode = self.nowPlayingActive ? IPScreenModeNowPlaying : IPScreenModeMenu;
    self.screenView.title = self.nowPlayingActive ? @"Now Playing" : m.title;
    self.screenView.items = m.items;
    self.screenView.selectedIndex = m.selectedIndex;
    [self updateNowPlaying];
    [self.screenView setNeedsDisplay];
}

- (void)updateNowPlaying {
    IPScreenView *s = self.screenView;
    MPMediaItem *item = self.player.nowPlayingItem;
    s.nowPlayingItem = item;
    NSTimeInterval t = self.player.currentPlaybackTime;
    s.elapsed = (isnan(t) || t < 0) ? 0 : t;
    s.duration = item.playbackDuration;
    s.playing = (self.player.playbackState == MPMusicPlaybackStatePlaying);
    NSUInteger idx = self.player.indexOfNowPlayingItem;
    s.queueIndex = (idx == NSNotFound) ? -1 : (NSInteger)idx;
    s.queueCount = self.queueCount;
}

- (void)tick {
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

#pragma mark - ClickWheelDelegate

- (void)clickWheel:(ClickWheelView *)wheel didRotateBySteps:(NSInteger)steps {
    if (self.nowPlayingActive) {
        if (self.screenView.bottomMode == IPBottomModeScrub) {
            NSTimeInterval duration = self.player.nowPlayingItem.playbackDuration;
            NSTimeInterval t = self.player.currentPlaybackTime + steps * 4.0;
            self.player.currentPlaybackTime = MAX(0, MIN(duration, t));
        } else {
            float current = (self.screenView.bottomMode == IPBottomModeVolume)
                ? self.screenView.volume
                : [AVAudioSession sharedInstance].outputVolume;
            float v = MAX(0.0f, MIN(1.0f, current + steps / 16.0f));
            [self setSystemVolume:v];
            self.screenView.volume = v;
            self.screenView.bottomMode = IPBottomModeVolume;
        }
        [self scheduleBottomModeReset];
        [self updateNowPlaying];
        [self.screenView setNeedsDisplay];
        return;
    }

    IPMenu *m = self.stack.lastObject;
    NSInteger n = (NSInteger)m.items.count;
    NSInteger newIndex = MAX(0, MIN(n - 1, m.selectedIndex + steps));
    if (newIndex != m.selectedIndex) {
        m.selectedIndex = newIndex;
        [self click];
        [self refreshScreen];
    }
}

- (void)clickWheel:(ClickWheelView *)wheel didPressButton:(ClickWheelButton)button {
    [self click];
    switch (button) {
        case ClickWheelButtonMenu:
            if (self.nowPlayingActive) {
                self.nowPlayingActive = NO;
            } else if (self.stack.count > 1) {
                [self.stack removeLastObject];
            }
            [self refreshScreen];
            break;

        case ClickWheelButtonCenter:
            if (self.nowPlayingActive) {
                self.screenView.bottomMode = IPBottomModeScrub;
                [self scheduleBottomModeReset];
                [self.screenView setNeedsDisplay];
            } else {
                IPMenu *m = self.stack.lastObject;
                if (m.selectedIndex < (NSInteger)m.items.count) {
                    IPMenuItem *item = m.items[m.selectedIndex];
                    if (item.action) item.action();
                }
            }
            break;

        case ClickWheelButtonNext:
            [self.player skipToNextItem];
            break;

        case ClickWheelButtonPrevious:
            if (self.player.currentPlaybackTime > 3.0) [self.player skipToBeginning];
            else [self.player skipToPreviousItem];
            break;

        case ClickWheelButtonPlayPause:
            [self togglePlayPause];
            break;
    }
    [self updateNowPlaying];
    [self.screenView setNeedsDisplay];
}

@end
