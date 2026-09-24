#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static CGFloat targetAspect = 16.0 / 10.0;

static CGRect (*orig_bounds)(id, SEL);

static CGRect hook_bounds(id self, SEL _cmd) {
    CGRect real = orig_bounds(self, _cmd);
    CGFloat h = real.size.height;
    CGFloat w = h * targetAspect;
    return CGRectMake(real.origin.x, real.origin.y, w, h);
}

%ctor {
    MSHookMessageEx(objc_getClass("UIScreen"), @selector(bounds), (IMP)&hook_bounds, (IMP*)&orig_bounds);
}
