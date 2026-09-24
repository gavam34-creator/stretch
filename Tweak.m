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

    CGFloat minArea = fs().size.width * fs().size.height * 0.5f;
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

static void (*orig_setFrame)(CALayer *, SEL, CGRect);
static void hook_setFrame(CALayer *self, SEL _cmd, CGRect frame) {
    if (g_active && self == g_target) {
        orig_setFrame(self, _cmd, fs());
        return;
    }
    orig_setFrame(self, _cmd, frame);
}

@interface VNTATicker : NSObject
@end
@implementation VNTATicker
+ (void)start {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:[self new]
                                                        selector:@selector(tick:)];
        dl.preferredFramesPerSecond = 10;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}
- (void)tick:(CADisplayLink *)dl {
    if (!g_target) {
        g_target = findLayer();
        if (g_target) g_active = YES;
    }
    if (!g_target) return;
    CGRect full = fs();
    if (!CGRectEqualToRect(g_target.frame, full)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g_target.frame = full;
        g_target.position = CGPointMake(CGRectGetMidX(full), CGRectGetMidY(full));
        [CATransaction commit];
    }
}
@end

__attribute__((constructor))
static void init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Method m = class_getInstanceMethod([CALayer class], @selector(setFrame:));
        orig_setFrame = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_setFrame);
        [VNTATicker start];
    });
}
