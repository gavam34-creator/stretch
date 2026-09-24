#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static CGFloat targetAspect = 16.0 / 10.0;
static CGRect (*orig_bounds)(id, SEL);

static CGRect hook_bounds(id self, SEL _cmd) {
    CGRect real = orig_bounds(self, _cmd);
    CGFloat h = real.size.height;
    CGFloat w = h * targetAspect;
    return CGRectMake(real.origin.x, real.origin.y, w, h);
}

__attribute__((constructor))
static void init_hook(void) {
    Class cls = objc_getClass("UIScreen");
    Method m = class_getInstanceMethod(cls, @selector(bounds));
    orig_bounds = (CGRect (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_bounds);
}