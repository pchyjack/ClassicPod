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
@property (nonatomic, strong) NSCache *coverCache;
@end

@implementation IPScreenView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor whiteColor];
        self.opaque = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.queueIndex = -1;
        self.sliderMarker = -1;
        self.coverCache = [NSCache new];
    }
    return self;
}

- (void)setCoverItems:(NSArray<MPMediaItemCollection *> *)items {
    if (_coverItems == items) return;
    _coverItems = items;
    [self.coverCache removeAllObjects];
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

    if (self.mode == IPScreenModeCoverFlow) {   // Cover Flow fills the whole screen, no title bar
        [self drawCoverFlowInRect:b ctx:ctx];
        [self drawOverlayInRect:b];
        return;
    }

    CGFloat titleH = round(b.size.height / (kVisibleRows + 1));
    [self drawTitleBarInRect:CGRectMake(0, 0, b.size.width, titleH) ctx:ctx];

    CGRect body = CGRectMake(0, titleH, b.size.width, b.size.height - titleH);
    switch (self.mode) {
        case IPScreenModeMenu:       [self drawMenuInRect:body ctx:ctx]; break;
        case IPScreenModeNowPlaying: [self drawNowPlayingInRect:body ctx:ctx]; break;
        case IPScreenModeSlider:     [self drawSliderInRect:body ctx:ctx]; break;
        default: break;
    }
    [self drawOverlayInRect:body];
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

    CGFloat optY = CGRectGetMaxY(body) - lh * 2.2;

    if (self.rating > 0 && self.bottomMode != IPBottomModeRating) {
        NSString *stars = [@"" stringByPaddingToLength:(NSUInteger)MIN(5, self.rating) withString:@"\u2605" startingAtIndex:0];
        [self drawText:stars inRect:CGRectMake(tx, CGRectGetMaxY(artRect) + 2, tw, lh)
                  font:[UIFont systemFontOfSize:lh * 0.8 weight:UIFontWeightRegular]
                 color:[UIColor colorWithRed:0.20 green:0.50 blue:0.92 alpha:1.0] align:NSTextAlignmentLeft];
    }

    if (self.bottomMode == IPBottomModeRating) {
        NSInteger r = MAX(0, MIN(5, self.rating));
        NSString *filled = [@"" stringByPaddingToLength:(NSUInteger)r withString:@"\u2605" startingAtIndex:0];
        NSString *empty = [@"" stringByPaddingToLength:(NSUInteger)(5 - r) withString:@"\u2606" startingAtIndex:0];
        [self drawText:[filled stringByAppendingString:empty] inRect:CGRectMake(0, optY - 6, w, lh * 1.5)
                  font:[UIFont systemFontOfSize:lh * 1.2 weight:UIFontWeightRegular]
                 color:[UIColor colorWithRed:0.20 green:0.50 blue:0.92 alpha:1.0] align:NSTextAlignmentCenter];
        [self drawText:@"Rating" inRect:CGRectMake(pad, optY + lh * 1.3, w - 2 * pad, lh)
                  font:[UIFont systemFontOfSize:lh * 0.62 weight:UIFontWeightMedium]
                 color:[UIColor colorWithWhite:0.3 alpha:1.0] align:NSTextAlignmentCenter];
        return;
    }

    if (self.bottomMode == IPBottomModeShuffle) {
        NSArray<NSString *> *names = @[@"Off", @"Songs", @"Albums"];
        NSInteger selected = (self.shuffleMode == MPMusicShuffleModeSongs) ? 1 : (self.shuffleMode == MPMusicShuffleModeAlbums ? 2 : 0);
        CGFloat segW = (w - 2 * pad) / 3.0;
        for (NSInteger i = 0; i < 3; i++) {
            CGRect seg = CGRectMake(pad + i * segW + 2, optY - 2, segW - 4, lh * 1.2);
            UIBezierPath *sp = [UIBezierPath bezierPathWithRoundedRect:seg cornerRadius:4];
            [(i == selected ? [UIColor colorWithRed:0.20 green:0.50 blue:0.92 alpha:1.0] : [UIColor colorWithWhite:0.90 alpha:1.0]) setFill];
            [sp fill];
            [self drawText:names[i] inRect:seg font:[UIFont systemFontOfSize:lh * 0.66 weight:UIFontWeightSemibold]
                     color:(i == selected ? [UIColor whiteColor] : [UIColor blackColor]) align:NSTextAlignmentCenter];
        }
        [self drawText:@"Shuffle" inRect:CGRectMake(pad, optY + lh * 1.3, w - 2 * pad, lh)
                  font:[UIFont systemFontOfSize:lh * 0.62 weight:UIFontWeightMedium]
                 color:[UIColor colorWithWhite:0.3 alpha:1.0] align:NSTextAlignmentCenter];
        return;
    }

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

#pragma mark - Slider, Cover Flow, letter overlay

- (void)drawSliderInRect:(CGRect)body ctx:(CGContextRef)ctx {
    CGFloat w = body.size.width, pad = 24;
    [self drawText:self.sliderCaption inRect:CGRectMake(0, CGRectGetMidY(body) - 46, w, 24)
              font:[UIFont systemFontOfSize:15 weight:UIFontWeightBold]
             color:[UIColor blackColor] align:NSTextAlignmentCenter];

    CGRect bar = CGRectMake(pad, CGRectGetMidY(body) - 6, w - 2 * pad, 12);
    UIBezierPath *track = [UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:6];
    [[UIColor colorWithWhite:0.90 alpha:1.0] setFill];
    [track fill];
    [[UIColor colorWithWhite:0.55 alpha:1.0] setStroke];
    track.lineWidth = 1.0;
    [track stroke];

    CGFloat frac = MAX(0, MIN(1, self.sliderValue));
    if (frac > 0) {
        CGRect fill = CGRectInset(bar, 1, 1);
        fill.size.width = MAX(fill.size.height, fill.size.width * frac);
        [[UIColor colorWithRed:0.20 green:0.50 blue:0.92 alpha:1.0] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:fill cornerRadius:fill.size.height / 2.0] fill];
    }

    if (self.sliderMarker >= 0) { // triangle under the bar marks the limit
        CGFloat x = bar.origin.x + bar.size.width * MIN(1, self.sliderMarker);
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:CGPointMake(x, CGRectGetMaxY(bar) + 3)];
        [tri addLineToPoint:CGPointMake(x + 6, CGRectGetMaxY(bar) + 13)];
        [tri addLineToPoint:CGPointMake(x - 6, CGRectGetMaxY(bar) + 13)];
        [tri closePath];
        [[UIColor colorWithWhite:0.15 alpha:1.0] setFill];
        [tri fill];
    }
}

- (UIImage *)coverImageAtIndex:(NSInteger)i {
    UIImage *img = [self.coverCache objectForKey:@(i)];
    if (!img) {
        MPMediaItem *rep = self.coverItems[i].representativeItem;
        img = [rep.artwork imageWithSize:CGSizeMake(120, 120)];
        if (!img) {
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(8, 8), YES, 1);
            [[UIColor colorWithWhite:0.35 alpha:1.0] setFill];
            UIRectFill(CGRectMake(0, 0, 8, 8));
            img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        [self.coverCache setObject:img forKey:@(i)];
    }
    return img;
}

- (void)drawCover:(UIImage *)img inRect:(CGRect)r ctx:(CGContextRef)ctx {
    [img drawInRect:r];

    // Reflection
    CGRect refl = CGRectMake(r.origin.x, CGRectGetMaxY(r) + 1, r.size.width, r.size.height * 0.45);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, refl);
    CGContextTranslateCTM(ctx, 0, 2 * CGRectGetMaxY(r) + 2);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetAlpha(ctx, 0.35);
    [img drawInRect:r];
    CGContextRestoreGState(ctx);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat fade[8] = {0, 0, 0, 0.25, 0, 0, 0, 1.0};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, fade, NULL, 2);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, refl);
    CGContextDrawLinearGradient(ctx, g, refl.origin, CGPointMake(refl.origin.x, CGRectGetMaxY(refl)), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

- (void)drawCoverFlowInRect:(CGRect)body ctx:(CGContextRef)ctx {
    [[UIColor blackColor] setFill];
    UIRectFill(body);

    NSInteger n = (NSInteger)self.coverItems.count;
    if (n == 0) {
        [self drawText:@"No Albums" inRect:body font:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]
                 color:[UIColor lightGrayColor] align:NSTextAlignmentCenter];
        return;
    }

    NSInteger idx = MAX(0, MIN(n - 1, self.coverIndex));
    CGFloat w = body.size.width, h = body.size.height;
    CGFloat side = h * 0.46;
    CGFloat cy = body.origin.y + h * 0.36;

    for (NSInteger k = 3; k >= 1; k--) {            // far covers first so near ones overlap them
        for (NSInteger dir = -1; dir <= 1; dir += 2) {
            NSInteger j = idx + dir * k;
            if (j < 0 || j >= n) continue;
            CGFloat cw = side * 0.34, ch = side * 0.86;
            CGFloat cx = w / 2.0 + dir * (side * 0.62 + (k - 1) * side * 0.24);
            [self drawCover:[self coverImageAtIndex:j] inRect:CGRectMake(cx - cw / 2.0, cy - ch / 2.0, cw, ch) ctx:ctx];
        }
    }
    [self drawCover:[self coverImageAtIndex:idx] inRect:CGRectMake(w / 2.0 - side / 2.0, cy - side / 2.0, side, side) ctx:ctx];

    MPMediaItem *rep = self.coverItems[idx].representativeItem;
    CGFloat lineH = h * 0.10;
    [self drawText:rep.albumTitle ?: @"Unknown Album"
            inRect:CGRectMake(8, CGRectGetMaxY(body) - lineH * 2 - 2, w - 16, lineH)
              font:[UIFont systemFontOfSize:lineH * 0.78 weight:UIFontWeightBold]
             color:[UIColor whiteColor] align:NSTextAlignmentCenter];
    [self drawText:rep.artist ?: @"Unknown Artist"
            inRect:CGRectMake(8, CGRectGetMaxY(body) - lineH - 2, w - 16, lineH)
              font:[UIFont systemFontOfSize:lineH * 0.70 weight:UIFontWeightRegular]
             color:[UIColor colorWithWhite:0.7 alpha:1.0] align:NSTextAlignmentCenter];
}

- (void)drawOverlayInRect:(CGRect)area {
    if (self.overlayLetter.length == 0) return;
    CGFloat s = MIN(area.size.width, area.size.height) * 0.5;
    CGRect box = CGRectMake(CGRectGetMidX(area) - s / 2.0, CGRectGetMidY(area) - s / 2.0, s, s);
    [[UIColor colorWithWhite:0.1 alpha:0.78] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:box cornerRadius:s * 0.12] fill];
    [self drawText:self.overlayLetter inRect:box font:[UIFont systemFontOfSize:s * 0.7 weight:UIFontWeightBold]
             color:[UIColor whiteColor] align:NSTextAlignmentCenter];
}

@end
