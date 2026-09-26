#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <mach-o/loader.h>
#include <math.h>
#include <string.h>

// --------------------------------------------------------------- dyld / Mach-O
extern const struct mach_header *_dyld_get_image_header(int32_t index);
extern int32_t _dyld_image_count(void);
extern const char *_dyld_get_image_name(int32_t index);

// =============================================================================
//  WORKUP STRETCH — PUBG Mobile VNG 4.6, arm64e, sideload IPA
//
//  ЧТО УСТАНОВЛЕНО АНАЛИЗОМ (ShadowTrackerExtra, cryptid=0, base 0x100000000):
//   1) игра ЧИТАЕТ UIScreen: спуфинг на широкий аспект -> кадр выходит за края.
//   2) в бинаре есть "UEnums.EAspectRatioAxisConstraint =
//      {AspectRatio_MaintainYFOV=0, AspectRatio_MaintainXFOV=1,
//       AspectRatio_MajorAxisFOV=2}"  (vaddr 0x107556605)
//      -> чёрные полосы = MaintainYFOV (движок вписывает 4:3 по вертикали).
//   3) AspectRatioAxisConstraint — настоящий UPROPERTY класса UEngine.
//      Таблица полей UE5: запись 64 Б, char* NameUTF8 по +0x08, offset по +0x30.
//        строка имени  vaddr 0x1077B4050, запись vaddr 0x109CAE300
//        -> UEngine::AspectRatioAxisConstraint = +0x7C, 1 байт (TEnumAsByte)
//      Соседние имена (bSentSplitJoin, PendingLevelPlayerControllerClass,
//      ViewportClient) подтверждают класс UEngine; дескриптор класса "Engine"
//      по vaddr 0x109CAE3A0, его регистрирует FUN_1068047E0.
//   4) GEngine (глобал UEngine*) = vaddr 0x10A8AA8A0 -> file-offset 0xA8A8A0.
//      Найден по assert-строкам Tencent "FEngineLoop-Init-GEngine->Init/Start"
//      -> FUN_102C87418 (FEngineLoop::PreInit):
//         adrp x24,0x10A8AA000 ; add x24,#0x8A0 ; str x0,[x24]
//         затем GEngine->Init (vtable 0x2D0) и GEngine->Start (vtable 0x2D8).
//   5) UEngine::ViewportClient = +0x0x58 (используется только для sanity-check).
//
//  ЧТО РЕАЛЬНО РАБОТАЕТ БЕЗ ОФФСЕТОВ (проверено на устройстве):
//   aspect >= нативного  -> ПОЛОС НЕТ (кадр шире экрана, края обрезаются)
//   aspect 4:3            -> полосы ЕСТЬ (это "ПК-вид", иначе никак)
//
//  НОВОЕ: запись GEngine+0x7C = 1 (MaintainXFOV) должна снять полосы по-настоящему,
//  потому что это штатный движковый флаг, а не подмена UIScreen.
//
//  БЕЗОПАСНОСТЬ (после крашей):
//   * НЕТ хуков setFrame/setBounds/setTransform на CALayer — они били по всем
//     слоям процесса и роняли UE4 Metal RHI.
//   * НЕТ мутаций CAMetalLayer.affineTransform — падение внутри Metal.
//   * НЕТ глобальных хуков UIKit. Только UIScreen.bounds/nativeBounds.
//   * НЕТ вечных таймеров/DisplayLink. Один отложенный старт на 7 сек.
//   * @try/@catch вокруг каждого хука. Меню — в отдельном UIWindow.
// =============================================================================

// 2.0 -> шире нативных 19.5:9 => БЕЗ ЧЁРНЫХ ПОЛОС (края слегка обрезаются).
// 4.3/3.0 -> 4:3 "ПК-вид", но С ПОЛОСАМИ (так устроен движок).
static double g_aspect = 2.0;
static volatile int g_spoofOn = 0;     // включается через 7 сек после старта

// =============================================================================
//  ДВИЖКОВЫЙ ФЛАГ ASPECT  (настоящий путь, без подмены UIScreen)
//
//  GEngine        = <image base> + 0xA8A8A0      (UEngine*)
//  aspect flag    = GEngine + 0x7C                 (1 байт)
//  0 = MaintainYFOV (полосы)  1 = MaintainXFOV (без полос)  2 = MajorAxisFOV
//
//  Движок кэширует флаг в UEngine::CurrentAspectRatioAxisConstraint и применяет
//  при ресайзе, поэтому пишем не один раз, а повторяем ограниченное число раз.
// =============================================================================
#define GENGINE_OFF  0xA8A8A0UL
#define UENG_ASPECT  0x7C
#define UENG_VPCL    0x58

static int   g_engineWant = 1;    // 1 = MaintainXFOV по умолчанию (без полос)
                                   // -1 = не трогаем движок
static int   g_engineLast = -2;   // последнее прочитанное из движка
static uintptr_t g_base = 0;      // рантайм-база образа ShadowTrackerExtra

static uintptr_t findGameBase(void) {
    for (int32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (!n) continue;
        if (strstr(n, "ShadowTrackerExtra")) {
            const struct mach_header *h = _dyld_get_image_header(i);
            return (uintptr_t)h;
        }
    }
    // fallback: образ 0 — это главный исполняемый файл
    const struct mach_header *h0 = _dyld_get_image_header(0);
    return (uintptr_t)h0;
}

static void *genginePtr(void) {
    if (!g_base) g_base = findGameBase();
    if (!g_base) return NULL;
    return *(void **)(g_base + GENGINE_OFF);
}

// Текущее значение флага в движке; -1 если недоступно/невалидно.
static int readEngineAspect(void) {
    @try {
        void *e = genginePtr();
        if (!e) return -1;
        uintptr_t p = (uintptr_t)e;
        if ((p & 0xF) || p < 0x1000) return -1;              // выравнивание/мусор
        return *(volatile uint8_t *)(p + UENG_ASPECT) & 0xFF;
    } @catch (id ex) {
        return -1;
    }
}

// Записать флаг. ok=0 если движок ещё не поднят.
static int writeEngineAspect(int v) {
    if (v < 0 || v > 2) return 0;
    @try {
        void *e = genginePtr();
        if (!e) return 0;
        uintptr_t p = (uintptr_t)e;
        if ((p & 0xF) || p < 0x1000) return 0;
        // sanity: UEngine::ViewportClient должен быть валидным указателем
        void *vpc = *(void **)(p + UENG_VPCL);
        if (!vpc) return 0;
        *(volatile uint8_t *)(p + UENG_ASPECT) = (uint8_t)v;
        g_engineLast = *(volatile uint8_t *)(p + UENG_ASPECT) & 0xFF;
        return 1;
    } @catch (id ex) {
        return 0;
    }
}

// Ограниченная серия попыток: движок перезаписывает флаг при загрузке уровня.
static void engineAspectRetry(int idx) {
    if (idx > 40) {
        if (g_engineWant >= 0) {
            int now = readEngineAspect();
            fprintf(stderr, "[Stretch] engine aspect final: want=%d read=%d %s\n",
                    g_engineWant, now,
                    (now == g_engineWant) ? "OK" : "OVERRIDDEN by game");
        }
        return;
    }
    if (g_engineWant >= 0) {
        int ok = writeEngineAspect(g_engineWant);
        if (idx == 0 || idx == 10 || ok == 0) {
            fprintf(stderr, "[Stretch] engine aspect try#%d want=%d ok=%d read=%d\n",
                    idx, g_engineWant, ok, readEngineAspect());
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ engineAspectRetry(idx + 1); });
}

static void engineAspectSet(int v) {
    g_engineWant = v;
    if (v < 0) {
        fprintf(stderr, "[Stretch] engine aspect: OFF (native)\n");
        return;
    }
    if (!findGameBase()) { fprintf(stderr, "[Stretch] game base not found\n"); return; }
    int ok = writeEngineAspect(v);
    fprintf(stderr, "[Stretch] engine aspect set want=%d ok=%d read=%d\n",
            v, ok, readEngineAspect());
    if (ok) engineAspectRetry(1);
}

static CGRect (*orig_bounds)(id, SEL)       = NULL;
static CGRect (*orig_nativeBounds)(id, SEL) = NULL;

static UIWindow *g_win = nil;
static UILabel   *g_valLabel = nil;
static UILabel   *g_engLabel = nil;
static UISlider  *g_slider = nil;
static UIButton  *g_btnApply = nil;

// --------------------------------------------------------------- спуфинг 4:3
// width = height * g_aspect, высота сохраняется, прямоугольник по центру.
static CGRect spoofAspect(CGRect r) {
    if (!g_spoofOn) return r;
    if (!(g_aspect > 0.01) || !isfinite(g_aspect)) return r;
    CGFloat w = r.size.width, h = r.size.height;
    if (!(w > 1.0) || !(h > 1.0)) return r;            // NaN/мусор отсекаем
    if (w <= h) return r;                                // не ландшафт
    CGFloat nw = round(h * g_aspect);
    if (!isfinite(nw) || nw < 64 || nw > w * 3.0f) return r;
    CGFloat dx = (w - nw) * 0.5f;
    if (!isfinite(dx)) return r;
    return CGRectMake(r.origin.x + dx, r.origin.y, nw, h);
}

static CGRect hook_bounds(id s, SEL c) {
    CGRect real = orig_bounds ? orig_bounds(s, c) : CGRectZero;
    @try { return spoofAspect(real); } @catch (id e) { return real; }
}
static CGRect hook_nativeBounds(id s, SEL c) {
    CGRect real = orig_nativeBounds ? orig_nativeBounds(s, c) : CGRectZero;
    @try { return spoofAspect(real); } @catch (id e) { return real; }
}

// Перечитать bounds движком (после смены aspect из меню)
static void forceRereadBounds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UIDeviceOrientationDidChangeNotification object:nil];
        } @catch (id e) {}
    });
}

// =============================================================================
//  МЕНЮ
// =============================================================================
@interface StretchMenu : NSObject
+ (void)show; + (void)hide; + (void)pick:(id)s;
+ (void)sliderChanged:(id)s; + (void)toggle:(id)s;
+ (void)engPick:(id)s;
@end

@implementation StretchMenu

+ (UILabel *)lbl:(NSString *)t size:(CGFloat)s {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = t;
    l.font = [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightBold];
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 1;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.6f;
    return l;
}

+ (NSString *)fmt:(double)a {
    if (!(a > 0.01)) return @"Native  (no change)";
    if (a >= 2.15) return [NSString stringWithFormat:@"%.2f  NO BARS", a];
    return [NSString stringWithFormat:@"%.2f  has bars", a];
}

+ (void)sliderChanged:(id)sender {
    UISlider *s = (UISlider *)sender;
    double v = s.value;
    if (!isfinite(v)) return;
    g_aspect = v;
    if (g_valLabel) g_valLabel.text = [self fmt:g_aspect];
    if (g_btnApply) {
        g_btnApply.enabled = YES;
        [g_btnApply setTitle:@"APPLY" forState:UIControlStateNormal];
    }
    fprintf(stderr, "[Stretch] aspect set to %.3f (apply)\n", g_aspect);
}

// кнопка APPLY: только здесь меняем aspect у движка
+ (void)pick:(id)sender {
    @try {
        if (g_btnApply) {
            g_btnApply.enabled = NO;
            [g_btnApply setTitle:@"APPLIED" forState:UIControlStateNormal];
        }
        forceRereadBounds();
    } @catch (id e) {}
    [self hide];
}

// --- переключатель ДВИЖКОВОГО флага (настоящий MaintainXFOV, без полос) ---
+ (void)engPick:(id)sender {
    int v = (int)[(NSNumber *)[sender accessibilityValue] integerValue];
    engineAspectSet(v);
    if (g_engLabel) g_engLabel.text = [self engStatus];
    [self hide];
}

+ (NSString *)engStatus {
    int r = readEngineAspect();
    if (r < 0) return @"ENGINE: not ready";
    if (g_engineWant < 0) return [NSString stringWithFormat:@"ENGINE: native (read %d)", r];
    if (r == g_engineWant) return [NSString stringWithFormat:@"ENGINE: %d OK", r];
    return [NSString stringWithFormat:@"ENGINE: want %d, read %d", g_engineWant, r];
}

+ (UIButton *)btn:(NSString *)t aspect:(double)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.bounds = CGRectMake(0, 0, 232, 36);
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6f;
    b.accessibilityIdentifier = [NSString stringWithFormat:@"asp%.4f", a];
    [b addTarget:self action:@selector(pick:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_win) return;                       // уже открыто
        @try {
            CGRect scr = UIScreen.mainScreen.bounds;
            g_win = [[UIWindow alloc] initWithFrame:scr];
            g_win.windowLevel = UIWindowLevelAlert + 100;
            g_win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

            CGFloat BW = 250, BH = 476;
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, BW, BH)];
            box.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.94];
            box.layer.cornerRadius = 14;
            box.layer.borderWidth = 1;
            box.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;

            UILabel *title = [self lbl:@"STRETCH" size:16];
            title.frame = CGRectMake(0, 8, BW, 22);
            g_valLabel = [self lbl:[self fmt:g_aspect] size:14];
            g_valLabel.frame = CGRectMake(0, 30, BW, 20);

            g_slider = [[UISlider alloc] initWithFrame:CGRectMake(20, 54, BW - 40, 28)];
            g_slider.minimumValue = 4.0 / 3.0;   // 4:3 — самый узкий
            g_slider.maximumValue = 2.8;
            g_slider.value = (float)(g_aspect >= 1.3333 && g_aspect <= 2.8 ? g_aspect : 2.0);
            g_slider.minimumTrackTintColor = [UIColor systemGreenColor];
            g_slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.2];
            [g_slider addTarget:self action:@selector(sliderChanged:)
               forControlEvents:UIControlEventValueChanged];

            UILabel *hint = [self lbl:@"<- 4:3 (bars)          NO BARS ->" size:10];
            hint.textColor = [UIColor colorWithWhite:1 alpha:0.5];
            hint.frame = CGRectMake(0, 82, BW, 16);

            g_btnApply = [self btn:@"APPLY" aspect:0];
            g_btnApply.center = CGPointMake(BW / 2.0, 118);
            g_btnApply.enabled = NO;
            [g_btnApply setTitle:@"APPLIED" forState:UIControlStateNormal];
            g_btnApply.backgroundColor = [UIColor colorWithRed:0.1 green:0.6
                                                         blue:0.3 alpha:0.5];

            NSArray *opts = @[@"4:3   1.33  (bars)",  @"16:9  1.78  (bars)",
                              @"19.5:9 native",       @"20:9  2.00  NO BARS",
                              @"21:9  2.33  NO BARS", @"24:9  2.67  NO BARS"];
            double asp[] = {4.0/3.0, 16.0/9.0, 0.0, 20.0/9.0, 21.0/9.0, 24.0/9.0};
            CGFloat y = 142;
            for (NSUInteger i = 0; i < opts.count; i++) {
                UIButton *b = [self btn:opts[i] aspect:asp[i]];
                b.center = CGPointMake(BW / 2.0, y + 17);
                [box addSubview:b];
                y += 40;
            }

            UILabel *h2 = [self lbl:@"3-finger double-tap = close" size:10];
            h2.textColor = [UIColor colorWithWhite:1 alpha:0.5];
            h2.frame = CGRectMake(0, BH - 24, BW, 18);

            // ---- ряд переключателя ДВИЖКОВОГО флага (настоящий, без полос) ----
            UILabel *et = [self lbl:@"ENGINE FLAG  (UEngine+0x7C)" size:11];
            et.textColor = [UIColor colorWithRed:0.4 green:0.9 blue:0.5 alpha:1.0];
            et.frame = CGRectMake(0, 388, BW, 16);

            g_engLabel = [self lbl:[self engStatus] size:10];
            g_engLabel.textColor = [UIColor colorWithWhite:1 alpha:0.65];
            g_engLabel.frame = CGRectMake(0, 404, BW, 14);

            NSArray *en =   @[@"OFF",    @"YFOV 0", @"XFOV 1", @"MJR 2"];
            NSArray *ev =   @[@-1,       @0,        @1,        @2];
            CGFloat ew = (BW - 24) / 4.0, ex = 12, ey = 420;
            for (NSUInteger i = 0; i < en.count; i++) {
                UIButton *b = [self btn:en[i] aspect:0];
                b.frame = CGRectMake(ex + ew * i, ey, ew - 4, 28);
                b.bounds = CGRectMake(0, 0, ew - 4, 28);
                b.titleLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                              weight:UIFontWeightBold];
                b.accessibilityValue = ev[i];
                [b removeTarget:self action:@selector(pick:)
                  forControlEvents:UIControlEventTouchUpInside];
                [b addTarget:self action:@selector(engPick:)
       forControlEvents:UIControlEventTouchUpInside];
                if ([ev[i] integerValue] == g_engineWant) {
                    b.backgroundColor = [UIColor colorWithRed:0.1 green:0.6
                                                       blue:0.35 alpha:0.75];
                }
                [box addSubview:b];
            }

            [box addSubview:title]; [box addSubview:g_valLabel]; [box addSubview:g_slider];
            [box addSubview:hint];  [box addSubview:h2];
            [box addSubview:et];    [box addSubview:g_engLabel];

            UIView *host = [[UIView alloc] initWithFrame:scr];
            [host addSubview:box];
            box.center = CGPointMake(CGRectGetMidX(scr), CGRectGetMidY(scr));
            [host addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(hide)]];

            // Окно с rootViewController — единственный надёжный способ показать
            // overlay на iOS 13+; без него окно не отображается.
            g_win.rootViewController = [[UIViewController alloc] init];
            g_win.rootViewController.view = host;
            [g_win makeKeyAndVisible];
            fprintf(stderr, "[Stretch] menu shown, aspect=%.3f\n", g_aspect);
        } @catch (id e) {
            fprintf(stderr, "[Stretch] menu failed: %s\n", [[e description] UTF8String]);
            [self hide];
        }
    });
}

+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        @try {
            g_win.hidden = YES;
            g_win.rootViewController = nil;
        } @catch (id e) {}
            g_win = nil; g_slider = nil; g_valLabel = nil; g_btnApply = nil; g_engLabel = nil;
    });
}

+ (void)toggle:(id)s {
    if (g_win) [self hide]; else [self show];
}

@end

// ------------------------------------------------------------------ gesture
// 3 пальца + 2 тапа. cancelsTouchesInView=NO — не перехватываем игровые тапы.
static void installGesture(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *target = nil;
            for (UIWindow *w in UIApplication.sharedApplication.windows) {
                if (w.isKeyWindow && (id)w != (id)g_win) { target = w; break; }
            }
            if (!target) return;
            for (UIGestureRecognizer *gr in target.gestureRecognizers) {
                if ([gr isKindOfClass:[UITapGestureRecognizer class]] &&
                    ((UITapGestureRecognizer *)gr).numberOfTouchesRequired == 3) return;
            }
            UITapGestureRecognizer *g =
                [[UITapGestureRecognizer alloc] initWithTarget:[StretchMenu class]
                                                        action:@selector(toggle:)];
            g.numberOfTouchesRequired = 3;
            g.numberOfTapsRequired   = 2;
            g.cancelsTouchesInView   = NO;
            g.delaysTouchesBegan     = NO;
            g.delaysTouchesEnded     = NO;
            [target addGestureRecognizer:g];
            fprintf(stderr, "[Stretch] gesture installed\n");
        } @catch (id e) {
            fprintf(stderr, "[Stretch] gesture error: %s\n", [[e description] UTF8String]);
        }
    });
}

__attribute__((constructor))
static void init_stretch(void) {
    @autoreleasepool {
        fprintf(stderr, "[Stretch] init, default aspect=%.3f\n", g_aspect);
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
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
                fprintf(stderr, "[Stretch] hooks installed (bounds, nativeBounds)\n");
            } @catch (id e) {
                fprintf(stderr, "[Stretch] hook error: %s\n", [[e description] UTF8String]);
            }

            // Включаем спуфинг через 7 сек — чтобы не сломать инициализацию UE4
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                g_spoofOn = 1;
                fprintf(stderr, "[Stretch] spoof on (aspect=%.3f)\n", g_aspect);

                // Движковый флаг: по умолчанию MaintainXFOV (1) = без полос.
                g_base = findGameBase();
                fprintf(stderr, "[Stretch] game base=%p engine=%p\n",
                        (void *)g_base, genginePtr());
                g_engineWant = 1;
                int ok = writeEngineAspect(1);
                fprintf(stderr, "[Stretch] engine default XFOV ok=%d read=%d\n",
                        ok, readEngineAspect());
                if (ok) engineAspectRetry(1);
            });
        });
        // жест: сразу и позже (окна могут появиться не сразу)
        dispatch_async(dispatch_get_main_queue(), ^{ installGesture(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ installGesture(); });
    }
}
