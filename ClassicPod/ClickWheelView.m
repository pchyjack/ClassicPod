#import "ClickWheelView.h"

static const CGFloat kStepAngle = M_PI / 10.0;      // 18 degrees of rotation = one click
static const CGFloat kTapRotationLimit = 0.30;      // below this much rotation, a touch counts as a tap

@interface ClickWheelView ()
@property (nonatomic) CGFloat lastAngle;
@property (nonatomic) CGFloat accumulated;
@property (nonatomic) CGFloat totalRotation;
@property (nonatomic) CGPoint startPoint;
@property (nonatomic) BOOL startedInCenter;
@property (nonatomic) BOOL startedInRing;
@end

@implementation ClickWheelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        self.multipleTouchEnabled = NO;
    }
    return self;
}

#pragma mark - Geometry

- (CGPoint)wheelCenter { return CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds)); }
- (CGFloat)outerRadius { return MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) / 2.0 - 1.0; }
- (CGFloat)centerRadius { return [self outerRadius] * 0.38; }

- (CGFloat)angleForPoint:(CGPoint)p {
    CGPoint c = [self wheelCenter];
    return atan2(p.y - c.y, p.x - c.x); // y points down, so increasing angle = clockwise on screen
}

- (CGFloat)distanceForPoint:(CGPoint)p {
    CGPoint c = [self wheelCenter];
    return hypot(p.x - c.x, p.y - c.y);
}

#pragma mark - Drawing

- (void)drawTriangleAt:(CGPoint)p size:(CGFloat)s right:(BOOL)right {
    CGFloat dir = right ? 1.0 : -1.0;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(p.x - dir * s * 0.4, p.y - s * 0.5)];
    [path addLineToPoint:CGPointMake(p.x + dir * s * 0.5, p.y)];
    [path addLineToPoint:CGPointMake(p.x - dir * s * 0.4, p.y + s * 0.5)];
    [path closePath];
    [path fill];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint c = [self wheelCenter];
    CGFloat R = [self outerRadius];
    CGFloat r = [self centerRadius];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

    // Outer ring
    CGRect outer = CGRectMake(c.x - R, c.y - R, 2 * R, 2 * R);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, outer);
    CGContextClip(ctx);
    CGFloat ringColors[8] = {0.97, 0.97, 0.97, 1.0, 0.80, 0.80, 0.81, 1.0};
    CGGradientRef ringGradient = CGGradientCreateWithColorComponents(cs, ringColors, NULL, 2);
    CGContextDrawLinearGradient(ctx, ringGradient, CGPointMake(c.x, c.y - R), CGPointMake(c.x, c.y + R), 0);
    CGGradientRelease(ringGradient);
    CGContextRestoreGState(ctx);

    UIBezierPath *ringOutline = [UIBezierPath bezierPathWithOvalInRect:outer];
    ringOutline.lineWidth = 1.0;
    [[UIColor colorWithWhite:0.62 alpha:1.0] setStroke];
    [ringOutline stroke];

    // Center button
    CGRect inner = CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, inner);
    CGContextClip(ctx);
    CGFloat centerColors[8] = {0.995, 0.995, 0.995, 1.0, 0.89, 0.89, 0.90, 1.0};
    CGGradientRef centerGradient = CGGradientCreateWithColorComponents(cs, centerColors, NULL, 2);
    CGContextDrawLinearGradient(ctx, centerGradient, CGPointMake(c.x, c.y - r), CGPointMake(c.x, c.y + r), 0);
    CGGradientRelease(centerGradient);
    CGContextRestoreGState(ctx);

    UIBezierPath *innerOutline = [UIBezierPath bezierPathWithOvalInRect:inner];
    innerOutline.lineWidth = 1.0;
    [[UIColor colorWithWhite:0.66 alpha:1.0] setStroke];
    [innerOutline stroke];
    CGColorSpaceRelease(cs);

    // Button symbols
    UIColor *labelColor = [UIColor colorWithWhite:0.47 alpha:1.0];
    [labelColor setFill];
    CGFloat mid = (R + r) / 2.0;
    CGFloat s = (R - r) * 0.36;

    NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:(R - r) * 0.30 weight:UIFontWeightHeavy],
                            NSForegroundColorAttributeName: labelColor};
    NSString *menu = @"MENU";
    CGSize ms = [menu sizeWithAttributes:attrs];
    [menu drawAtPoint:CGPointMake(c.x - ms.width / 2.0, c.y - mid - ms.height / 2.0) withAttributes:attrs];

    [self drawTriangleAt:CGPointMake(c.x + mid - s * 0.45, c.y) size:s right:YES];
    [self drawTriangleAt:CGPointMake(c.x + mid + s * 0.45, c.y) size:s right:YES];
    [self drawTriangleAt:CGPointMake(c.x - mid - s * 0.45, c.y) size:s right:NO];
    [self drawTriangleAt:CGPointMake(c.x - mid + s * 0.45, c.y) size:s right:NO];

    [self drawTriangleAt:CGPointMake(c.x - s * 0.55, c.y + mid) size:s right:YES];
    CGFloat bx = c.x + s * 0.15, by = c.y + mid - s / 2.0;
    UIRectFill(CGRectMake(bx, by, s * 0.25, s));
    UIRectFill(CGRectMake(bx + s * 0.5, by, s * 0.25, s));
}

#pragma mark - Touch handling

- (void)resetTracking {
    self.startedInCenter = NO;
    self.startedInRing = NO;
    self.accumulated = 0;
    self.totalRotation = 0;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [touches.anyObject locationInView:self];
    CGFloat d = [self distanceForPoint:p];
    self.startPoint = p;
    self.startedInCenter = (d <= [self centerRadius]);
    self.startedInRing = (!self.startedInCenter && d <= [self outerRadius]);
    self.lastAngle = [self angleForPoint:p];
    self.accumulated = 0;
    self.totalRotation = 0;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.startedInRing) return;
    CGPoint p = [touches.anyObject locationInView:self];
    if ([self distanceForPoint:p] < [self centerRadius] * 0.6) return; // angle is unstable near the middle

    CGFloat a = [self angleForPoint:p];
    CGFloat delta = a - self.lastAngle;
    if (delta > M_PI) delta -= 2 * M_PI;
    else if (delta < -M_PI) delta += 2 * M_PI;
    self.lastAngle = a;
    self.totalRotation += fabs(delta);
    self.accumulated += delta;

    NSInteger steps = (NSInteger)(self.accumulated / kStepAngle);
    if (steps != 0) {
        self.accumulated -= steps * kStepAngle;
        [self.delegate clickWheel:self didRotateBySteps:steps];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [touches.anyObject locationInView:self];

    if (self.startedInCenter) {
        if ([self distanceForPoint:p] <= [self centerRadius] * 1.15) {
            [self.delegate clickWheel:self didPressButton:ClickWheelButtonCenter];
        }
    } else if (self.startedInRing && self.totalRotation < kTapRotationLimit) {
        CGFloat a = [self angleForPoint:self.startPoint];
        ClickWheelButton b;
        if (a >= -3 * M_PI_4 && a < -M_PI_4)      b = ClickWheelButtonMenu;
        else if (a >= -M_PI_4 && a < M_PI_4)      b = ClickWheelButtonNext;
        else if (a >= M_PI_4 && a < 3 * M_PI_4)   b = ClickWheelButtonPlayPause;
        else                                      b = ClickWheelButtonPrevious;
        [self.delegate clickWheel:self didPressButton:b];
    }
    [self resetTracking];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self resetTracking];
}

@end
