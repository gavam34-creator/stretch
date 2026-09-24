#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface UIScreen (Stretch)
@end

@implementation UIScreen (Stretch)
- (CGRect)stretch_bounds {
    CGRect real = [self stretch_bounds];
    if (real.size.height <= 0 || real.size.width <= 0) return real;
    
    CGFloat h = real.size.height;
    CGFloat w = h * (4.0 / 3.0); // <-- ТУТ 4:3
    CGFloat x = real.origin.x + (real.size.width - w) / 2.0;
    return CGRectMake(x, real.origin.y, w, h);
}
@end

__attribute__((constructor))
static void init_hook(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = objc_getClass("UIScreen");
        if (!cls) return;
        
        Method original = class_getInstanceMethod(cls, @selector(bounds));
        Method replacement = class_getInstanceMethod(cls, @selector(stretch_bounds));
        if (original && replacement) {
            method_exchangeImplementations(original, replacement);
        }
    });
}