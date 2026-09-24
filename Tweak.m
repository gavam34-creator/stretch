#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static CGFloat targetAspect = 4.0 / 3.0;

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

static void applyStretchToWindow(UIWindow *window) {
    if (!window) return;

    UIScreen *screen = [window screen];
    if (!screen) return;

    CGRect nativeBounds = [screen nativeBounds];
    CGFloat scale = [screen scale];
    if (scale <= 0) scale = 1.0;

    CGFloat physW = nativeBounds.size.width / scale;
    CGFloat physH = nativeBounds.size.height / scale;
    if (physW <= 0 || physH <= 0) return;

    CGSize winSize = window.bounds.size;
    if (winSize.width <= 0 || winSize.height <= 0) return;

    CGFloat scaleX = physW / winSize.width;
    CGFloat scaleY = physH / winSize.height;

    // Сброс трансформа (ручной identity, без QuartzCore)
    CATransform3D identity;
    identity.m11 = 1.0; identity.m12 = 0; identity.m13 = 0; identity.m14 = 0;
    identity.m21 = 0; identity.m22 = 1.0; identity.m23 = 0; identity.m24 = 0;
    identity.m31 = 0; identity.m32 = 0; identity.m33 = 1.0; identity.m34 = 0;
    identity.m41 = 0; identity.m42 = 0; identity.m43 = 0; identity.m44 = 1.0;
    window.layer.transform = identity;

    // Масштаб (ручной, без QuartzCore)
    CATransform3D scaleT;
    scaleT.m11 = scaleX; scaleT.m12 = 0;      scaleT.m13 = 0; scaleT.m14 = 0;
    scaleT.m21 = 0;      scaleT.m22 = scaleY; scaleT.m23 = 0; scaleT.m24 = 0;
    scaleT.m31 = 0;      scaleT.m32 = 0;      scaleT.m33 = 1.0; scaleT.m34 = 0;
    scaleT.m41 = 0;      scaleT.m42 = 0;      scaleT.m43 = 0; scaleT.m44 = 1.0;
    window.layer.transform = scaleT;

    // Центрируем окно на физическом экране
    window.center = CGPointMake(physW / 2.0, physH / 2.0);
}

__attribute__((constructor))
static void init_hook(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        Class cls = objc_getClass("UIScreen");
        if (cls) {
            Method orig = class_getInstanceMethod(cls, @selector(bounds));
            Method repl = class_getInstanceMethod(cls, @selector(stretch_bounds));
            if (orig && repl) method_exchangeImplementations(orig, repl);
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            while (1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIApplication *app = [UIApplication sharedApplication];
                    if (!app) return;
                    for (UIScene *scene in app.connectedScenes) {
                        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                        UIWindowScene *ws = (UIWindowScene *)scene;
                        for (UIWindow *window in ws.windows) {
                            applyStretchToWindow(window);
                        }
                    }
                });
                [NSThread sleepForTimeInterval:0.2];
            }
        });
    }];
}