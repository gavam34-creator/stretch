#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdio.h>

// =============================================================================
//  WORKUP STRETCH — меню: открывается 2/3-пальцевым тапом, выбор aspect.
//  Широкие aspect (>= 19.5:9) убирают чёрные полосы. Меняется на лету.
// =============================================================================

static double g_aspect = 4.0 / 3.0;   // текущий (меняется из меню)

static void (*orig_bounds)(id, SEL);
static void (*orig_nativeBounds)(id, SEL);

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
+ (void)toggleMenu:(id)sender;
@end

static UIWindow *g_win = nil;

@implementation StretchMenu

+ (UILabel *)mkLabel:(NSString *)t size:(CGFloat)s {
    UILabel *l = [UILabel new];
    l.text = t; l.font = [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightBold];
    l.textColor = [UIColor whiteColor]; l.textAlignment = NSTextAlignmentCenter;
    return l;
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

        UILabel *title = [self mkLabel:@"STRETCH ASPECT" size:17];
        title.frame = CGRectMake(0,10,250,26);

        NSArray *opts = @[@"Native  (off)",@"4:3   1.333",@"16:9  1.778",@"19.5:9 2.167",
                          @"20:9  2.222",@"21:9  2.333",@"24:9  2.667",@"32:9  3.556"];
        double asp[] = {0.0, 4.0/3.0, 16.0/9.0, 19.5/9.0, 20.0/9.0, 21.0/9.0, 24.0/9.0, 32.0/9.0};

        CGFloat y = 42;
        for (NSUInteger i = 0; i < opts.count; i++) {
            UIButton *b = [self mkBtn:opts[i] aspect:asp[i]];
            b.center = CGPointMake(125, y + 19);
            [box addSubview:b];
            y += 44;
        }
        UILabel *hint = [self mkLabel:@"2/3-finger tap = toggle" size:11];
        hint.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        hint.frame = CGRectMake(0,400,250,20);

        [box addSubview:title]; [box addSubview:hint];
        [v addSubview:box];
        // тап вне меню — закрыть
        UITapGestureRecognizer *close = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hide)];
        [v addGestureRecognizer:close];

        g_win.rootViewController = [UIViewController new];
        g_win.rootViewController.view = v;
        [g_win makeKeyAndVisible];
        fprintf(stderr, "[Stretch] menu shown\n");
    });
}

+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        g_win.hidden = YES; g_win.rootViewController = nil; g_win = nil;
        fprintf(stderr, "[Stretch] menu hidden, aspect=%.3f\n", g_aspect);
    });
}

+ (void)pick:(id)sender {
    UIButton *b = (UIButton *)sender;
    double a = b.accessibilityIdentifier.doubleValue;
    g_aspect = a;
    [self hide];
}

+ (void)toggleMenu:(id)sender { [self show]; }

@end

// gesture: 2- и 3-пальцевый тап
static void installGesture(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.isKeyWindow) continue;
            for (int n = 2; n <= 3; n++) {
                UITapGestureRecognizer *g =
                    [[UITapGestureRecognizer alloc] initWithTarget:[StretchMenu class]
                                                            action:@selector(toggleMenu:)];
                g.numberOfTouchesRequired = n;
                [w addGestureRecognizer:g];
            }
            break;
        }
        fprintf(stderr, "[Stretch] gesture installed (2/3-finger tap)\n");
    });
}

__attribute__((constructor))
static void init_stretch(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class cls = [UIScreen mainScreen].class;
            Method mb = class_getInstanceMethod(cls, @selector(bounds));
            if (mb) { orig_bounds = (void*)method_getImplementation(mb);
                      method_setImplementation(mb, (IMP)hook_bounds); }
            Method mnb = class_getInstanceMethod(cls, @selector(nativeBounds));
            if (mnb) { orig_nativeBounds = (void*)method_getImplementation(mnb);
                       method_setImplementation(mnb, (IMP)hook_nativeBounds); }
            fprintf(stderr, "[Stretch] init aspect=%.3f\n", g_aspect);
        });
        // gesture чуть позже, когда окно готово
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ installGesture(); });
    }
}
