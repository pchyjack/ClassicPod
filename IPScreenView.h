#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import "IPMenu.h"

typedef NS_ENUM(NSInteger, IPScreenMode) {
    IPScreenModeMenu,
    IPScreenModeNowPlaying
};

typedef NS_ENUM(NSInteger, IPBottomMode) {
    IPBottomModeProgress,
    IPBottomModeVolume,
    IPBottomModeScrub
};

// The LCD. Draws either a menu list or the Now Playing screen.
// Call -setNeedsDisplay after changing properties.
@interface IPScreenView : UIView
@property (nonatomic) IPScreenMode mode;
@property (nonatomic, copy) NSString *title;

// Menu mode
@property (nonatomic, copy) NSArray<IPMenuItem *> *items;
@property (nonatomic) NSInteger selectedIndex;

// Now Playing mode
@property (nonatomic, strong) MPMediaItem *nowPlayingItem;
@property (nonatomic) BOOL playing;
@property (nonatomic) NSTimeInterval elapsed;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSInteger queueIndex;   // -1 = unknown
@property (nonatomic) NSInteger queueCount;
@property (nonatomic) float volume;           // 0...1, shown in IPBottomModeVolume
@property (nonatomic) IPBottomMode bottomMode;
@end
