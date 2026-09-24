#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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

// --- Принудительное центрирование и растягивание окна ---
static void applyStretchToWindow(UIWindow *window) {
    if (!window) return;
    
    // Получаем физический размер экрана в точках
    UIScreen *screen = [UIScreen mainScreen];
    CGRect nativeBounds = [screen nativeBounds];
    CGFloat scale = [screen scale];
    if (scale <= 0) scale = 1.0;
    
    CGFloat physW = nativeBounds.size.width / scale;
    CGFloat physH = nativeBounds.size.height / scale;
    
    if (physW <= 0 || physH <= 0) return;
    
    // Текущий размер окна (должен быть 4:3 после хука UIScreen)
    CGSize winSize = window.bounds.size;
    if (winSize.width <= 0 || winSize.height <= 0) return;
    
    // Сбрасываем предыдущий трансформ, чтобы не накапливать
    window.layer.transform = CATransform3DIdentity;
    
    // Считаем, во сколько раз нужно растянуть
    CGFloat scaleX = physW / winSize.width;
    CGFloat scaleY = physH / winSize.height;
    
    // Применяем масштаб
    window.layer.transform = CATransform3DMakeScale(scaleX, scaleY, 1.0);
    
    // Жёстко ставим окно в центр экрана
    window.center = CGPointMake(physW / 2.0, physH / 2.0);
}

__attribute__((constructor))
static void init_hook(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        // Ставим хук на UIScreen
        Class cls = objc_getClass("UIScreen");
        if (cls) {
            Method orig = class_getInstanceMethod(cls, @selector(bounds));
            Method repl = class_getInstanceMethod(cls, @selector(stretch_bounds));
            if (orig && repl) method_exchangeImplementations(orig, repl);
        }
        
        // Цикл для постоянного контроля (игра может пересоздавать окна)
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
                [NSThread sleepForTimeInterval:0.2]; // каждые 0.2 сек достаточно
            }
        });
    }];
}