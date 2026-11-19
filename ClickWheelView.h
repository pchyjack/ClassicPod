#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, ClickWheelButton) {
    ClickWheelButtonMenu,
    ClickWheelButtonNext,
    ClickWheelButtonPlayPause,
    ClickWheelButtonPrevious,
    ClickWheelButtonCenter
};

@class ClickWheelView;

@protocol ClickWheelDelegate <NSObject>
// Positive = clockwise, negative = counter-clockwise.
- (void)clickWheel:(ClickWheelView *)wheel didRotateBySteps:(NSInteger)steps;
- (void)clickWheel:(ClickWheelView *)wheel didPressButton:(ClickWheelButton)button;
// Press-and-hold (about 0.7 s). No didPressButton follows a hold.
- (void)clickWheel:(ClickWheelView *)wheel didHoldButton:(ClickWheelButton)button;
- (void)clickWheel:(ClickWheelView *)wheel didEndHoldOfButton:(ClickWheelButton)button;
@end

@interface ClickWheelView : UIView
@property (nonatomic, weak) id<ClickWheelDelegate> delegate;
@end
