#import "IPScreenView.h"
#import <QuartzCore/QuartzCore.h>

static const NSInteger kVisibleRows = 8;

// The iPod classic's menus use a bold Helvetica-style face.
static UIFont *IPBoldFont(CGFloat size) {
    return [UIFont fontWithName:@"HelveticaNeue-Bold" size:size] ?: [UIFont boldSystemFontOfSize:size];
}
static UIFont *IPRegularFont(CGFloat size) {
    return [UIFont fontWithName:@"HelveticaNeue" size:size] ?: [UIFont systemFontOfSize:size];
}

static void DrawSpeaker(CGPoint c, CGFloat s, BOOL waves, UIColor *color) {
    [color setFill];
    [color setStroke];
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(c.x - s * 0.55, c.y - s * 0.18)];
    [p addLineToPoint:CGPointMake(c.x - s * 0.25, c.y - s * 0.18)];
    [p addLineToPoint:CGPointMake(c.x + s * 0.10, c.y - s * 0.48)];
    [p addLineToPoint:CGPointMake(c.x + s * 0.10, c.y + s * 0.48)];
    [p addLineToPoint:CGPointMake(c.x - s * 0.25, c.y + s * 0.18)];
    [p addLineToPoint:CGPointMake(c.x - s * 0.55, c.y + s * 0.18)];
    [p closePath];
    [p fill];
    if (waves) {
        for (NSInteger k = 1; k <= 2; k++) {
            UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(c.x + s * 0.10, c.y)
                                                               radius:s * (0.28 * k + 0.10)
                                                           startAngle:-M_PI / 4 endAngle:M_PI / 4 clockwise:YES];
            arc.lineWidth = s * 0.10;
            arc.lineCapStyle = kCGLineCapRound;
            [arc stroke];
        }
    }
}

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
@property (nonatomic, strong) CADisplayLink *coverLink;
@property (nonatomic) CGFloat coverPosition;   // animated position, in album indexes
@property (nonatomic) BOOL coverNeedsSnap;     // jump (don't animate) to the next index we're given
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

- (void)setMode:(IPScreenMode)mode {
    _mode = mode;
    BOOL video = (mode == IPScreenModeVideo);   // transparent so the video shows through
    self.opaque = !video;
    self.backgroundColor = video ? [UIColor clearColor] : [UIColor whiteColor];
    [self setNeedsDisplay];
}

- (void)setCoverItems:(NSArray<MPMediaItemCollection *> *)items {
    if (_coverItems == items) return;
    _coverItems = items;
    [self.coverCache removeAllObjects];
    self.coverNeedsSnap = YES;
}

- (void)setCoverIndex:(NSInteger)index {
    BOOL changed = (index != _coverIndex);
    _coverIndex = index;
    if (self.coverNeedsSnap) {
        self.coverNeedsSnap = NO;
        self.coverPosition = index;
        [self stopCoverAnimation];
        return;
    }
    if (changed || fabs(self.coverPosition - index) > 0.005) [self startCoverAnimation];
}

- (void)startCoverAnimation {
    if (self.coverLink) return;
    self.coverLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(coverTick:)];
    [self.coverLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopCoverAnimation {
    [self.coverLink invalidate];
    self.coverLink = nil;
}

// Glides the covers toward the selected album (ease-out), like the real Cover Flow.
- (void)coverTick:(CADisplayLink *)link {
    CGFloat target = self.coverIndex;
    CGFloat diff = target - self.coverPosition;
    if (fabs(diff) > 8) { // after a big jump, only animate the last few covers
        self.coverPosition = target - (diff > 0 ? 8 : -8);
        diff = target - self.coverPosition;
    }
    if (self.mode != IPScreenModeCoverFlow || fabs(diff) < 0.004) {
        self.coverPosition = target;
        [self stopCoverAnimation];
    } else {
        CGFloat dt = MAX(1.0 / 120.0, MIN(1.0 / 20.0, link.targetTimestamp - link.timestamp));
        self.coverPosition += diff * (1.0 - exp(-dt * 12.0));
    }
    [self setNeedsDisplay];
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
    if (self.mode == IPScreenModeVideo) {
        CGContextClearRect(ctx, b);
        [self drawVideoOverlayInRect:b];
        return;
    }
    [[UIColor whiteColor] setFill];
    UIRectFill(b);

    if (self.mode == IPScreenModeCoverFlow) {   // the 3D Cover Flow view covers this; keep it black underneath
        [[UIColor blackColor] setFill];
        UIRectFill(b);
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
    const CGFloat top[3] = {0.93, 0.93, 0.94};
    const CGFloat bottom[3] = {0.66, 0.67, 0.70};
    [self fillGradientInRect:r top:top bottom:bottom ctx:ctx];
    [[UIColor colorWithWhite:0.40 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, CGRectGetMaxY(r) - 1, r.size.width, 1));

    // Title on the left, like the real iPod classic
    UIFont *font = IPBoldFont(r.size.height * 0.62);
    [self drawText:self.title inRect:CGRectMake(8, r.origin.y, r.size.width - 84, r.size.height)
              font:font color:[UIColor blackColor] align:NSTextAlignmentLeft];

    // Right side: play / pause, then battery
    CGFloat cy = CGRectGetMidY(r);
    float level = [UIDevice currentDevice].batteryLevel;
    if (level < 0) level = 1.0f;
    CGRect bat = CGRectMake(r.size.width - 34, cy - 5.5, 26, 11);
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:bat cornerRadius:2];
    bp.lineWidth = 1.0;
    [[UIColor colorWithWhite:0.30 alpha:1.0] setStroke];
    [bp stroke];
    [[UIColor colorWithWhite:0.30 alpha:1.0] setFill];
    UIRectFill(CGRectMake(CGRectGetMaxX(bat), cy - 2, 2, 4));
    CGRect fill = CGRectInset(bat, 2, 2);
    fill.size.width *= level;
    [(level < 0.2f ? [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1] : [UIColor colorWithRed:0.30 green:0.78 blue:0.25 alpha:1]) setFill];
    UIRectFill(fill);

    CGFloat px = bat.origin.x - 18;
    [[UIColor colorWithRed:0.15 green:0.55 blue:0.95 alpha:1.0] setFill];
    if (self.playing) {
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:CGPointMake(px, cy - 6)];
        [tri addLineToPoint:CGPointMake(px + 11, cy)];
        [tri addLineToPoint:CGPointMake(px, cy + 6)];
        [tri closePath];
        [tri fill];
    } else if (self.nowPlayingItem) {
        UIRectFill(CGRectMake(px, cy - 6, 4, 12));
        UIRectFill(CGRectMake(px + 7, cy - 6, 4, 12));
    }
}

- (void)drawMenuInRect:(CGRect)body ctx:(CGContextRef)ctx {
    NSInteger n = (NSInteger)self.items.count;
    BOOL hasPreview = (self.previewKind != IPPreviewNone);
    CGFloat listW = hasPreview ? round(body.size.width * 0.62) : body.size.width;
    CGFloat rowH = body.size.height / kVisibleRows;
    NSInteger sel = MAX(0, MIN(n - 1, self.selectedIndex));

    if (sel < self.topIndex) self.topIndex = sel;
    if (sel >= self.topIndex + kVisibleRows) self.topIndex = sel - kVisibleRows + 1;
    self.topIndex = MAX(0, MIN(self.topIndex, MAX(0, n - kVisibleRows)));

    BOOL needsScrollBar = n > kVisibleRows;
    CGFloat rightEdge = listW - (needsScrollBar ? 12 : 0);
    UIFont *font = IPBoldFont(rowH * 0.66);

    for (NSInteger i = 0; i < kVisibleRows; i++) {
        NSInteger idx = self.topIndex + i;
        if (idx >= n) break;
        IPMenuItem *item = self.items[idx];
        CGRect row = CGRectMake(0, body.origin.y + i * rowH, rightEdge, rowH);
        BOOL selected = (idx == sel);
        UIColor *textColor = [UIColor blackColor];

        if (selected) {
            const CGFloat top[3] = {0.33, 0.62, 0.93};
            const CGFloat bottom[3] = {0.12, 0.40, 0.80};
            [self fillGradientInRect:row top:top bottom:bottom ctx:ctx];
            textColor = [UIColor whiteColor];
        }

        CGFloat trailing = 8;
        if (selected && item.hasChildren) {            // the arrow only appears on the highlighted row
            CGFloat cx = rightEdge - 15, cy = CGRectGetMidY(row);
            UIBezierPath *chevron = [UIBezierPath bezierPath];
            [chevron moveToPoint:CGPointMake(cx, cy - 5.5)];
            [chevron addLineToPoint:CGPointMake(cx + 5.5, cy)];
            [chevron addLineToPoint:CGPointMake(cx, cy + 5.5)];
            chevron.lineWidth = 2.8;
            chevron.lineCapStyle = kCGLineCapRound;
            chevron.lineJoinStyle = kCGLineJoinRound;
            [textColor setStroke];
            [chevron stroke];
            trailing = 24;
        }

        CGFloat titleWidth = rightEdge - 8 - trailing;
        if (item.detail.length) {
            titleWidth = rightEdge * 0.55 - 8;
            [self drawText:item.detail
                    inRect:CGRectMake(rightEdge * 0.55, row.origin.y, rightEdge * 0.45 - 8, rowH)
                      font:font color:textColor align:NSTextAlignmentRight];
        }
        [self drawText:item.title inRect:CGRectMake(8, row.origin.y, titleWidth, rowH)
                  font:font color:textColor align:NSTextAlignmentLeft];
    }

    if (needsScrollBar) {
        CGRect track = CGRectMake(listW - 10, body.origin.y + 2, 6, body.size.height - 4);
        UIBezierPath *tp = [UIBezierPath bezierPathWithRoundedRect:track cornerRadius:3];
        [[UIColor colorWithWhite:0.90 alpha:1.0] setFill];
        [tp fill];
        [[UIColor colorWithWhite:0.70 alpha:1.0] setStroke];
        tp.lineWidth = 0.5;
        [tp stroke];

        CGFloat thumbH = MAX(14.0, track.size.height * kVisibleRows / n);
        CGFloat frac = (CGFloat)self.topIndex / (CGFloat)(n - kVisibleRows);
        CGRect thumb = CGRectMake(track.origin.x, track.origin.y + (track.size.height - thumbH) * frac, track.size.width, thumbH);
        [[UIColor colorWithWhite:0.45 alpha:1.0] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:thumb cornerRadius:3] fill];
    }

    if (hasPreview) {
        [self drawPreviewInRect:CGRectMake(listW, body.origin.y, body.size.width - listW, body.size.height) ctx:ctx];
    }
}

static void DrawGear(CGPoint c, CGFloat R, UIColor *color) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    NSInteger teeth = 8;
    CGFloat inner = R * 0.78;
    for (NSInteger i = 0; i < teeth; i++) {
        CGFloat a = i * 2 * M_PI / teeth;
        CGFloat baseHalf = 0.20, tipHalf = 0.13;
        CGPoint p0 = CGPointMake(c.x + inner * cos(a - baseHalf), c.y + inner * sin(a - baseHalf));
        CGPoint p1 = CGPointMake(c.x + R * cos(a - tipHalf), c.y + R * sin(a - tipHalf));
        CGPoint p2 = CGPointMake(c.x + R * cos(a + tipHalf), c.y + R * sin(a + tipHalf));
        CGPoint p3 = CGPointMake(c.x + inner * cos(a + baseHalf), c.y + inner * sin(a + baseHalf));
        if (i == 0) [p moveToPoint:p0]; else [p addLineToPoint:p0];
        [p addLineToPoint:p1];
        [p addLineToPoint:p2];
        [p addLineToPoint:p3];
    }
    [p closePath];
    [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - R * 0.36, c.y - R * 0.36, R * 0.72, R * 0.72)]];
    p.usesEvenOddFillRule = YES;
    [color setFill];
    [p fill];
}

static void DrawShuffleGlyph(CGPoint c, CGFloat s, UIColor *color) {
    [color setStroke];
    [color setFill];
    for (NSInteger k = 0; k < 2; k++) {
        CGFloat y0 = (k == 0) ? 0.35 : -0.35;
        CGFloat y1 = -y0;
        UIBezierPath *p = [UIBezierPath bezierPath];
        p.lineWidth = s * 0.09;
        p.lineCapStyle = kCGLineCapRound;
        [p moveToPoint:CGPointMake(c.x - s * 0.6, c.y + s * y0)];
        [p addCurveToPoint:CGPointMake(c.x + s * 0.38, c.y + s * y1)
             controlPoint1:CGPointMake(c.x, c.y + s * y0)
             controlPoint2:CGPointMake(c.x, c.y + s * y1)];
        [p stroke];
        UIBezierPath *head = [UIBezierPath bezierPath];
        [head moveToPoint:CGPointMake(c.x + s * 0.62, c.y + s * y1)];
        [head addLineToPoint:CGPointMake(c.x + s * 0.34, c.y + s * (y1 - 0.14))];
        [head addLineToPoint:CGPointMake(c.x + s * 0.34, c.y + s * (y1 + 0.14))];
        [head closePath];
        [head fill];
    }
}

// The picture pane beside the main menu: album art, or a gear / shuffle symbol.
- (void)drawPreviewInRect:(CGRect)r ctx:(CGContextRef)ctx {
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, r);

    UIImage *img = nil;
    if (self.previewKind == IPPreviewArtwork) img = self.previewImage;
    else if (self.previewKind == IPPreviewNowPlaying) img = self.artworkImage;

    if (self.previewKind == IPPreviewSettings || self.previewKind == IPPreviewShuffle) {
        const CGFloat top[3] = {0.97, 0.97, 0.98};
        const CGFloat bottom[3] = {0.80, 0.81, 0.84};
        [self fillGradientInRect:r top:top bottom:bottom ctx:ctx];
        CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
        CGFloat s = MIN(r.size.width, r.size.height) * 0.46;
        UIColor *glyph = [UIColor colorWithWhite:0.42 alpha:1.0];
        if (self.previewKind == IPPreviewSettings) DrawGear(c, s, glyph);
        else DrawShuffleGlyph(c, s * 1.5, glyph);
    } else if (img) {
        CGFloat scale = MAX(r.size.width / img.size.width, r.size.height / img.size.height);
        CGSize sz = CGSizeMake(img.size.width * scale, img.size.height * scale);
        [img drawInRect:CGRectMake(CGRectGetMidX(r) - sz.width / 2.0, CGRectGetMidY(r) - sz.height / 2.0, sz.width, sz.height)];
    } else {
        [[UIColor colorWithWhite:0.15 alpha:1.0] setFill];
        UIRectFill(r);
        [self drawText:@"\u266A" inRect:r font:IPRegularFont(r.size.width * 0.5)
                 color:[UIColor colorWithWhite:0.45 alpha:1.0] align:NSTextAlignmentCenter];
    }
    CGContextRestoreGState(ctx);

    [[UIColor colorWithWhite:0.55 alpha:1.0] setFill];
    UIRectFill(CGRectMake(r.origin.x, r.origin.y, 1, r.size.height));
}

- (void)drawNowPlayingInRect:(CGRect)body ctx:(CGContextRef)ctx {
    CGFloat w = body.size.width;
    CGFloat pad = 10;
    MPMediaItem *item = self.nowPlayingItem;

    if (!item) {
        [self drawText:@"Nothing Playing" inRect:body
                  font:IPRegularFont(15)
                 color:[UIColor grayColor] align:NSTextAlignmentCenter];
        return;
    }

    CGFloat lh = body.size.height / 9.0;

    if (self.queueIndex >= 0 && self.queueCount > 0 && self.queueIndex < self.queueCount) {
        NSString *pos = [NSString stringWithFormat:@"%ld of %ld", (long)self.queueIndex + 1, (long)self.queueCount];
        [self drawText:pos inRect:CGRectMake(0, body.origin.y + 2, w, lh)
                  font:IPRegularFont(lh * 0.62)
                 color:[UIColor colorWithWhite:0.4 alpha:1.0] align:NSTextAlignmentCenter];
    }

    // Shuffle / repeat icons, top right
    NSString *flags = @"";
    if (self.shuffleMode == MPMusicShuffleModeSongs || self.shuffleMode == MPMusicShuffleModeAlbums) flags = @"\u21C4";
    if (self.repeatMode == MPMusicRepeatModeAll) flags = [flags stringByAppendingString:@" \u21BB"];
    else if (self.repeatMode == MPMusicRepeatModeOne) flags = [flags stringByAppendingString:@" \u21BB1"];
    [self drawText:flags inRect:CGRectMake(0, body.origin.y + 2, w - pad, lh)
              font:IPBoldFont(lh * 0.70)
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
                  font:IPRegularFont(art * 0.5)
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
              font:IPBoldFont(lh * 0.72)
             color:[UIColor blackColor] align:NSTextAlignmentLeft];
    [self drawText:item.artist ?: @"Unknown Artist" inRect:CGRectMake(tx, artRect.origin.y + th, tw, th)
              font:IPRegularFont(lh * 0.66)
             color:[UIColor colorWithWhite:0.2 alpha:1.0] align:NSTextAlignmentLeft];
    [self drawText:item.albumTitle ?: @"Unknown Album" inRect:CGRectMake(tx, artRect.origin.y + 2 * th, tw, th)
              font:IPRegularFont(lh * 0.62)
             color:[UIColor colorWithWhite:0.45 alpha:1.0] align:NSTextAlignmentLeft];

    CGFloat optY = CGRectGetMaxY(body) - lh * 2.2;

    if (self.rating > 0 && self.bottomMode != IPBottomModeRating) {
        NSString *stars = [@"" stringByPaddingToLength:(NSUInteger)MIN(5, self.rating) withString:@"\u2605" startingAtIndex:0];
        [self drawText:stars inRect:CGRectMake(tx, CGRectGetMaxY(artRect) + 2, tw, lh)
                  font:IPRegularFont(lh * 0.8)
                 color:[UIColor colorWithRed:0.20 green:0.50 blue:0.92 alpha:1.0] align:NSTextAlignmentLeft];
    }

    if (self.bottomMode == IPBottomModeRating) {
        NSInteger r = MAX(0, MIN(5, self.rating));
        NSString *filled = [@"" stringByPaddingToLength:(NSUInteger)r withString:@"\u2605" startingAtIndex:0];
        NSString *empty = [@"" stringByPaddingToLength:(NSUInteger)(5 - r) withString:@"\u2606" startingAtIndex:0];
        [self drawText:[filled stringByAppendingString:empty] inRect:CGRectMake(0, optY - 6, w, lh * 1.5)
                  font:IPRegularFont(lh * 1.2)
                 color:[UIColor colorWithRed:0.20 green:0.50 blue:0.92 alpha:1.0] align:NSTextAlignmentCenter];
        [self drawText:@"Rating" inRect:CGRectMake(pad, optY + lh * 1.3, w - 2 * pad, lh)
                  font:IPRegularFont(lh * 0.62)
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
            [self drawText:names[i] inRect:seg font:IPBoldFont(lh * 0.66)
                     color:(i == selected ? [UIColor whiteColor] : [UIColor blackColor]) align:NSTextAlignmentCenter];
        }
        [self drawText:@"Shuffle" inRect:CGRectMake(pad, optY + lh * 1.3, w - 2 * pad, lh)
                  font:IPRegularFont(lh * 0.62)
                 color:[UIColor colorWithWhite:0.3 alpha:1.0] align:NSTextAlignmentCenter];
        return;
    }

    // Progress / volume bar
    CGFloat barY = CGRectGetMaxY(body) - lh * 2.2;
    CGRect bar = CGRectMake(pad, barY, w - 2 * pad, 11);
    if (self.bottomMode == IPBottomModeVolume) {   // leave room for the speaker icons
        bar.origin.x = pad + 18;
        bar.size.width = w - 2 * pad - 38;
    }
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

    if (self.bottomMode == IPBottomModeVolume) {
        UIColor *iconColor = [UIColor colorWithWhite:0.25 alpha:1.0];
        DrawSpeaker(CGPointMake(pad + 6, CGRectGetMidY(bar)), 9, NO, iconColor);
        DrawSpeaker(CGPointMake(w - pad - 12, CGRectGetMidY(bar)), 13, YES, iconColor);
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
    UIFont *small = IPRegularFont(lh * 0.62);
    UIColor *gray = [UIColor colorWithWhite:0.3 alpha:1.0];
    if (self.bottomMode == IPBottomModeVolume) {
        // the speaker icons already say "volume"
    } else {
        [self drawText:TimeString(self.elapsed) inRect:labelRow font:small color:gray align:NSTextAlignmentLeft];
        [self drawText:[@"-" stringByAppendingString:TimeString(self.duration - self.elapsed)]
                inRect:labelRow font:small color:gray align:NSTextAlignmentRight];
    }
}

#pragma mark - Video overlay

- (void)drawVideoOverlayInRect:(CGRect)b {
    if (!self.videoOverlay || !self.nowPlayingItem) return;
    CGFloat w = b.size.width, h = b.size.height, pad = 14;
    CGRect panel = CGRectMake(0, h * 0.70, w, h * 0.30);
    [[UIColor colorWithWhite:0 alpha:0.65] setFill];
    UIRectFill(panel);

    CGFloat lh = panel.size.height / 3.0;
    [self drawText:self.nowPlayingItem.title ?: @"" inRect:CGRectMake(pad, panel.origin.y + 2, w - 2 * pad, lh)
              font:IPBoldFont(lh * 0.62) color:[UIColor whiteColor] align:NSTextAlignmentCenter];

    CGRect bar = CGRectMake(pad, panel.origin.y + lh + 4, w - 2 * pad, 9);
    if (self.bottomMode == IPBottomModeVolume) {
        bar.origin.x = pad + 18;
        bar.size.width = w - 2 * pad - 38;
    }
    UIBezierPath *track = [UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:4.5];
    [[UIColor colorWithWhite:0.35 alpha:1.0] setFill];
    [track fill];

    CGFloat frac = (self.bottomMode == IPBottomModeVolume) ? self.volume : (self.duration > 0 ? self.elapsed / self.duration : 0);
    frac = MAX(0, MIN(1, frac));
    if (frac > 0) {
        CGRect fill = bar;
        fill.size.width = MAX(fill.size.height, fill.size.width * frac);
        [[UIColor colorWithRed:0.20 green:0.55 blue:0.95 alpha:1.0] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:fill cornerRadius:fill.size.height / 2.0] fill];
    }

    if (self.bottomMode == IPBottomModeVolume) {
        DrawSpeaker(CGPointMake(pad + 6, CGRectGetMidY(bar)), 9, NO, [UIColor whiteColor]);
        DrawSpeaker(CGPointMake(w - pad - 12, CGRectGetMidY(bar)), 13, YES, [UIColor whiteColor]);
    } else {
        if (self.bottomMode == IPBottomModeScrub) {
            CGFloat dx = bar.origin.x + bar.size.width * frac, dy = CGRectGetMidY(bar);
            UIBezierPath *diamond = [UIBezierPath bezierPath];
            [diamond moveToPoint:CGPointMake(dx, dy - 8)];
            [diamond addLineToPoint:CGPointMake(dx + 6, dy)];
            [diamond addLineToPoint:CGPointMake(dx, dy + 8)];
            [diamond addLineToPoint:CGPointMake(dx - 6, dy)];
            [diamond closePath];
            [[UIColor whiteColor] setFill];
            [diamond fill];
        }
        CGRect times = CGRectMake(pad, CGRectGetMaxY(bar) + 3, w - 2 * pad, lh);
        UIFont *small = IPRegularFont(lh * 0.52);
        [self drawText:TimeString(self.elapsed) inRect:times font:small color:[UIColor whiteColor] align:NSTextAlignmentLeft];
        [self drawText:[@"-" stringByAppendingString:TimeString(self.duration - self.elapsed)]
                inRect:times font:small color:[UIColor whiteColor] align:NSTextAlignmentRight];
    }
}

#pragma mark - Slider, Cover Flow, letter overlay

- (void)drawSliderInRect:(CGRect)body ctx:(CGContextRef)ctx {
    CGFloat w = body.size.width, pad = 24;
    [self drawText:self.sliderCaption inRect:CGRectMake(0, CGRectGetMidY(body) - 46, w, 24)
              font:IPBoldFont(15)
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
        [self drawText:@"No Albums" inRect:body font:IPRegularFont(15)
                 color:[UIColor lightGrayColor] align:NSTextAlignmentCenter];
        return;
    }

    CGFloat w = body.size.width, h = body.size.height;
    CGFloat side = h * 0.46;
    CGFloat cy = body.origin.y + h * 0.36;
    CGFloat pos = MAX(0, MIN(n - 1, self.coverPosition));
    NSInteger idx = MAX(0, MIN(n - 1, (NSInteger)lround(pos)));

    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSInteger j = MAX(0, (NSInteger)floor(pos) - 4); j <= MIN(n - 1, (NSInteger)ceil(pos) + 4); j++) {
        [order addObject:@(j)];
    }
    [order sortUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) { // far covers first
        CGFloat dx = fabs(x.integerValue - pos), dy = fabs(y.integerValue - pos);
        return dx > dy ? NSOrderedAscending : (dx < dy ? NSOrderedDescending : NSOrderedSame);
    }];

    for (NSNumber *num in order) {
        NSInteger j = num.integerValue;
        CGFloat offset = j - pos, a = fabs(offset), sign = (offset < 0) ? -1 : 1;
        CGFloat t = MIN(a, 1.0);
        CGFloat turn = t * t * (3 - 2 * t);                    // 0 = facing front, 1 = turned away
        CGFloat cw = side * cos(turn * 65.0 * M_PI / 180.0);   // turning looks like a narrower cover
        CGFloat ch = side * (1.0 - 0.14 * turn);
        CGFloat cx = w / 2.0 + sign * (side * 0.72 * turn + MAX(0, a - 1) * side * 0.24);
        CGRect r = CGRectMake(cx - cw / 2.0, cy - ch / 2.0, cw, ch);
        [self drawCover:[self coverImageAtIndex:j] inRect:r ctx:ctx];
        if (turn > 0.01) { // shade covers that are turned away
            [[UIColor colorWithWhite:0 alpha:0.4 * turn] setFill];
            UIRectFillUsingBlendMode(r, kCGBlendModeNormal);
        }
    }

    MPMediaItem *rep = self.coverItems[idx].representativeItem;
    CGFloat lineH = h * 0.10;
    [self drawText:rep.albumTitle ?: @"Unknown Album"
            inRect:CGRectMake(8, CGRectGetMaxY(body) - lineH * 2 - 2, w - 16, lineH)
              font:IPBoldFont(lineH * 0.78)
             color:[UIColor whiteColor] align:NSTextAlignmentCenter];
    [self drawText:rep.artist ?: @"Unknown Artist"
            inRect:CGRectMake(8, CGRectGetMaxY(body) - lineH - 2, w - 16, lineH)
              font:IPRegularFont(lineH * 0.70)
             color:[UIColor colorWithWhite:0.7 alpha:1.0] align:NSTextAlignmentCenter];
}

- (void)drawOverlayInRect:(CGRect)area {
    if (self.overlayLetter.length == 0) return;
    CGFloat s = MIN(area.size.width, area.size.height) * 0.5;
    CGRect box = CGRectMake(CGRectGetMidX(area) - s / 2.0, CGRectGetMidY(area) - s / 2.0, s, s);
    [[UIColor colorWithWhite:0.1 alpha:0.78] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:box cornerRadius:s * 0.12] fill];
    [self drawText:self.overlayLetter inRect:box font:IPBoldFont(s * 0.7)
             color:[UIColor whiteColor] align:NSTextAlignmentCenter];
}

@end
