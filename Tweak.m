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

// Рекурсивно ставит гравити "resize" (растянуть без сохранения пропорций) на слой и все подслои
static void forceStretch(CALayer *layer) {
    if (!layer) return;
    layer.contentsGravity = @"resize";
    layer.masksToBounds = NO;
    NSArray *subs = layer.sublayers;
    for (CALayer *sub in subs) {
        forceStretch(sub);
    }
}

// Находим корневой слой игры и растягиваем его
static void stretchAllWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *window in ws.windows) {
            forceStretch(window.layer);
        }
    }
}

__attribute__((constructor))
static void init_hook(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        // 1. Хук UIScreen.bounds → 4:3 (игра рендерит в 4:3)
        Class cls = objc_getClass("UIScreen");
        if (cls) {
            Method orig = class_getInstanceMethod(cls, @selector(bounds));
            Method repl = class_getInstanceMethod(cls, @selector(stretch_bounds));
            if (orig && repl) method_exchangeImplementations(orig, repl);
        }

        // 2. Цикл: каждые 0.2 сек насильно ставим "resize" на все слои
        //    Это заставляет iOS растянуть 4:3 картинку на весь экран
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            while (1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    stretchAllWindows();
                });
                [NSThread sleepForTimeInterval:0.2];
            }
        });
    }];
}