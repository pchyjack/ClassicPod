#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

// Cover Flow drawn with Core Animation layers: real perspective, shaded side covers and
// reflections, animated smoothly on the GPU.
@interface IPCoverFlowView : UIView
@property (nonatomic, copy) NSArray<MPMediaItemCollection *> *albums;
@property (nonatomic) NSInteger index;                 // selected album; changing it animates
@property (nonatomic, copy) NSString *overlayLetter;   // big letter while fast-scrolling
- (void)snapToIndex:(NSInteger)index;                  // jump without animating
@end
