#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static CGFloat targetAspect = 4.0 / 3.0;

// --- Хук UIScreen.bounds ---
@interface UIScreen (Stretch)
@end
@implementation UIScreen (Stretch)
- (CGRect)stretch_bounds {
    CGRect real = [self stretch_bounds];
    if (real.size.height <= 0 || real.size.width <= 0) return real;
    CGFloat h = real.size.height;
    CGFloat w = h * targetAspect;
    return CGRectMake(0, 0, w, h);
}
@end

// --- Хук UIWindow.bounds ---
@interface UIWindow (Stretch)
@end
@implementation UIWindow (Stretch)
- (CGRect)stretch_bounds {
    CGRect real = [self stretch_bounds];
    if (real.size.height <= 0 || real.size.width <= 0) return real;
    CGFloat h = real.size.height;
    CGFloat w = h * targetAspect;
    return CGRectMake(0, 0, w, h);
}
@end

// --- Форсим растяжение всех слоёв (убирает чёрные полосы) ---
static void applyStretch(CALayer *layer) {
    if (!layer) return;
    layer.contentsGravity = kCAGravityResize;
    NSArray *sublayers = layer.sublayers;
    for (CALayer *sub in sublayers) {
        applyStretch(sub);
    }
}

static void applyStretchToAllWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *window in ws.windows) {
            applyStretch(window.layer);
        }
    }
}

__attribute__((constructor))
static void init_hook(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class screenCls = objc_getClass("UIScreen");
        if (screenCls) {
            Method orig = class_getInstanceMethod(screenCls, @selector(bounds));
            Method repl = class_getInstanceMethod(screenCls, @selector(stretch_bounds));
            if (orig && repl) method_exchangeImplementations(orig, repl);
        }
        Class windowCls = objc_getClass("UIWindow");
        if (windowCls) {
            Method orig = class_getInstanceMethod(windowCls, @selector(bounds));
            Method repl = class_getInstanceMethod(windowCls, @selector(stretch_bounds));
            if (orig && repl) method_exchangeImplementations(orig, repl);
        }
        // Каждые 2 секунды форсим растяжение слоёв — лечит полосы
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            while (1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    applyStretchToAllWindows();
                });
                [NSThread sleepForTimeInterval:2.0];
            }
        });
    });
}