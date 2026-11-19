#import "IPScreenView.h"

static const NSInteger kVisibleRows = 8;

static NSString *TimeString(NSTimeInterval t) {
    NSInteger s = (NSInteger)MAX(0, t);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(s / 60), (long)(s % 60)];
}

@interface IPScreenView ()
@property (nonatomic) NSInteger topIndex;
@property (nonatomic, strong) UIImage *artworkImage;
@property (nonatomic) MPMediaEntityPersistentID artworkID;
@property (nonatomic) BOOL hasArtworkID;
@end

@implementation IPScreenView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor whiteColor];
        self.opaque = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.queueIndex = -1;
    }
    return self;
}

- (void)setNowPlayingItem:(MPMediaItem *)item {
    if (!item) {
        _nowPlayingItem = nil;
        self.artworkImage = nil;
        self.hasArtworkID = NO;
        return;
    }
    if (self.hasArtworkID && item.persistentID == self.artworkID) {
        _nowPlayingItem = item;
        return;
    }
    _nowPlayingItem = item;
    self.artworkID = item.persistentID;
    self.hasArtworkID = YES;
    self.artworkImage = [item.artwork imageWithSize:CGSizeMake(160, 160)];
}

#pragma mark - Helpers

- (void)drawText:(NSString *)text inRect:(CGRect)rect font:(UIFont *)font color:(UIColor *)color align:(NSTextAlignment)align {
    if (text.length == 0) return;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = align;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{NSFontAttributeName: font,
                            NSForegroundColorAttributeName: color,
                            NSParagraphStyleAttributeName: ps};
    CGFloat h = ceil(font.lineHeight);
    CGRect r = CGRectMake(rect.origin.x, rect.origin.y + (rect.size.height - h) / 2.0, rect.size.width, h);
    [text drawInRect:r withAttributes:attrs];
}

- (void)fillGradientInRect:(CGRect)r top:(const CGFloat *)top bottom:(const CGFloat *)bottom ctx:(CGContextRef)ctx {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8] = {top[0], top[1], top[2], 1.0, bottom[0], bottom[1], bottom[2], 1.0};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, r);
    CGContextDrawLinearGradient(ctx, g, r.origin, CGPointMake(r.origin.x, CGRectGetMaxY(r)), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    [[UIColor whiteColor] setFill];
    UIRectFill(b);

    CGFloat titleH = round(b.size.height / (kVisibleRows + 1));
    [self drawTitleBarInRect:CGRectMake(0, 0, b.size.width, titleH) ctx:ctx];

    CGRect body = CGRectMake(0, titleH, b.size.width, b.size.height - titleH);
    if (self.mode == IPScreenModeMenu) {
        [self drawMenuInRect:body ctx:ctx];
    } else {
        [self drawNowPlayingInRect:body ctx:ctx];
    }
}

- (void)drawTitleBarInRect:(CGRect)r ctx:(CGContextRef)ctx {
    const CGFloat top[3] = {0.97, 0.97, 0.98};
    const CGFloat bottom[3] = {0.72, 0.74, 0.77};
    [self fillGradientInRect:r top:top bottom:bottom ctx:ctx];
    [[UIColor colorWithWhite:0.45 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, CGRectGetMaxY(r) - 1, r.size.width, 1));

    UIFont *font = [UIFont systemFontOfSize:r.size.height * 0.56 weight:UIFontWeightBold];
    [self drawText:self.title inRect:CGRectMake(40, r.origin.y, r.size.width - 80, r.size.height)
              font:font color:[UIColor blackColor] align:NSTextAlignmentCenter];

    CGFloat cy = CGRectGetMidY(r);
    [[UIColor colorWithWhite:0.15 alpha:1.0] setFill];
    if (self.playing) {
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:CGPointMake(10, cy - 5)];
        [tri addLineToPoint:CGPointMake(18, cy)];
        [tri addLineToPoint:CGPointMake(10, cy + 5)];
        [tri closePath];
        [tri fill];
    } else if (self.nowPlayingItem) {
        UIRectFill(CGRectMake(10, cy - 5, 3, 10));
        UIRectFill(CGRectMake(16, cy - 5, 3, 10));
    }

    float level = [UIDevice currentDevice].batteryLevel;
    if (level < 0) level = 1.0f;
    CGRect bat = CGRectMake(r.size.width - 34, cy - 5, 24, 10);
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:bat cornerRadius:2];
    bp.lineWidth = 1.0;
    [[UIColor colorWithWhite:0.2 alpha:1.0] setStroke];
    [bp stroke];
    [[UIColor colorWithWhite:0.2 alpha:1.0] setFill];
    UIRectFill(CGRectMake(CGRectGetMaxX(bat), cy - 2, 2, 4));
    CGRect fill = CGRectInset(bat, 2, 2);
    fill.size.width *= level;
    [(level < 0.2f ? [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1] : [UIColor colorWithRed:0.25 green:0.7 blue:0.3 alpha:1]) setFill];
    UIRectFill(fill);
}

- (void)drawMenuInRect:(CGRect)body ctx:(CGContextRef)ctx {
    NSInteger n = (NSInteger)self.items.count;
    CGFloat rowH = body.size.height / kVisibleRows;
    NSInteger sel = MAX(0, MIN(n - 1, self.selectedIndex));

    if (sel < self.topIndex) self.topIndex = sel;
    if (sel >= self.topIndex + kVisibleRows) self.topIndex = sel - kVisibleRows + 1;
    self.topIndex = MAX(0, MIN(self.topIndex, MAX(0, n - kVisibleRows)));

    BOOL needsScrollBar = n > kVisibleRows;
    CGFloat rightEdge = body.size.width - (needsScrollBar ? 12 : 0);
    UIFont *font = [UIFont systemFontOfSize:rowH * 0.60 weight:UIFontWeightSemibold];

    for (NSInteger i = 0; i < kVisibleRows; i++) {
        NSInteger idx = self.topIndex + i;
        if (idx >= n) break;
        IPMenuItem *item = self.items[idx];
        CGRect row = CGRectMake(0, body.origin.y + i * rowH, rightEdge, rowH);
        BOOL selected = (idx == sel);
        UIColor *textColor = [UIColor blackColor];

        if (selected) {
            const CGFloat top[3] = {0.30, 0.58, 0.95};
            const CGFloat bottom[3] = {0.10, 0.36, 0.78};
            [self fillGradientInRect:row top:top bottom:bottom ctx:ctx];
            textColor = [UIColor whiteColor];
        }

        CGFloat trailing = 10;
        if (item.hasChildren) {
            CGFloat cx = rightEdge - 14, cy = CGRectGetMidY(row);
            UIBezierPath *chevron = [UIBezierPath bezierPath];
            [chevron moveToPoint:CGPointMake(cx, cy - 5)];
            [chevron addLineToPoint:CGPointMake(cx + 5, cy)];
            [chevron addLineToPoint:CGPointMake(cx, cy + 5)];
            chevron.lineWidth = 2.0;
            chevron.lineCapStyle = kCGLineCapRound;
            chevron.lineJoinStyle = kCGLineJoinRound;
            [textColor setStroke];
            [chevron stroke];
            trailing = 24;
        }

        CGFloat titleWidth = rightEdge - 10 - trailing;
        if (item.detail.length) {
            titleWidth = rightEdge * 0.55 - 10;
            [self drawText:item.detail
                    inRect:CGRectMake(rightEdge * 0.55, row.origin.y, rightEdge * 0.45 - 10, rowH)
                      font:font color:textColor align:NSTextAlignmentRight];
        }
        [self drawText:item.title inRect:CGRectMake(10, row.origin.y, titleWidth, rowH)
                  font:font color:textColor align:NSTextAlignmentLeft];
    }

    if (needsScrollBar) {
        CGRect track = CGRectMake(body.size.width - 10, body.origin.y + 2, 6, body.size.height - 4);
        UIBezierPath *tp = [UIBezierPath bezierPathWithRoundedRect:track cornerRadius:3];
        [[UIColor colorWithWhite:0.90 alpha:1.0] setFill];
        [tp fill];
        [[UIColor colorWithWhite:0.70 alpha:1.0] setStroke];
        tp.lineWidth = 0.5;
        [tp stroke];

        CGFloat thumbH = MAX(14.0, track.size.height * kVisibleRows / n);
        CGFloat frac = (CGFloat)self.topIndex / (CGFloat)(n - kVisibleRows);
        CGRect thumb = CGRectMake(track.origin.x, track.origin.y + (track.size.height - thumbH) * frac, track.size.width, thumbH);
        UIBezierPath *thp = [UIBezierPath bezierPathWithRoundedRect:thumb cornerRadius:3];
        [[UIColor colorWithWhite:0.45 alpha:1.0] setFill];
        [thp fill];
    }
}

- (void)drawNowPlayingInRect:(CGRect)body ctx:(CGContextRef)ctx {
    CGFloat w = body.size.width;
    CGFloat pad = 10;
    MPMediaItem *item = self.nowPlayingItem;

    if (!item) {
        [self drawText:@"Nothing Playing" inRect:body
                  font:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]
                 color:[UIColor grayColor] align:NSTextAlignmentCenter];
        return;
    }

    CGFloat lh = body.size.height / 9.0;

    if (self.queueIndex >= 0 && self.queueCount > 0 && self.queueIndex < self.queueCount) {
        NSString *pos = [NSString stringWithFormat:@"%ld of %ld", (long)self.queueIndex + 1, (long)self.queueCount];
        [self drawText:pos inRect:CGRectMake(0, body.origin.y + 2, w, lh)
                  font:[UIFont systemFontOfSize:lh * 0.62 weight:UIFontWeightMedium]
                 color:[UIColor colorWithWhite:0.4 alpha:1.0] align:NSTextAlignmentCenter];
    }

    // Shuffle / repeat icons, top right
    NSString *flags = @"";
    if (self.shuffleMode == MPMusicShuffleModeSongs || self.shuffleMode == MPMusicShuffleModeAlbums) flags = @"\u21C4";
    if (self.repeatMode == MPMusicRepeatModeAll) flags = [flags stringByAppendingString:@" \u21BB"];
    else if (self.repeatMode == MPMusicRepeatModeOne) flags = [flags stringByAppendingString:@" \u21BB1"];
    [self drawText:flags inRect:CGRectMake(0, body.origin.y + 2, w - pad, lh)
              font:[UIFont systemFontOfSize:lh * 0.70 weight:UIFontWeightBold]
             color:[UIColor colorWithWhite:0.25 alpha:1.0] align:NSTextAlignmentRight];

    // Artwork
    CGFloat art = MIN(body.size.height * 0.42, 84);
    CGRect artRect = CGRectMake(pad, body.origin.y + lh + 4, art, art);
    if (self.artworkImage) {
        [self.artworkImage drawInRect:artRect];
    } else {
        [[UIColor colorWithWhite:0.90 alpha:1.0] setFill];
        UIRectFill(artRect);
        [self drawText:@"\u266A" inRect:artRect
                  font:[UIFont systemFontOfSize:art * 0.5 weight:UIFontWeightRegular]
                 color:[UIColor colorWithWhite:0.55 alpha:1.0] align:NSTextAlignmentCenter];
    }
    [[UIColor colorWithWhite:0.65 alpha:1.0] setStroke];
    UIBezierPath *artBorder = [UIBezierPath bezierPathWithRect:artRect];
    artBorder.lineWidth = 0.5;
    [artBorder stroke];

    // Track info
    CGFloat tx = CGRectGetMaxX(artRect) + 10;
    CGFloat tw = w - tx - pad;
    CGFloat th = art / 3.0;
    [self drawText:item.title ?: @"Unknown Song" inRect:CGRectMake(tx, artRect.origin.y, tw, th)
              font:[UIFont systemFontOfSize:lh * 0.72 weight:UIFontWeightBold]
             color:[UIColor blackColor] align:NSTextAlignmentLeft];
    [self drawText:item.artist ?: @"Unknown Artist" inRect:CGRectMake(tx, artRect.origin.y + th, tw, th)
              font:[UIFont systemFontOfSize:lh * 0.66 weight:UIFontWeightRegular]
             color:[UIColor colorWithWhite:0.2 alpha:1.0] align:NSTextAlignmentLeft];
    [self drawText:item.albumTitle ?: @"Unknown Album" inRect:CGRectMake(tx, artRect.origin.y + 2 * th, tw, th)
              font:[UIFont systemFontOfSize:lh * 0.62 weight:UIFontWeightRegular]
             color:[UIColor colorWithWhite:0.45 alpha:1.0] align:NSTextAlignmentLeft];

    // Progress / volume bar
    CGFloat barY = CGRectGetMaxY(body) - lh * 2.2;
    CGRect bar = CGRectMake(pad, barY, w - 2 * pad, 11);
    UIBezierPath *track = [UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:5.5];
    [[UIColor colorWithWhite:0.90 alpha:1.0] setFill];
    [track fill];
    [[UIColor colorWithWhite:0.55 alpha:1.0] setStroke];
    track.lineWidth = 1.0;
    [track stroke];

    CGFloat frac;
    if (self.bottomMode == IPBottomModeVolume) {
        frac = self.volume;
    } else {
        frac = self.duration > 0 ? self.elapsed / self.duration : 0;
    }
    frac = MAX(0, MIN(1, frac));

    if (frac > 0) {
        CGRect fill = CGRectInset(bar, 1, 1);
        fill.size.width = MAX(fill.size.height, fill.size.width * frac);
        UIBezierPath *fp = [UIBezierPath bezierPathWithRoundedRect:fill cornerRadius:fill.size.height / 2.0];
        [[UIColor colorWithRed:0.20 green:0.50 blue:0.92 alpha:1.0] setFill];
        [fp fill];
    }

    if (self.bottomMode == IPBottomModeScrub) {
        CGFloat dx = bar.origin.x + bar.size.width * frac;
        CGFloat dy = CGRectGetMidY(bar);
        UIBezierPath *diamond = [UIBezierPath bezierPath];
        [diamond moveToPoint:CGPointMake(dx, dy - 8)];
        [diamond addLineToPoint:CGPointMake(dx + 6, dy)];
        [diamond addLineToPoint:CGPointMake(dx, dy + 8)];
        [diamond addLineToPoint:CGPointMake(dx - 6, dy)];
        [diamond closePath];
        [[UIColor colorWithWhite:0.15 alpha:1.0] setFill];
        [diamond fill];
    }

    CGRect labelRow = CGRectMake(pad, CGRectGetMaxY(bar) + 3, w - 2 * pad, lh);
    UIFont *small = [UIFont systemFontOfSize:lh * 0.62 weight:UIFontWeightMedium];
    UIColor *gray = [UIColor colorWithWhite:0.3 alpha:1.0];
    if (self.bottomMode == IPBottomModeVolume) {
        [self drawText:@"Volume" inRect:labelRow font:small color:gray align:NSTextAlignmentCenter];
    } else {
        [self drawText:TimeString(self.elapsed) inRect:labelRow font:small color:gray align:NSTextAlignmentLeft];
        [self drawText:[@"-" stringByAppendingString:TimeString(self.duration - self.elapsed)]
                inRect:labelRow font:small color:gray align:NSTextAlignmentRight];
    }
}

@end
