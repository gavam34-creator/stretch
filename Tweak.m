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

__attribute__((constructor))
static void init_hook(void) {
    // Ждём, пока приложение полностью запустится и станет активным
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        Class cls = objc_getClass("UIScreen");
        if (!cls) return;
        Method orig = class_getInstanceMethod(cls, @selector(bounds));
        Method repl = class_getInstanceMethod(cls, @selector(stretch_bounds));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
        }
    }];
}