#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static CALayer *g_target = nil;
static BOOL g_active = NO;

static CGRect fs(void) {
    return [UIScreen mainScreen].bounds;
}

static CALayer *findLayer(void) {
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                w = ((UIWindowScene *)s).windows.firstObject;
                break;
            }
        }
    }
    if (!w) w = [UIApplication sharedApplication].windows.firstObject;
    if (!w) return nil;

    CGFloat minArea = fs().size.width * fs().size.height * 0.3f;
    NSMutableArray *q = [NSMutableArray arrayWithObject:w.layer];
    while (q.count) {
        CALayer *l = q.firstObject; [q removeObjectAtIndex:0];
        if ([NSStringFromClass(l.class) isEqualToString:@"CAMetalLayer"]) {
            if (l.bounds.size.width * l.bounds.size.height >= minArea)
                return l;
        }
        if (l.sublayers) [q addObjectsFromArray:l.sublayers];
    }
    return nil;
}

static void applyStretch(CALayer *l) {
    CGRect full = fs();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.frame           = full;
    l.position        = CGPointMake(CGRectGetMidX(full), CGRectGetMidY(full));
    l.contentsGravity = kCAGravityResize;
    l.contentsRect    = CGRectMake(0, 0, 1, 1);
    [CATransaction commit];
}

static void (*orig_setFrame)(CALayer *, SEL, CGRect);
static void hook_setFrame(CALayer *self, SEL _cmd, CGRect frame) {
    if (g_active && self == g_target) {
        orig_setFrame(self, _cmd, fs());
        return;
    }
    orig_setFrame(self, _cmd, frame);
}

static void (*orig_setContentsGravity)(CALayer *, SEL, NSString *);
static void hook_setContentsGravity(CALayer *self, SEL _cmd, NSString *gravity) {
    if (g_active && self == g_target) {
        orig_setContentsGravity(self, _cmd, kCAGravityResize);
        return;
    }
    orig_setContentsGravity(self, _cmd, gravity);
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
    if (!g_target) {
        g_target = findLayer();
        if (g_target) {
            g_active = YES;
            applyStretch(g_target);
        }
    }
    if (!g_target) return;
    if (!CGRectEqualToRect(g_target.frame, fs()) ||
        ![g_target.contentsGravity isEqualToString:kCAGravityResize]) {
        applyStretch(g_target);
    }
}
@end

__attribute__((constructor))
static void init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = [CALayer class];

        Method mf = class_getInstanceMethod(cls, @selector(setFrame:));
        orig_setFrame = (void *)method_getImplementation(mf);
        method_setImplementation(mf, (IMP)hook_setFrame);

        Method mg = class_getInstanceMethod(cls, @selector(setContentsGravity:));
        orig_setContentsGravity = (void *)method_getImplementation(mg);
        method_setImplementation(mg, (IMP)hook_setContentsGravity);

        [VNTATicker start];
    });
}
