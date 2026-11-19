#import <Foundation/Foundation.h>

typedef void (^IPAction)(void);

@interface IPMenuItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;   // right-aligned value, e.g. "On"
@property (nonatomic, assign) BOOL hasChildren; // draws a ">" chevron
@property (nonatomic, copy) IPAction action;
+ (instancetype)itemWithTitle:(NSString *)title hasChildren:(BOOL)hasChildren action:(IPAction)action;
+ (instancetype)itemWithTitle:(NSString *)title detail:(NSString *)detail action:(IPAction)action;
@end

typedef NSArray<IPMenuItem *> *(^IPBuilder)(void);

@interface IPMenu : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) IPBuilder builder;
@property (nonatomic, copy) NSArray<IPMenuItem *> *items;
@property (nonatomic, assign) NSInteger selectedIndex;
+ (instancetype)menuWithTitle:(NSString *)title builder:(IPBuilder)builder;
- (void)reload; // re-runs the builder, keeping the selection in range
@end
