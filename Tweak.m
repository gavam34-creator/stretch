#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static UIView *g_gameView = nil;
static BOOL    g_active   = NO;

static CGRect fs(void) { return [UIScreen mainScreen].bounds; }

static UIWindow *getWindow(void) {
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                w = ((UIWindowScene *)s).windows.firstObject;
                break;
            }
        }
    }
    return w ?: [UIApplication sharedApplication].windows.firstObject;
}

static UIView *findGameView(void) {
    UIWindow *w = getWindow();
    if (!w) return nil;
    CGFloat minArea = fs().size.width * fs().size.height * 0.25f;
    NSMutableArray *q = [NSMutableArray arrayWithObject:w];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        if ([NSStringFromClass(v.layer.class) isEqualToString:@"CAMetalLayer"]) {
            CGFloat a = v.bounds.size.width * v.bounds.size.height;
            if (a >= minArea) return v;
        }
        [q addObjectsFromArray:v.subviews];
    }
    return nil;
}

static void applyStretch(UIView *v) {
    CGRect full   = fs();
    CGFloat sx    = full.size.width  / v.bounds.size.width;
    CGFloat sy    = full.size.height / v.bounds.size.height;
    v.transform   = CGAffineTransformMakeScale(sx, sy);
    v.center      = CGPointMake(CGRectGetMidX(full), CGRectGetMidY(full));
}

static void (*orig_setTransform)(UIView *, SEL, CGAffineTransform);
static void hook_setTransform(UIView *self, SEL _cmd, CGAffineTransform t) {
    if (g_active && self == g_gameView) return;
    orig_setTransform(self, _cmd, t);
}

@interface VNTATicker : NSObject
@end
@implementation VNTATicker
+ (void)start {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:[self new]
                                                        selector:@selector(tick:)];
        dl.preferredFramesPerSecond = 30;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}
- (void)tick:(CADisplayLink *)dl {
    if (!g_gameView) {
        g_gameView = findGameView();
        if (g_gameView) { g_active = YES; applyStretch(g_gameView); }
        return;
    }
    CGAffineTransform cur = g_gameView.transform;
    if (fabs(cur.a - 1.0f) < 0.01f) applyStretch(g_gameView);
}
@end

__attribute__((constructor))
static void init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Method m = class_getInstanceMethod([UIView class], @selector(setTransform:));
        orig_setTransform = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_setTransform);
        [VNTATicker start];
    });
}
