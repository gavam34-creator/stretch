#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <QuartzCore/QuartzCore.h>

// =============================================================================
//  WORKUP STRETCH — меню: открывается 3-пальцевым двойным тапом, выбор aspect.
//  Дефолт: 1440x1080 (4:3). Кадр ПРИНУДИТЕЛЬНО растягивается на весь экран
//  (contentsGravity=resize) -> растяжка без чёрных полос.
// =============================================================================

// Текущий aspect. По умолчанию 1440x1080 = 4:3 (1.333) — «ПК-вид».
static double g_aspect = 1440.0 / 1080.0;   // 4:3

// Игра кэширует размер экрана. Чтобы смена aspect применилась — шлём
// уведомление об ориентации, чтобы движок перечитал bounds и перестроил вьюпорт.
static void forceRereadBounds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UIDeviceOrientationDidChangeNotification object:nil];
    });
}

// ---- РАСТЯЖКА БЕЗ ПОЛОС: заставляем Metal-слой растягивать кадр на весь экран
// 1) рекурсивно ищем все CAMetalLayer в окнах приложения
// 2) ставим contentsGravity = kCAGravityResize => 4:3-кадр тянется на всю ширину
static void fixLayersIn(CALayer *l, int depth) {
    if (!l) return;
    Class ml = NSClassFromString(@"CAMetalLayer");
    if (ml && [l isKindOfClass:ml]) {
        l.contentsGravity = @"resize";   // растянуть (не сохранять пропорции) -> без полос
        if (depth <= 2)
            fprintf(stderr, "[Stretch] metal layer bounds=(%.0f x %.0f) gravity=%@\n",
                    l.bounds.size.width, l.bounds.size.height, l.contentsGravity);
    }
    for (CALayer *s in (NSArray *)l.sublayers) fixLayersIn(s, depth + 1);
}
static void fixAllLayers(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        fixLayersIn(w.layer, 0);
        fixLayersIn(w.rootViewController.view.layer, 0);
    }
}
static void startLayerFixer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_get_main_queue();
        __block void (^tick)(void);
        tick = ^{
            fixAllLayers();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), q, tick);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), q, tick);
    });
}

static CGRect (*orig_bounds)(id, SEL) = NULL;
static CGRect (*orig_nativeBounds)(id, SEL) = NULL;

static CGRect spoof(CGRect r) {
    if (g_aspect <= 0.01) return r;                    // выключено
    CGFloat w = r.size.width, h = r.size.height;
    if (w <= 0 || h <= 0 || w <= h) return r;
    CGFloat nw = round(h * g_aspect);
    if (nw < 64 || nw > w * 3.0f) return r;
    return CGRectMake(r.origin.x + (w - nw) * 0.5f, r.origin.y, nw, h);
}
static CGRect hook_bounds(id s, SEL c) {
    return spoof(orig_bounds ? orig_bounds(s, c) : CGRectZero);
}
static CGRect hook_nativeBounds(id s, SEL c) {
    return spoof(orig_nativeBounds ? orig_nativeBounds(s, c) : CGRectZero);
}

// ---------------------------------------------------------------- меню
@interface StretchMenu : NSObject
+ (void)show;
+ (void)hide;
+ (void)pick:(id)sender;
+ (void)sliderChanged:(id)sender;
+ (void)toggleMenu:(id)sender;
@end

static UIWindow *g_win = nil;
static UILabel *g_valLabel = nil;
static UISlider *g_slider = nil;

@implementation StretchMenu

+ (UILabel *)mkLabel:(NSString *)t size:(CGFloat)s {
    UILabel *l = [UILabel new];
    l.text = t; l.font = [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightBold];
    l.textColor = [UIColor whiteColor]; l.textAlignment = NSTextAlignmentCenter;
    return l;
}

+ (NSString *)fmtAspect:(double)a {
    if (a <= 0.01) return @"Native (off)";
    return [NSString stringWithFormat:@"%.3f  (%.1f:1)%@", a, a,
            (a <= 2.20 ? @"  [bars]" : @"  [no bars]")];
}

+ (void)updateLabel {
    if (g_valLabel) g_valLabel.text = [self fmtAspect:g_aspect];
}

+ (void)sliderChanged:(id)sender {
    UISlider *s = (UISlider *)sender;
    g_aspect = s.value;
    [self updateLabel];
    forceRereadBounds();   // заставить игру перечитать bounds
}

+ (UIButton *)mkBtn:(NSString *)t aspect:(double)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0,0,220,38);
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
        g_win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        g_win.windowLevel = UIWindowLevelAlert + 100;
        g_win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

        UIView *v = [UIView new];
        v.frame = g_win.bounds; v.backgroundColor = [UIColor clearColor];

        UIView *box = [UIView new];
        box.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.92];
        box.layer.cornerRadius = 14; box.layer.borderWidth = 1;
        box.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
        box.bounds = CGRectMake(0,0,250,430);
        box.center = CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds));

        UILabel *title = [self mkLabel:@"STRETCH  (drag = sides)" size:16];
        title.frame = CGRectMake(0,10,250,24);

        // ---- ползунок ширины (высота держится, тянешь вбок) ----
        g_valLabel = [self mkLabel:[self fmtAspect:g_aspect] size:15];
        g_valLabel.frame = CGRectMake(0,40,250,22);

        g_slider = [UISlider new];
        g_slider.minimumValue = 1.0;      // узко (полосы)
        g_slider.maximumValue = 3.5;      // ультра-широко
        g_slider.value = (float)MAX(1.0, MIN(3.5, g_aspect));
        g_slider.frame = CGRectMake(20,68,210,32);
        g_slider.minimumTrackTintColor = [UIColor systemGreenColor];
        g_slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.2];
        [g_slider addTarget:self action:@selector(sliderChanged:)
           forControlEvents:UIControlEventValueChanged];

        UILabel *hintW = [self mkLabel:@"<- narrow        wide ->" size:10];
        hintW.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        hintW.frame = CGRectMake(0,98,250,16);

        // ---- быстрые пресеты ----
        NSArray *opts = @[@"Native 19.5:9 (off)",@"4:3",@"16:9",@"20:9",@"21:9",@"24:9",@"32:9"];
        double asp[] = {0.0, 4.0/3.0, 16.0/9.0, 20.0/9.0, 21.0/9.0, 24.0/9.0, 32.0/9.0};
        CGFloat y = 122;
        for (NSUInteger i = 0; i < opts.count; i++) {
            UIButton *b = [self mkBtn:opts[i] aspect:asp[i]];
            b.center = CGPointMake(125, y + 18);
            [box addSubview:b];
            y += 42;
        }

        UILabel *hint = [self mkLabel:@"3-finger double-tap = close" size:11];
        hint.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        hint.frame = CGRectMake(0,404,250,20);

        [box addSubview:title]; [box addSubview:g_valLabel];
        [box addSubview:g_slider]; [box addSubview:hintW]; [box addSubview:hint];
        [v addSubview:box];
        UITapGestureRecognizer *close = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hide)];
        [v addGestureRecognizer:close];

        g_win.rootViewController = [UIViewController new];
        g_win.rootViewController.view = v;
        [g_win makeKeyAndVisible];
        fprintf(stderr, "[Stretch] menu shown, aspect=%.3f\n", g_aspect);
    });
}

+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        g_win.hidden = YES; g_win.rootViewController = nil; g_win = nil;
        g_slider = nil; g_valLabel = nil;
        fprintf(stderr, "[Stretch] menu hidden, aspect=%.3f\n", g_aspect);
    });
}

+ (void)pick:(id)sender {
    UIButton *b = (UIButton *)sender;
    g_aspect = b.accessibilityIdentifier.doubleValue;
    [self hide];
    forceRereadBounds();   // применить
}

+ (void)toggleMenu:(id)sender { [self show]; }

@end

// gesture: ТОЛЬКО 3-пальцевый ДВОЙНОЙ тап — чтобы меню случайно не открывалось в бою
static void installGesture(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.isKeyWindow) continue;
            UITapGestureRecognizer *g =
                [[UITapGestureRecognizer alloc] initWithTarget:[StretchMenu class]
                                                        action:@selector(toggleMenu:)];
            g.numberOfTouchesRequired = 3;   // три пальца
            g.numberOfTapsRequired   = 2;    // два раза
            g.cancelsTouchesInView   = NO;   // не блокируем игру
            g.delaysTouchesBegan     = NO;
            [w addGestureRecognizer:g];
            break;
        }
        fprintf(stderr, "[Stretch] gesture: 3-finger DOUBLE tap\n");
    });
}

__attribute__((constructor))
static void init_stretch(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class cls = [UIScreen mainScreen].class;
            Method mb = class_getInstanceMethod(cls, @selector(bounds));
            if (mb) { orig_bounds = (CGRect(*)(id,SEL))method_getImplementation(mb);
                      method_setImplementation(mb, (IMP)hook_bounds); }
            Method mnb = class_getInstanceMethod(cls, @selector(nativeBounds));
            if (mnb) { orig_nativeBounds = (CGRect(*)(id,SEL))method_getImplementation(mnb);
                       method_setImplementation(mnb, (IMP)hook_nativeBounds); }
            fprintf(stderr, "[Stretch] init aspect=%.3f\n", g_aspect);
        });
        // gesture: ставим и сразу, и позже (на случай смены окон)
        dispatch_async(dispatch_get_main_queue(), ^{ installGesture(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ installGesture(); });
        // Растяжка кадра: периодически ставим Metal-слою contentsGravity=resize
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ startLayerFixer(); });
    }
}
