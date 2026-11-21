#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import "IPMenu.h"

typedef NS_ENUM(NSInteger, IPScreenMode) {
    IPScreenModeMenu,
    IPScreenModeNowPlaying,
    IPScreenModeCoverFlow,
    IPScreenModeSlider,
    IPScreenModeVideo
};

typedef NS_ENUM(NSInteger, IPBottomMode) {
    IPBottomModeProgress,
    IPBottomModeVolume,
    IPBottomModeScrub,
    IPBottomModeRating,
    IPBottomModeShuffle
};

typedef NS_ENUM(NSInteger, IPPreviewKind) {
    IPPreviewNone,
    IPPreviewArtwork,
    IPPreviewNowPlaying,
    IPPreviewSettings,
    IPPreviewShuffle
};

// The LCD. Draws either a menu list or the Now Playing screen.
// Call -setNeedsDisplay after changing properties.
@interface IPScreenView : UIView
@property (nonatomic) IPScreenMode mode;
@property (nonatomic, copy) NSString *title;

// Menu mode
@property (nonatomic, copy) NSArray<IPMenuItem *> *items;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic) IPPreviewKind previewKind;     // picture pane to the right of the list
@property (nonatomic, strong) UIImage *previewImage; // used by IPPreviewArtwork

// Now Playing mode
@property (nonatomic, strong) MPMediaItem *nowPlayingItem;
@property (nonatomic) BOOL playing;
@property (nonatomic) NSTimeInterval elapsed;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSInteger queueIndex;   // -1 = unknown
@property (nonatomic) NSInteger queueCount;
@property (nonatomic) float volume;           // 0...1, shown in IPBottomModeVolume
@property (nonatomic) IPBottomMode bottomMode;
@property (nonatomic) BOOL videoOverlay;   // title + progress bar over a playing video
@property (nonatomic) MPMusicShuffleMode shuffleMode; // shuffle icon on Now Playing
@property (nonatomic) MPMusicRepeatMode repeatMode;     // repeat / repeat-once icon
@property (nonatomic) NSInteger rating;                  // 0...5 stars

// Cover Flow mode
@property (nonatomic, strong) NSArray<MPMediaItemCollection *> *coverItems;
@property (nonatomic) NSInteger coverIndex;

// Slider mode (Brightness, Volume Limit)
@property (nonatomic) CGFloat sliderValue;   // 0...1
@property (nonatomic) CGFloat sliderMarker;  // 0...1, or < 0 for none
@property (nonatomic, copy) NSString *sliderCaption;

// Big letter shown while fast-scrolling a long list
@property (nonatomic, copy) NSString *overlayLetter;
@end
