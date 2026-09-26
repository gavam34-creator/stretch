#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdio.h>
#include <math.h>

// =============================================================================
//  WORKUP STRETCH — 4:3 на весь экран, БЕЗ чёрных полос.  arm64e, PUBG VNG 4.6
//
//  УСТАНОВЛЕНО (анализ ShadowTrackerExtra, cryptid=0, base 0x100000000):
//   vaddr 0x107556605 -> "UEnums.EAspectRatioAxisConstraint =
//        {AspectRatio_MaintainYFOV=0, AspectRatio_MaintainXFOV=1,
//         AspectRatio_MajorAxisFOV=2, ...}"
//   => чёрные полосы = MaintainYFOV: движок вписывает 4:3, сохраняя верт. FOV.
//   => "MaintainXFOV" (1) убирает полосы, но живёт по оффсету внутри движка.
//
//  РЕШЕНИЕ БЕЗ ОФФСЕТОВ: горизонтальный масштаб CAMetalLayer.
//   1) спуфим UIScreen.bounds -> 4:3 (w = h * 1.3333), движок рисует 4:3;
//   2) масштабируем слой рендера по X в S = (W/H)/aspect. Чёрные поля уходят
//      за края экрана, 4:3-кадр занимает всю ширину => полос нет.
// =============================================================================

static double g_aspect = 1440.0 / 1080.0;  // 4:3 = 1.3333
static volatile int g_spoofOn = 0;          // вкл. через 7 сек

static CGRect (*orig_bounds)(id, SEL)       = NULL;
static CGRect (*orig_nativeBounds)(id, SEL) = NULL;

static UIWindow *g_win = nil;
static UILabel   *g_valLabel = nil;
static UISlider  *g_slider = nil;

// ---------------------------------------------------------------- спуфинг 4:3
static CGRect spoof43(CGRect r) {
    if (!g_spoofOn) return r;
    if (g_aspect <= 0.01) return r;
    CGFloat w = r.size.width, h = r.size.height;
    if (w <= 0 || h <= 0 || w <= h) return r;
    CGFloat nw = round(h * g_aspect);
    if (nw < 64 || nw > w * 3.0f) return r;
    return CGRectMake(r.origin.x + (w - nw) * 0.5f, r.origin.y, nw, h);
}
static CGRect hook_bounds(id s, SEL c) {
    @try { return spoof43(orig_bounds ? orig_bounds(s, c) : CGRectZero); }
    @catch (id e) { return orig_bounds ? orig_bounds(s, c) : CGRectZero; }
}
static CGRect hook_nativeBounds(id s, SEL c) {
    @try { return spoof43(orig_nativeBounds ? orig_nativeBounds(s, c) : CGRectZero); }
    @catch (id e) { return orig_nativeBounds ? orig_nativeBounds(s, c) : CGRectZero; }
}

// ------------------------------------------------- растяжка слоя рендера по X
//  S = (W/H) / aspect   — самокалибровка по собственному размеру слоя
static void stretchMetalLayer(CALayer *l) {
    if (!g_spoofOn || g_aspect <= 0.01) return;
    @try {
        CGRect f = l.frame;
        CGFloat W = f.size.width, H = f.size.height;
        if (!(W > 1.0) || !(H > 1.0)) return;           // отсекаем NaN и мусор
        if (!isfinite(W) || !isfinite(H)) return;
        if (!isfinite(f.origin.x) || !isfinite(f.origin.y)) return;
        CGFloat S = (W / H) / g_aspect;                 // 19.5:9 / 4:3 = ~1.626
        if (!isfinite(S) || S <= 1.002 || S > 4.0) return;   // ВАЖНО: проверка NaN
        CGFloat cx = f.origin.x + W * 0.5f;
        CGFloat cy = f.origin.y + H * 0.5f;
        if (!isfinite(cx) || !isfinite(cy)) return;
        // растяжение относительно центра: T(-c) * Scale(S,1) * T(c)
        CGAffineTransform t =
            CGAffineTransformConcat(CGAffineTransformMakeTranslation(-cx, -cy),
              CGAffineTransformConcat(CGAffineTransformMakeScale(S, 1.0),
                                      CGAffineTransformMakeTranslation(cx, cy)));
        if (!CGAffineTransformIsIdentity(l.affineTransform) && !l.affineTransform.a &&
            !l.affineTransform.d)
            fprintf(stderr, "[Stretch] stretch: layer=%.0fx%.0f S=%.4f\n", W, H, S);
        if (!CGAffineTransformEqualToTransform(l.affineTransform, t))
            l.affineTransform = t;
    } @catch (id e) {}
}

// -------- обход дерева слоёв: ищем CAMetalLayer, кэшируем, тянем каждый кадр
static NSMutableArray *g_metalLayers = nil;

static void findMetalLayers(void) {
    @try {
        Class ml = NSClassFromString(@"CAMetalLayer");
        if (!ml) return;
        if (g_metalLayers) [g_metalLayers removeAllObjects];
        else g_metalLayers = [NSMutableArray array];
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if ((id)w == (id)g_win) continue;              // меню не трогаем
            NSMutableArray *q = [NSMutableArray arrayWithObject:w.layer];
            while (q.count) {
                CALayer *l = q.firstObject;
                [q removeObjectAtIndex:0];
                if ([l isKindOfClass:ml]) [g_metalLayers addObject:l];
                for (CALayer *sub in (NSArray *)l.sublayers) [q addObject:sub];
            }
        }
    } @catch (id e) {}
}

static void stretchAllMetalLayers(void) {
    if (!g_spoofOn || g_aspect <= 0.01) return;
    if (!g_metalLayers.count) findMetalLayers();
    for (CALayer *l in (NSArray *)g_metalLayers) {
        if (!l) continue;
        @try {
            if (l.superlayer) stretchMetalLayer(l);
        } @catch (id e) {}
    }
}

@interface StretchMenu : NSObject
+ (void)show; + (void)hide; + (void)pick:(id)s;
+ (void)sliderChanged:(id)s; + (void)toggle:(id)s;
+ (void)onFrame:(id)s;
@end

static void startStretcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                findMetalLayers();
                fprintf(stderr, "[Stretch] metal layers found: %lu\n",
                        (unsigned long)g_metalLayers.count);
                CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:
                                     [StretchMenu class]
                                                             selector:@selector(onFrame:)];
                [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            } @catch (id e) {
                fprintf(stderr, "[Stretch] displaylink error: %s\n",
                        [[e description] UTF8String]);
            }
        });
    });
}

static void forceRereadBounds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UIDeviceOrientationDidChangeNotification object:nil];
        } @catch (id e) {}
    });
}

// ------------------------------------------------------------------- меню
@implementation StretchMenu

// вызывается CADisplayLink каждый кадр — накладываем масштаб заново,
// потому что движок сбрасывает геометрию слоя при resize
+ (void)onFrame:(id)s { stretchAllMetalLayers(); }

+ (UILabel *)lbl:(NSString *)t size:(CGFloat)s {
    UILabel *l = [UILabel new];
    l.text = t;
    l.font = [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightBold];
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}
+ (NSString *)fmt:(double)a {
    if (a <= 0.01) return @"Native (off)";
    return [NSString stringWithFormat:@"%.3f  (%.1f:1)", a, a];
}
+ (void)sliderChanged:(id)sender {
    g_aspect = ((UISlider *)sender).value;
    if (g_valLabel) g_valLabel.text = [self fmt:g_aspect];
    forceRereadBounds();
    stretchAllMetalLayers();
}
+ (UIButton *)btn:(NSString *)t aspect:(double)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.bounds = CGRectMake(0, 0, 220, 38);
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 8; b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightSemibold];
    b.accessibilityIdentifier = [NSString stringWithFormat:@"asp%.4f", a];
    [b addTarget:self action:@selector(pick:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}
+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_win) return;
        @try {
            g_win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            g_win.windowLevel = UIWindowLevelAlert + 100;
            g_win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

            UIView *v = [[UIView alloc] initWithFrame:g_win.bounds];
            v.backgroundColor = [UIColor clearColor];
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 400)];
            box.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.93];
            box.layer.cornerRadius = 14; box.layer.borderWidth = 1;
            box.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
            box.center = CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds));

            UILabel *title = [self lbl:@"STRETCH 4:3  (no bars)" size:15];
            title.frame = CGRectMake(0, 8, 250, 22);
            g_valLabel = [self lbl:[self fmt:g_aspect] size:15];
            g_valLabel.frame = CGRectMake(0, 32, 250, 22);

            g_slider = [[UISlider alloc] initWithFrame:CGRectMake(20, 58, 210, 30)];
            g_slider.minimumValue = 1.0;
            g_slider.maximumValue = 3.5;
            g_slider.value = (float)MAX(1.0, MIN(3.5, g_aspect));
            g_slider.minimumTrackTintColor = [UIColor systemGreenColor];
            g_slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.2];
            [g_slider addTarget:self action:@selector(sliderChanged:)
               forControlEvents:UIControlEventValueChanged];

            UILabel *hint = [self lbl:@"<- narrow        wide ->" size:10];
            hint.textColor = [UIColor colorWithWhite:1 alpha:0.5];
            hint.frame = CGRectMake(0, 86, 250, 16);

            NSArray *opts = @[@"Native (off)", @"4:3", @"16:9", @"20:9", @"21:9", @"24:9", @"32:9"];
            double asp[] = {0.0, 4.0/3.0, 16.0/9.0, 20.0/9.0, 21.0/9.0, 24.0/9.0, 32.0/9.0};
            CGFloat y = 106;
            for (NSUInteger i = 0; i < opts.count; i++) {
                UIButton *b = [self btn:opts[i] aspect:asp[i]];
                b.center = CGPointMake(125, y + 18);
                [box addSubview:b];
                y += 42;
            }
            UILabel *hint2 = [self lbl:@"3-finger double-tap = close" size:11];
            hint2.textColor = [UIColor colorWithWhite:1 alpha:0.5];
            hint2.frame = CGRectMake(0, 376, 250, 18);

            [box addSubview:title]; [box addSubview:g_valLabel]; [box addSubview:g_slider];
            [box addSubview:hint];  [box addSubview:hint2];
            [v addSubview:box];
            [v addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(hide)]];

            // без UIViewController: сначала пробуем просто окно
            [g_win addSubview:v];
            [g_win makeKeyAndVisible];
            if (!g_win.hidden) {
                // окно показалось без rootViewController — ок
            } else {
                g_win.rootViewController = [UIViewController new];
                g_win.rootViewController.view = v;
                [g_win makeKeyAndVisible];
            }
            fprintf(stderr, "[Stretch] menu shown aspect=%.3f\n", g_aspect);
        } @catch (id e) {
            fprintf(stderr, "[Stretch] menu error: %s\n",
                    [[e description] UTF8String]);
        }
    });
}
+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        g_win.hidden = YES; g_win = nil; g_slider = nil; g_valLabel = nil;
    });
}
+ (void)pick:(id)sender {
    g_aspect = ((UIButton *)sender).accessibilityIdentifier.doubleValue;
    [self hide];
    forceRereadBounds();
}
+ (void)toggle:(id)s { [self show]; }

@end

// ------------------------------------------------------------------ gesture
static void installGesture(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIWindow *w in UIApplication.sharedApplication.windows) {
                if (!w.isKeyWindow) continue;
                UITapGestureRecognizer *g =
                    [[UITapGestureRecognizer alloc] initWithTarget:[StretchMenu class]
                                                            action:@selector(toggle:)];
                g.numberOfTouchesRequired = 3;
                g.numberOfTapsRequired   = 2;
                g.cancelsTouchesInView   = NO;
                g.delaysTouchesBegan     = NO;
                [w addGestureRecognizer:g];
                break;
            }
        } @catch (id e) {}
    });
}

__attribute__((constructor))
static void init_stretch(void) {
    @autoreleasepool {
        fprintf(stderr, "[Stretch] init (aspect=%.3f)\n", g_aspect);
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                // --- 1. спуфинг экрана в 4:3 ---
                Class sc = [UIScreen mainScreen].class;
                Method mb = class_getInstanceMethod(sc, @selector(bounds));
                if (mb) {
                    orig_bounds = (CGRect(*)(id, SEL))method_getImplementation(mb);
                    method_setImplementation(mb, (IMP)hook_bounds);
                }
                Method mnb = class_getInstanceMethod(sc, @selector(nativeBounds));
                if (mnb) {
                    orig_nativeBounds = (CGRect(*)(id, SEL))method_getImplementation(mnb);
                    method_setImplementation(mnb, (IMP)hook_nativeBounds);
                }
                // Хуки setFrame/setBounds/setTransform на CALayer УБРАНЫ:
                // они били по всем слоям процесса и роняли игру.
                // Растяжку каждый кадр накладывает CADisplayLink (onFrame:).
                fprintf(stderr, "[Stretch] hooks installed (bounds/nativeBounds)\n");
            } @catch (id e) {
                fprintf(stderr, "[Stretch] hook error: %s\n", [[e description] UTF8String]);
            }

            // --- 3. вкл. спуфинг через 7 сек ---
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                g_spoofOn = 1;
                stretchAllMetalLayers();
                fprintf(stderr, "[Stretch] spoof on\n");
            });
        });
        dispatch_async(dispatch_get_main_queue(), ^{ installGesture(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ installGesture(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ startStretcher(); });
    }
}
