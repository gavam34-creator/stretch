#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static CGFloat targetAspect = 16.0 / 10.0;
static BOOL stretchEnabled = NO;

// --- UIScreen hooks ---
@interface UIScreen (Stretch)
@end
@implementation UIScreen (Stretch)

- (CGRect)stretch_bounds {
    CGRect real = [self stretch_bounds];
    if (!stretchEnabled) return real;
    if (real.size.height <= 0) return real;
    CGFloat h = real.size.height;
    CGFloat w = h * targetAspect;
    return CGRectMake(0, 0, w, h);
}

- (CGRect)stretch_nativeBounds {
    CGRect real = [self stretch_nativeBounds];
    if (!stretchEnabled) return real;
    if (real.size.height <= 0) return real;
    CGFloat h = real.size.height;
    CGFloat w = h * targetAspect;
    return CGRectMake(0, 0, w, h);
}

- (CGRect)stretch_applicationFrame {
    CGRect real = [self stretch_applicationFrame];
    if (!stretchEnabled) return real;
    if (real.size.height <= 0) return real;
    CGFloat h = real.size.height;
    CGFloat w = h * targetAspect;
    return CGRectMake(0, 0, w, h);
}

- (CGSize)stretch_currentModeSize {
    CGSize real = [self stretch_currentModeSize];
    if (!stretchEnabled) return real;
    if (real.height <= 0) return real;
    CGFloat h = real.height;
    CGFloat w = h * targetAspect;
    return CGSizeMake(w, h);
}

- (CGFloat)stretch_scale {
    CGFloat real = [self stretch_scale];
    return real; // scale не трогаем — иначе всё развалится
}

@end

// --- UIWindow hooks ---
@interface UIWindow (Stretch)
@end
@implementation UIWindow (Stretch)

- (CGRect)stretch_bounds {
    CGRect real = [self stretch_bounds];
    if (!stretchEnabled) return real;
    if (real.size.height <= 0) return real;
    CGFloat h = real.size.height;
    CGFloat w = h * targetAspect;
    return CGRectMake(0, 0, w, h);
}

- (CGRect)stretch_frame {
    CGRect real = [self stretch_frame];
    if (!stretchEnabled) return real;
    // Frame НЕ меняем — он определяет положение окна
    return real;
}

@end

// --- Форсируем перерисовку ---
static void forceLayout(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *window in ws.windows) {
            [window setNeedsLayout];
            [window layoutIfNeeded];
            for (UIView *sub in window.subviews) {
                [sub setNeedsLayout];
                [sub layoutIfNeeded];
                for (UIView *sub2 in sub.subviews) {
                    [sub2 setNeedsLayout];
                    [sub2 layoutIfNeeded];
                }
            }
        }
    }
}

// --- Форсируем rotation (чтобы UE4 пересчитал вьюпорт) ---
static void forceRotation(void) {
    // Постим уведомление — UE4 может пересчитать вьюпорт
    [[NSNotificationCenter defaultCenter] postNotificationName:UIDeviceOrientationDidChangeNotification
                                                        object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidChangeStatusBarOrientationNotification
                                                        object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationWillChangeStatusBarOrientationNotification
                                                        object:nil];
}

// --- Меню ---
@interface BPMenuView : UIView
@property (nonatomic, strong) UILabel *aspectLabel;
@property (nonatomic, strong) UISlider *aspectSlider;
@end

@implementation BPMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.95];
        self.layer.cornerRadius = 16.0;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1.0].CGColor;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, frame.size.width, 30)];
        title.text = @"BYPASS MENU";
        title.textColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1.0];
        title.font = [UIFont fontWithName:@"Helvetica-Bold" size:18];
        title.textAlignment = NSTextAlignmentCenter;
        [self addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(frame.size.width - 40, 8, 32, 32);
        [close setTitle:@"X" forState:UIControlStateNormal];
        [close setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0] forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [close addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(15, 55, frame.size.width - 30, 25)];
        label.text = [NSString stringWithFormat:@"Aspect: %.2f", targetAspect];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont fontWithName:@"Helvetica" size:15];
        [self addSubview:label];
        self.aspectLabel = label;

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(15, 90, frame.size.width - 30, 30)];
        slider.minimumValue = 1.0;
        slider.maximumValue = 2.0;
        slider.value = targetAspect;
        slider.minimumTrackTintColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1.0];
        [slider addTarget:self action:@selector(aspectChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:slider];
        self.aspectSlider = slider;

        NSArray *presets = @[@"1.33", @"1.6", @"1.78", @"2.0"];
        for (int i = 0; i < 4; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            CGFloat btnW = (frame.size.width - 50) / 4.0;
            btn.frame = CGRectMake(15 + i * (btnW + 5), 130, btnW, 32);
            [btn setTitle:presets[i] forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.3 blue:0.5 alpha:1.0];
            btn.layer.cornerRadius = 8.0;
            btn.tag = i;
            [btn addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:btn];
        }

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)aspectChanged:(UISlider *)slider {
    stretchEnabled = YES;
    targetAspect = slider.value;
    self.aspectLabel.text = [NSString stringWithFormat:@"Aspect: %.2f", targetAspect];
    forceLayout();
    forceRotation();
}

- (void)presetTapped:(UIButton *)sender {
    stretchEnabled = YES;
    NSArray *values = @[@1.333, @1.6, @1.778, @2.0];
    targetAspect = [values[sender.tag] floatValue];
    self.aspectSlider.value = targetAspect;
    self.aspectLabel.text = [NSString stringWithFormat:@"Aspect: %.2f", targetAspect];
    forceLayout();
    forceRotation();
}

- (void)closeMenu { [self removeFromSuperview]; }

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}
@end

// --- Менеджер ---
@interface BPMenuManager : NSObject
@property (nonatomic, strong) BPMenuView *menuView;
+ (instancetype)shared;
- (void)delayedSetup;
@end

@implementation BPMenuManager
+ (instancetype)shared {
    static BPMenuManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[BPMenuManager alloc] init]; });
    return instance;
}

- (UIWindow *)getKeyWindow {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) { if (w.isKeyWindow) return w; }
    }
    return nil;
}

- (void)setupGesture {
    UIWindow *window = [self getKeyWindow];
    if (!window) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.numberOfTapsRequired = 2;
    tap.numberOfTouchesRequired = 3;
    tap.cancelsTouchesInView = NO;
    [window addGestureRecognizer:tap];
}

- (void)handleTap:(UITapGestureRecognizer *)tap { [self toggleMenu]; }

- (void)toggleMenu {
    if (self.menuView && self.menuView.superview) {
        [self.menuView removeFromSuperview];
        self.menuView = nil;
        return;
    }
    UIWindow *window = [self getKeyWindow];
    if (!window) return;
    CGFloat menuW = 280;
    BPMenuView *menu = [[BPMenuView alloc] initWithFrame:CGRectMake((window.bounds.size.width - menuW)/2.0, 80, menuW, 180)];
    [window addSubview:menu];
    self.menuView = menu;
}

- (void)delayedSetup { [self setupGesture]; }
@end

// --- Инициализация ---
__attribute__((constructor))
static void init_hook(void) {
    Class cls = objc_getClass("UIScreen");
    if (cls) {
        Method o, r;
        o = class_getInstanceMethod(cls, @selector(bounds));
        r = class_getInstanceMethod(cls, @selector(stretch_bounds));
        if (o && r) method_exchangeImplementations(o, r);

        o = class_getInstanceMethod(cls, @selector(nativeBounds));
        r = class_getInstanceMethod(cls, @selector(stretch_nativeBounds));
        if (o && r) method_exchangeImplementations(o, r);

        // applicationFrame — может не быть на новых iOS
        if (class_getInstanceMethod(cls, @selector(applicationFrame))) {
            o = class_getInstanceMethod(cls, @selector(applicationFrame));
            r = class_getInstanceMethod(cls, @selector(stretch_applicationFrame));
            if (o && r) method_exchangeImplementations(o, r);
        }
    }

    Class winCls = objc_getClass("UIWindow");
    if (winCls) {
        Method o = class_getInstanceMethod(winCls, @selector(bounds));
        Method r = class_getInstanceMethod(winCls, @selector(stretch_bounds));
        if (o && r) method_exchangeImplementations(o, r);
    }

    [[BPMenuManager shared] performSelector:@selector(delayedSetup) withObject:nil afterDelay:5.0];
}