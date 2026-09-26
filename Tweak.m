#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>
#import <stdio.h>
#import <stdlib.h>

// ---------------------------------------------------------------------------
// Спуффинг разрешения экрана через UIScreen (без Dobby, без оффсетов игры).
// ЦЕЛЬ: «ПК-шный» вид — сузить вьюпорт до 4:3 (1.333) или 16:9 (1.778),
// чтобы игра рисовала в узкой рамке с чёрными полосами по бокам, как на ПК.
// (Это УЖЕ нативных 19.5:9 = 2.167, в отличие от «широкой» растяжки.)
//
//   1.0  -> нативное разрешение (без подмены)
//   1.333-> 4:3  (классика)
//   1.778-> 16:9
// ---------------------------------------------------------------------------
static double targetAspect = 4.0 / 3.0;

static CGRect (*orig_bounds)(id, SEL);
static CGRect (*orig_nativeBounds)(id, SEL);
static CGRect (*orig_scale)(id, SEL);

static CGRect spoof(CGRect r) {
    if (targetAspect <= 1.0001) return r;            // выключено
    CGFloat w = r.size.width, h = r.size.height;
    if (w <= 0 || h <= 0) return r;
    if (w <= h) return r;                            // портрет — не трогаем
    CGFloat newW = round(h * targetAspect);
    if (newW < 64 || newW > w * 2.0f) return r;      // защита от абсурда
    CGFloat dx = (w - newW) * 0.5f;                  // центрируем по X (pillarbox)
    return CGRectMake(r.origin.x + dx, r.origin.y, newW, h);
}

static CGRect hook_bounds(id self, SEL _cmd) {
    CGRect r = orig_bounds ? orig_bounds(self, _cmd) : CGRectZero;
    return spoof(r);
}

static CGRect hook_nativeBounds(id self, SEL _cmd) {
    CGRect r = orig_nativeBounds ? orig_nativeBounds(self, _cmd) : CGRectZero;
    return spoof(r);
}

static CGRect hook_scale(id self, SEL _cmd) {
    CGRect r = orig_scale ? orig_scale(self, _cmd) : CGRectZero;
    return spoof(r);
}

__attribute__((constructor))
static void init_spoof(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class cls = [UIScreen mainScreen].class;
            if (!cls) { fprintf(stderr, "[Stretch] UIScreen not found\n"); return; }

            // bounds
            Method mb = class_getInstanceMethod(cls, @selector(bounds));
            if (mb) {
                orig_bounds = (CGRect(*)(id, SEL))method_getImplementation(mb);
                method_setImplementation(mb, (IMP)hook_bounds);
            }
            // nativeBounds
            Method mnb = class_getInstanceMethod(cls, @selector(nativeBounds));
            if (mnb) {
                orig_nativeBounds = (CGRect(*)(id, SEL))method_getImplementation(mnb);
                method_setImplementation(mnb, (IMP)hook_nativeBounds);
            }
            // scale (iOS13+)
            Method ms = class_getInstanceMethod(cls, @selector(scale));
            if (ms) {
                orig_scale = (CGRect(*)(id, SEL))method_getImplementation(ms);
                method_setImplementation(ms, (IMP)hook_scale);
            }
            fprintf(stderr, "[Stretch] UIScreen spoof installed, aspect=%.3f\n", targetAspect);
        });
    }
}
