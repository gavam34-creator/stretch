#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Глобальная переменная аспекта (по умолчанию 16:10 = 1.6)
static CGFloat targetAspect = 16.0 / 10.0;

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

// --- Меню ---
@interface BPMenuView : UIView
@property (nonatomic, strong) UISlider *aspectSlider;
@property (nonatomic, strong) UILabel *aspectLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, assign) CGPoint lastPanPoint;
@end

@implementation BPMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.95];
        self.layer.cornerRadius = 16.0;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1.0].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.7;
        self.layer.shadowRadius = 12.0;
        self.layer.shadowOffset = CGSizeMake(0, 4);

        // Заголовок
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, frame.size.width, 30)];
        title.text = @"BYPASS MENU";
        title.textColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1.0];
        title.font = [UIFont fontWithName:@"Helvetica-Bold" size:18];
        title.textAlignment = NSTextAlignmentCenter;
        [self addSubview:title];
        self.titleLabel = title;

        // Кнопка закрытия
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(frame.size.width - 40, 8, 32, 32);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0] forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [close addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];
        self.closeButton = close;

        // Лейбл аспекта
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(15, 55, frame.size.width - 30, 25)];
        label.text = [NSString stringWithFormat:@"Aspect: %.2f", targetAspect];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont fontWithName:@"Helvetica" size:15];
        [self addSubview:label];
        self.aspectLabel = label;

        // Слайдер
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(15, 90, frame.size.width - 30, 30)];
        slider.minimumValue = 1.0;
        slider.maximumValue = 2.0;
        slider.value = targetAspect;
        slider.minimumTrackTintColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1.0];
        slider.maximumTrackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
        [slider addTarget:self action:@selector(aspectChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:slider];
        self.aspectSlider = slider;

        // Кнопки пресетов
        NSArray *presets = @[@"1.33", @"1.6", @"1.78", @"2.0"];
        for (int i = 0; i < presets.count; i++) {
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

        // Pan для перетаскивания
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)aspectChanged:(UISlider *)slider {
    targetAspect = slider.value;
    self.aspectLabel.text = [NSString stringWithFormat:@"Aspect: %.2f", targetAspect];
}

- (void)presetTapped:(UIButton *)sender {
    NSArray *values = @[@1.333, @1.6, @1.778, @2.0];
    targetAspect = [values[sender.tag] floatValue];
    self.aspectSlider.value = targetAspect;
    self.aspectLabel.text = [NSString stringWithFormat:@"Aspect: %.2f", targetAspect];
}

- (void)closeMenu {
    [self removeFromSuperview];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

@end

// --- Менеджер меню ---
@interface BPMenuManager : NSObject
@property (nonatomic, strong) BPMenuView *menuView;
+ (instancetype)shared;
- (void)toggleMenu;
- (void)setupGesture;
@end

@implementation BPMenuManager

+ (instancetype)shared {
    static BPMenuManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BPMenuManager alloc] init];
    });
    return instance;
}

- (void)setupGesture {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        UIApplication *app = [UIApplication sharedApplication];
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
        if (!window) return;

        // Двойной тап тремя пальцами
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTripleTap:)];
        tap.numberOfTapsRequired = 2;
        tap.numberOfTouchesRequired = 3;
        tap.cancelsTouchesInView = NO;
        [window addGestureRecognizer:tap];
    });
}

- (void)handleTripleTap:(UITapGestureRecognizer *)tap {
    [self toggleMenu];
}

- (void)toggleMenu {
    if (self.menuView && self.menuView.superview) {
        [self.menuView removeFromSuperview];
        self.menuView = nil;
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        UIApplication *app = [UIApplication sharedApplication];
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
        if (!window) return;

        CGRect screen = window.bounds;
        CGFloat menuW = 280;
        CGFloat menuH = 180;
        CGFloat x = (screen.size.width - menuW) / 2.0;
        CGFloat y = 80;

        BPMenuView *menu = [[BPMenuView alloc] initWithFrame:CGRectMake(x, y, menuW, menuH)];
        [window addSubview:menu];
        self.menuView = menu;
    });
}

@end

// --- Инициализация ---
__attribute__((constructor))
static void init_hook(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        // Хук UIScreen.bounds
        Class cls = objc_getClass("UIScreen");
        if (cls) {
            Method orig = class_getInstanceMethod(cls, @selector(bounds));
            Method repl = class_getInstanceMethod(cls, @selector(stretch_bounds));
            if (orig && repl) method_exchangeImplementations(orig, repl);
        }

        // Настройка жеста (с задержкой, чтобы окно точно было)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[BPMenuManager shared] setupGesture];
        });
    }];
}