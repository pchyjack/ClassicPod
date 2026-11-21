#import "IPCoverFlowView.h"
#import <QuartzCore/QuartzCore.h>

// If the side covers lean the wrong way when you try it, change this to -1.
static const CGFloat kTurnSign = 1.0;
static const CGFloat kMaxTurn = 68.0 * M_PI / 180.0;

@interface IPCoverFlowView ()
@property (nonatomic, strong) CALayer *stage;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CALayer *> *coverLayers;
@property (nonatomic, strong) NSCache *imageCache;
@property (nonatomic, strong) UIImage *placeholder;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) CGFloat position;                // animated position, in album indexes
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIView *letterBox;
@property (nonatomic, strong) UILabel *letterLabel;
@end

@implementation IPCoverFlowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        self.clipsToBounds = YES;
        _coverLayers = [NSMutableDictionary dictionary];
        _imageCache = [NSCache new];

        _stage = [CALayer layer];
        [self.layer addSublayer:_stage];

        _titleLabel = [UILabel new];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_titleLabel];

        _artistLabel = [UILabel new];
        _artistLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        _artistLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_artistLabel];

        _letterBox = [UIView new];
        _letterBox.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.78];
        _letterBox.layer.cornerRadius = 10;
        _letterBox.hidden = YES;
        [self addSubview:_letterBox];

        _letterLabel = [UILabel new];
        _letterLabel.textColor = [UIColor whiteColor];
        _letterLabel.textAlignment = NSTextAlignmentCenter;
        [_letterBox addSubview:_letterLabel];
    }
    return self;
}

- (void)dealloc {
    [_link invalidate];
}

#pragma mark - Geometry

- (CGFloat)side { return self.bounds.size.height * 0.46; }
- (CGFloat)rowY { return self.bounds.size.height * 0.38; }   // vertical center of the covers

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat S = [self side], cy = [self rowY];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.stage.bounds = self.bounds;
    self.stage.anchorPoint = CGPointMake(0.5, cy / h);   // the vanishing point is the middle of the covers
    self.stage.position = CGPointMake(w / 2.0, cy);
    CATransform3D perspective = CATransform3DIdentity;
    perspective.m34 = -1.0 / (S * 3.0);
    self.stage.sublayerTransform = perspective;
    [CATransaction commit];

    CGFloat lineH = h * 0.10;
    UIFont *bold = [UIFont fontWithName:@"HelveticaNeue-Bold" size:lineH * 0.78] ?: [UIFont boldSystemFontOfSize:lineH * 0.78];
    UIFont *regular = [UIFont fontWithName:@"HelveticaNeue" size:lineH * 0.70] ?: [UIFont systemFontOfSize:lineH * 0.70];
    self.titleLabel.font = bold;
    self.artistLabel.font = regular;
    self.titleLabel.frame = CGRectMake(8, h - lineH * 2 - 2, w - 16, lineH);
    self.artistLabel.frame = CGRectMake(8, h - lineH - 2, w - 16, lineH);

    CGFloat box = MIN(w, h) * 0.5;
    self.letterBox.frame = CGRectMake((w - box) / 2.0, (h - box) / 2.0, box, box);
    self.letterLabel.frame = self.letterBox.bounds;
    self.letterLabel.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:box * 0.7] ?: [UIFont boldSystemFontOfSize:box * 0.7];

    for (CALayer *l in self.coverLayers.allValues) [l removeFromSuperlayer];   // rebuild at the new size
    [self.coverLayers removeAllObjects];
    [self applyTransforms];
}

#pragma mark - Public

- (void)setAlbums:(NSArray<MPMediaItemCollection *> *)albums {
    _albums = [albums copy];
    [self.imageCache removeAllObjects];
    for (CALayer *l in self.coverLayers.allValues) [l removeFromSuperlayer];
    [self.coverLayers removeAllObjects];
}

- (void)setIndex:(NSInteger)index {
    index = MAX(0, MIN((NSInteger)self.albums.count - 1, index));
    _index = index;
    if (fabs(self.position - index) > 0.004) [self startLink];
    [self updateLabels];
}

- (void)snapToIndex:(NSInteger)index {
    index = MAX(0, MIN((NSInteger)self.albums.count - 1, index));
    _index = index;
    self.position = index;
    [self stopLink];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self applyTransforms];
}

- (void)setOverlayLetter:(NSString *)letter {
    _overlayLetter = [letter copy];
    self.letterBox.hidden = (letter.length == 0);
    self.letterLabel.text = letter;
}

#pragma mark - Animation

- (void)startLink {
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopLink {
    [self.link invalidate];
    self.link = nil;
}

- (void)tick:(CADisplayLink *)link {
    CGFloat target = self.index;
    CGFloat diff = target - self.position;
    if (fabs(diff) > 8) { // after a big jump only the last few covers animate
        self.position = target - (diff > 0 ? 8 : -8);
        diff = target - self.position;
    }
    if (self.hidden || fabs(diff) < 0.004) {
        self.position = target;
        [self stopLink];
    } else {
        CGFloat dt = MAX(1.0 / 120.0, MIN(1.0 / 20.0, link.targetTimestamp - link.timestamp));
        self.position += diff * (1.0 - exp(-dt * 11.0));
    }
    [self applyTransforms];
}

#pragma mark - Covers

- (UIImage *)imageAtIndex:(NSInteger)i {
    UIImage *img = [self.imageCache objectForKey:@(i)];
    if (!img) {
        MPMediaItem *rep = self.albums[i].representativeItem;
        img = [rep.artwork imageWithSize:CGSizeMake(160, 160)];
        if (!img) {
            if (!self.placeholder) {
                UIGraphicsBeginImageContextWithOptions(CGSizeMake(8, 8), YES, 1);
                [[UIColor colorWithWhite:0.35 alpha:1.0] setFill];
                UIRectFill(CGRectMake(0, 0, 8, 8));
                self.placeholder = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
            }
            img = self.placeholder;
        }
        [self.imageCache setObject:img forKey:@(i)];
    }
    return img;
}

- (CALayer *)makeCoverLayerForIndex:(NSInteger)j {
    CGFloat S = [self side];
    id contents = (__bridge id)[self imageAtIndex:j].CGImage;

    CALayer *cover = [CALayer layer];
    cover.bounds = CGRectMake(0, 0, S, S);
    cover.contents = contents;
    cover.allowsEdgeAntialiasing = YES;

    // Shade that darkens covers as they turn away
    CALayer *shade = [CALayer layer];
    shade.name = @"shade";
    shade.frame = cover.bounds;
    shade.backgroundColor = [UIColor blackColor].CGColor;
    shade.opacity = 0;
    [cover addSublayer:shade];

    // Reflection: the bottom half of the cover, flipped, fading out
    CALayer *reflection = [CALayer layer];
    reflection.bounds = CGRectMake(0, 0, S, S * 0.5);
    reflection.position = CGPointMake(S / 2.0, S + 2 + S * 0.25);
    reflection.contents = contents;
    reflection.contentsRect = CGRectMake(0, 0.5, 1, 0.5);
    reflection.transform = CATransform3DMakeScale(1, -1, 1);
    CAGradientLayer *fade = [CAGradientLayer layer];
    fade.frame = reflection.bounds;
    fade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.0].CGColor,    // far end (after the flip)
                    (id)[UIColor colorWithWhite:0 alpha:0.42].CGColor];  // next to the cover
    reflection.mask = fade;
    [cover addSublayer:reflection];
    return cover;
}

- (void)applyTransforms {
    NSInteger n = (NSInteger)self.albums.count;
    if (n == 0 || self.bounds.size.width == 0) return;

    CGFloat S = [self side], w = self.bounds.size.width, cy = [self rowY];
    CGFloat pos = MAX(0, MIN(n - 1, self.position));
    NSInteger lo = MAX(0, (NSInteger)floor(pos) - 5);
    NSInteger hi = MIN(n - 1, (NSInteger)ceil(pos) + 5);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (NSNumber *key in [self.coverLayers allKeys]) {
        if (key.integerValue < lo || key.integerValue > hi) {
            [self.coverLayers[key] removeFromSuperlayer];
            [self.coverLayers removeObjectForKey:key];
        }
    }

    for (NSInteger j = lo; j <= hi; j++) {
        CALayer *cover = self.coverLayers[@(j)];
        if (!cover) {
            cover = [self makeCoverLayerForIndex:j];
            self.coverLayers[@(j)] = cover;
            [self.stage addSublayer:cover];
        }
        CGFloat offset = j - pos, a = fabs(offset), sign = (offset < 0) ? -1.0 : 1.0;
        CGFloat t = MIN(a, 1.0);
        CGFloat turn = t * t * (3 - 2 * t);                    // 0 = facing front, 1 = fully turned

        CGFloat x = sign * (0.70 * S * turn + MAX(0, a - 1) * 0.22 * S);
        CGFloat scale = 1.0 - 0.10 * turn;
        CGFloat angle = -sign * turn * kMaxTurn * kTurnSign;

        CATransform3D transform = CATransform3DMakeScale(scale, scale, 1);
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(angle, 0, 1, 0));
        cover.transform = transform;
        cover.position = CGPointMake(w / 2.0 + x, cy);
        cover.zPosition = -turn * 0.30 * S - MAX(0, a - 1) * 0.10 * S;   // turned covers sit further back

        for (CALayer *sub in cover.sublayers) {
            if ([sub.name isEqualToString:@"shade"]) sub.opacity = 0.45 * turn;
        }
    }
    [CATransaction commit];
    [self updateLabels];
}

- (void)updateLabels {
    NSInteger n = (NSInteger)self.albums.count;
    if (n == 0) {
        self.titleLabel.text = @"No Albums";
        self.artistLabel.text = nil;
        return;
    }
    NSInteger idx = MAX(0, MIN(n - 1, (NSInteger)lround(self.position)));
    MPMediaItem *rep = self.albums[idx].representativeItem;
    self.titleLabel.text = rep.albumTitle ?: @"Unknown Album";
    self.artistLabel.text = rep.artist ?: @"Unknown Artist";
}

@end
