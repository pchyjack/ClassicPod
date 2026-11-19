#import "IPMenu.h"

@implementation IPMenuItem

+ (instancetype)itemWithTitle:(NSString *)title hasChildren:(BOOL)hasChildren action:(IPAction)action {
    IPMenuItem *i = [IPMenuItem new];
    i.title = title ?: @"";
    i.hasChildren = hasChildren;
    i.action = action;
    return i;
}

+ (instancetype)itemWithTitle:(NSString *)title detail:(NSString *)detail action:(IPAction)action {
    IPMenuItem *i = [self itemWithTitle:title hasChildren:NO action:action];
    i.detail = detail;
    return i;
}

@end

@implementation IPMenu

+ (instancetype)menuWithTitle:(NSString *)title builder:(IPBuilder)builder {
    IPMenu *m = [IPMenu new];
    m.title = title;
    m.builder = builder;
    [m reload];
    return m;
}

- (void)reload {
    NSArray<IPMenuItem *> *items = self.builder ? self.builder() : @[];
    if (items.count == 0) {
        items = @[[IPMenuItem itemWithTitle:@"No Items" hasChildren:NO action:nil]];
    }
    self.items = items;
    if (self.selectedIndex >= (NSInteger)items.count) self.selectedIndex = (NSInteger)items.count - 1;
    if (self.selectedIndex < 0) self.selectedIndex = 0;
}

@end
