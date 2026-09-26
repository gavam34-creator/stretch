#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <stdio.h>
#import <mach-o/loader.h>
#include <math.h>
#include <string.h>

extern const struct mach_header *_dyld_get_image_header(int32_t index);
extern int32_t _dyld_image_count(void);
extern const char *_dyld_get_image_name(int32_t index);

// =============================================================================
//  WORKUP STRETCH v6 — FINAL
//
//  A) UIScreen.bounds -> 4:3 (origin НЕ сдвигаем, nativeBounds НЕ трогаем)
//  B) UEngine+0x7C = 1 (MaintainXFOV) — через vm_read_overwrite/vm_write
//  C) contentsGravity=Resize на главном слое — KVC, БЕЗ глобального хука
//
//  ФИКСЫ v8:
//   1. Убран гейт по UEngine::ViewportClient из read/write. Он ломал всё:
//      на 7-й секунде вьюпорт ещё NULL -> и чтение, и запись молча
//      блокировались, отсюда был "read: -1" при живом движке.
//   2. Гейт заменён на vtable-проверку (первые 8 байт != NULL).
//   3. Окно ретрая 15с -> 60с, стартует ВСЕГДА, независимо от ok.
//   4. diagnoseEngine(): пошаговая печать, локализует обрыв до шага.
//   5. autoScanAspectFlag(): если +0x7C не 0/1/2 - скан байта рядом.
//   6. Кнопка DIAG в меню.
// =============================================================================

#define GENGINE_OFF  0xA8A8A0UL
#define UENG_ASPECT  0x7C
#define UENG_VPCL    0x58

static double        g_aspect    = 4.0 / 3.0;
static volatile int  g_spoofOn   = 0;

static int           g_engineWant = 1;
static int           g_engineLast = -2;
static uintptr_t     g_base       = 0;
static int           g_engineOverrides = 0;

static UIWindow *g_win      = nil;
static UILabel  *g_status   = nil;
static UILabel  *g_engLabel = nil;

// =============================================================================
//  SAFE MEMORY — vm_read_overwrite / vm_write
// =============================================================================
static BOOL safeRead8(uintptr_t addr, uint8_t *out) {
    vm_size_t sz = 1;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                          (vm_address_t)addr,
                                          sz,
                                          (vm_address_t)out,
                                          &sz);
    return (kr == KERN_SUCCESS && sz == 1);
}

static BOOL safeReadPtr(uintptr_t addr, void **out) {
    vm_size_t sz = sizeof(void *);
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                          (vm_address_t)addr,
                                          sz,
                                          (vm_address_t)out,
                                          &sz);
    return (kr == KERN_SUCCESS && sz == sizeof(void *));
}

static BOOL safeWrite8(uintptr_t addr, uint8_t val) {
    kern_return_t kr = vm_write(mach_task_self(),
                                 (vm_address_t)addr,
                                 (vm_address_t)&val,
                                 1);
    return (kr == KERN_SUCCESS);
}

// =============================================================================
//  A) ХУК bounds
// =============================================================================
static CGRect (*orig_bounds)(id, SEL) = NULL;

static CGRect spoofBounds(CGRect r) {
    if (!g_spoofOn) return r;
    if (!(g_aspect > 0.01) || !isfinite(g_aspect)) return r;
    CGFloat w = r.size.width, h = r.size.height;
    if (!(w > 1.0) || !(h > 1.0)) return r;
    if (w <= h) return r;
    CGFloat nw = round(h * g_aspect);
    if (!isfinite(nw) || nw < 64 || nw > w * 3.0f) return r;
    return CGRectMake(r.origin.x, r.origin.y, nw, h);
}

static CGRect hook_bounds(id s, SEL c) {
    if (!orig_bounds) return CGRectZero;        // ЗАЩИТА
    CGRect real = orig_bounds(s, c);
    return spoofBounds(real);
}

static void forceRereadBounds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UIDeviceOrientationDidChangeNotification object:nil];
        } @catch (id e) {}
    });
}

// =============================================================================
//  B) ДВИЖКОВЫЙ ФЛАГ — безопасно
// =============================================================================
static uintptr_t findGameBase(void) {
    for (int32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (!n) continue;
        if (strstr(n, "ShadowTrackerExtra")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return (uintptr_t)_dyld_get_image_header(0);
}

static void *genginePtrSafe(void) {
    if (!g_base) g_base = findGameBase();
    if (!g_base) return NULL;
    void *e = NULL;
    if (!safeReadPtr(g_base + GENGINE_OFF, &e)) return NULL;
    return e;
}

// --- признак "это UObject" -------------------------------------------------
// Проверять одно выравнивание бессмысленно: указатель бывает выровнен и при
// этом мусором. Настоящий признак - первые 8 байт это не-NULL vtable.
// ВАЖНО: vtable тоже читаем через vm_read, прямого разыменования тут нет.
static int plausibleEngine(void *e) {
    if (!e) return 0;
    uintptr_t a = (uintptr_t)e;
    if (a < 0x1000) return 0;
    if (a & 0x7) return 0;
    void *vt = NULL;
    if (!safeReadPtr(a, &vt)) return 0;
    if (!vt) return 0;
    if ((uintptr_t)vt < 0x1000) return 0;
    return 1;
}

// Если по +0x7C приходит не 0/1/2 - ищем байт-кандидат рядом.
// Эвристика: значение 0..2 И в пределах +-16 байт есть непустой 8-байтный
// указатель (соседнее свойство-указатель).
static long autoScanAspectFlag(void) {
    void *e = genginePtrSafe();
    if (!e) { fprintf(stderr, "[Stretch] scan: no engine\n"); return -1; }
    uintptr_t p = (uintptr_t)e;
    long found = -1;
    int n = 0;
    for (uintptr_t off = 0x50; off <= 0xB0; off++) {
        uint8_t v = 0;
        if (!safeRead8(p + off, &v)) continue;
        if (v > 2) continue;
        int near = 0;
        for (int d = 8; d <= 16; d += 8) {
            void *nb = NULL;
            if (safeReadPtr(p + off + d, &nb) && nb && (uintptr_t)nb > 0x1000) near = 1;
            if (safeReadPtr(p + off - d, &nb) && nb && (uintptr_t)nb > 0x1000) near = 1;
        }
        if (!near) continue;
        fprintf(stderr, "[Stretch] scan: +0x%02lX = %u (рядом указатель)\n",
                (unsigned long)off, (unsigned)v);
        if (found < 0) found = (long)off;
        n++;
    }
    fprintf(stderr, "[Stretch] scan done: %d кандидат(ов)\n", n);
    return found;
}

// Пошаговая диагностика: показывает РОВНО на каком шаге обрыв.
static void diagnoseEngine(void) {
    fprintf(stderr, "[Stretch] ===== DIAG =====\n");
    if (!g_base) g_base = findGameBase();
    fprintf(stderr, "[Stretch] DIAG images=%d base=%p slot=%p\n",
            (int)_dyld_image_count(), (void *)g_base, (void *)(g_base + GENGINE_OFF));
    if (!g_base) { fprintf(stderr, "[Stretch] DIAG FAIL: base не найден\n"); return; }

    void *e = NULL;
    vm_size_t sz = sizeof(void *);
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)(g_base + GENGINE_OFF),
                                         sizeof(void *), (vm_address_t)&e, &sz);
    fprintf(stderr, "[Stretch] DIAG slot kr=%d engine=%p\n", (int)kr, e);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[Stretch] DIAG FAIL: kr=%d (1=PROTECTION, 14=INVALID)\n", (int)kr);
        return;
    }
    if (!e) {
        fprintf(stderr, "[Stretch] DIAG FAIL: GEngine==NULL -> движок не поднят\n");
        return;
    }
    if (!plausibleEngine(e)) {
        fprintf(stderr, "[Stretch] DIAG FAIL: %p не похож на UObject\n", e);
        return;
    }

    void *vt = NULL, *vpc = NULL;
    uint8_t flag = 0xFF;
    safeReadPtr((uintptr_t)e, &vt);
    safeReadPtr((uintptr_t)e + UENG_VPCL, &vpc);
    int fok = safeRead8((uintptr_t)e + UENG_ASPECT, &flag);
    fprintf(stderr, "[Stretch] DIAG vtable=%p vpc@+%d=%p flag@+%d=%s%u\n",
            vt, UENG_VPCL, vpc, UENG_ASPECT, fok ? "" : "НЕ ЧИТАЕТСЯ, ",
            (unsigned)(fok ? flag : 0));

    fprintf(stderr, "[Stretch] DIAG dump:");
    for (int off = 0x50; off <= 0xB0; off += 8) {
        void *q = NULL;
        if (safeReadPtr((uintptr_t)e + off, &q)) fprintf(stderr, " %02X=%p", off, q);
        else                                            fprintf(stderr, " %02X=??", off);
    }
    fprintf(stderr, "\n");
    if (fok && flag <= 2) {
        fprintf(stderr, "[Stretch] DIAG OK: +%d похож на enum\n", UENG_ASPECT);
    } else {
        fprintf(stderr, "[Stretch] DIAG WARN: +%d не 0/1/2, скан\n", UENG_ASPECT);
        autoScanAspectFlag();
    }
    fprintf(stderr, "[Stretch] ===== /DIAG =====\n");
}

static int readEngineAspect(void) {
    void *e = genginePtrSafe();
    if (!plausibleEngine(e)) return -1;
    uint8_t v = 0;
    if (!safeRead8((uintptr_t)e + UENG_ASPECT, &v)) return -1;
    return (int)v;
}

static int writeEngineAspect(int v) {
    if (v < 0 || v > 2) return 0;
    void *e = genginePtrSafe();
    // Гейт ТОЛЬКО на vtable. Раньше здесь стояла проверка ViewportClient!=NULL,
    // и это ломало всё: вьюпорт на 7-й секунде ещё NULL, и обе операции
    // молча блокировались.
    if (!plausibleEngine(e)) return 0;
    if (!safeWrite8((uintptr_t)e + UENG_ASPECT, (uint8_t)v)) return 0;
    uint8_t verify = 0;
    if (safeRead8((uintptr_t)e + UENG_ASPECT, &verify)) g_engineLast = verify;
    return 1;
}

static void engineAspectRetry(int idx) {
    if (idx > 40) {                       // 40 * 1.5c = 60 секунд
        fprintf(stderr, "[Stretch] engine final: want=%d read=%d overrides=%d\n",
                g_engineWant, readEngineAspect(), g_engineOverrides);
        return;
    }
    if (g_engineWant < 0) return;

    int before = readEngineAspect();
    int ok = writeEngineAspect(g_engineWant);
    int after = readEngineAspect();
    if (ok && after != g_engineWant) g_engineOverrides++;

    if (idx <= 2 || (idx % 10) == 0 || ok == 0) {
        fprintf(stderr, "[Stretch] engine try#%d want=%d ok=%d before=%d after=%d\n",
                idx, g_engineWant, ok, before, after);
    }
    if (idx == 4 || idx == 20 || idx == 40) diagnoseEngine();

    if (g_engineOverrides >= 3) {
        fprintf(stderr, "[Stretch] engine retry STOP: игра перебивает (overrides=%d)\n",
                g_engineOverrides);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ engineAspectRetry(idx + 1); });
}

static void engineAspectSet(int v) {
    g_engineWant = v;
    g_engineOverrides = 0;
    if (v < 0) {
        if (g_engLabel) g_engLabel.text = @"ENGINE: native";
        return;
    }
    if (!findGameBase()) return;
    int ok = writeEngineAspect(v);
    fprintf(stderr, "[Stretch] engine set want=%d ok=%d read=%d\n",
            v, ok, readEngineAspect());
    // Ретай запускаем ВСЕГДА: если на 7-й секунде GEngine ещё NULL или объект
    // не прошёл гейт, движок поднимается на 15-20-й секунде.
    engineAspectRetry(1);
    if (!ok) diagnoseEngine();
    if (g_engLabel) {
        g_engLabel.text = [NSString stringWithFormat:@"ENGINE: %d (read %d)",
                                                       v, readEngineAspect()];
    }
}

// =============================================================================
//  C) FORCE GRAVITY — KVC, БЕЗ ГЛОБАЛЬНОГО ХУКА
// =============================================================================
static void forceMainLayerGravityOnce(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = nil;
            for (UIWindow *win in UIApplication.sharedApplication.windows) {
                if (win.isKeyWindow && (id)win != (id)g_win) { w = win; break; }
            }
            if (!w || !w.layer) return;

            Class metalCls = NSClassFromString(@"CAMetalLayer");
            if (!metalCls) return;

            NSArray *subs = w.layer.sublayers;
            if (!subs) return;

            int hits = 0;
            for (CALayer *l in subs) {
                if ([l isKindOfClass:metalCls]) {
                    [l setValue:kCAGravityResize forKey:@"contentsGravity"];
                    hits++;
                }
                for (CALayer *l2 in l.sublayers) {
                    if ([l2 isKindOfClass:metalCls]) {
                        [l2 setValue:kCAGravityResize forKey:@"contentsGravity"];
                        hits++;
                    }
                }
            }
            fprintf(stderr, "[Stretch] gravity set on %d metal layer(s)\n", hits);
        } @catch (id e) {
            fprintf(stderr, "[Stretch] force gravity fail: %s\n",
                    [[e description] UTF8String]);
        }
    });
}

// =============================================================================
//  МЕНЮ
// =============================================================================
@interface StretchMenu : NSObject
+ (void)show; + (void)hide; + (void)toggle:(id)s;
+ (void)modeA:(id)s;
+ (void)modeAB:(id)s;
+ (void)modeABC:(id)s;
+ (void)engPick:(id)s;
+ (void)aspPick:(id)s;
+ (void)diag:(id)s;
@end

@implementation StretchMenu

+ (UILabel *)lbl:(NSString *)t size:(CGFloat)s {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = t;
    l.font = [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightBold];
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.6f;
    return l;
}

+ (UIButton *)btn:(NSString *)t h:(CGFloat)h {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.bounds = CGRectMake(0, 0, 230, h);
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    b.titleLabel.numberOfLines = 2;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    return b;
}

static int safeIntFromSender(id sender) {
    if (![sender isKindOfClass:[UIButton class]]) return -2;
    id raw = [(UIButton *)sender accessibilityValue];
    if (![raw respondsToSelector:@selector(integerValue)]) return -2;
    return (int)[raw integerValue];
}

static double safeDoubleFromSender(id sender) {
    if (![sender isKindOfClass:[UIButton class]]) return 0.0;
    id raw = [(UIButton *)sender accessibilityValue];
    if (![raw respondsToSelector:@selector(doubleValue)]) return 0.0;
    return [raw doubleValue];
}

+ (void)modeA:(id)s {
    g_spoofOn = 1;
    engineAspectSet(-1);
    forceRereadBounds();
    if (g_status) g_status.text = @"MODE: A (bounds only)";
    fprintf(stderr, "[Stretch] MODE A\n");
    [self hide];
}

+ (void)modeAB:(id)s {
    g_spoofOn = 1;
    engineAspectSet(1);
    forceRereadBounds();
    if (g_status) g_status.text = @"MODE: A+B (bounds + XFOV)";
    fprintf(stderr, "[Stretch] MODE A+B\n");
    [self hide];
}

+ (void)modeABC:(id)s {
    g_spoofOn = 1;
    engineAspectSet(1);
    forceMainLayerGravityOnce();
    forceRereadBounds();
    if (g_status) g_status.text = @"MODE: A+B+C (full)";
    fprintf(stderr, "[Stretch] MODE A+B+C\n");
    [self hide];
}

+ (void)engPick:(id)sender {
    int v = safeIntFromSender(sender);
    if (v < -1 || v > 2) { [self hide]; return; }
    engineAspectSet(v);
    [self hide];
}

+ (void)aspPick:(id)sender {
    double a = safeDoubleFromSender(sender);
    if (!(a > 1.0) || !(a < 4.0)) return;
    g_aspect = a;
    if (g_status) {
        g_status.text = [NSString stringWithFormat:@"ASPECT: %.3f", a];
    }
    forceRereadBounds();
    fprintf(stderr, "[Stretch] aspect = %.3f\n", a);
}

+ (void)diag:(id)sender {
    diagnoseEngine();
    long scan = autoScanAspectFlag();
    int r = readEngineAspect();
    if (g_engLabel) {
        g_engLabel.text = [NSString stringWithFormat:@"read %d  base %p  %@",
                                                       r, (void *)g_base,
                                                       scan < 0 ? @"scan none" :
                                        [NSString stringWithFormat:@"+0x%lX", scan]];
    }
    if (g_status) g_status.text = @"DIAG: смотри консоль";
}

+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_win) return;
        @try {
            CGRect scr = UIScreen.mainScreen.bounds;
            g_win = [[UIWindow alloc] initWithFrame:scr];
            g_win.windowLevel = UIWindowLevelAlert + 100;
            g_win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];

            CGFloat BW = 260, BH = 560;
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, BW, BH)];
            box.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
            box.layer.cornerRadius = 14;
            box.layer.borderWidth = 1;
            box.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;

            UILabel *title = [self lbl:@"STRETCH v8" size:14];
            title.frame = CGRectMake(0, 10, BW, 20);

            g_status = [self lbl:@"MODE: idle" size:11];
            g_status.textColor = [UIColor colorWithRed:0.4 green:0.9 blue:0.5 alpha:1.0];
            g_status.frame = CGRectMake(0, 32, BW, 16);

            CGFloat y = 56;
            NSArray *modes = @[@"A: bounds only",
                               @"A+B: bounds + XFOV",
                               @"A+B+C: +gravity"];
            SEL sels[] = {@selector(modeA:), @selector(modeAB:), @selector(modeABC:)};
            for (NSUInteger i = 0; i < modes.count; i++) {
                UIButton *b = [self btn:modes[i] h:42];
                b.frame = CGRectMake(15, y, BW - 30, 42);
                [b addTarget:self action:sels[i]
                    forControlEvents:UIControlEventTouchUpInside];
                [box addSubview:b];
                y += 48;
            }

            UILabel *ah = [self lbl:@"ASPECT" size:11];
            ah.textColor = [UIColor colorWithWhite:1 alpha:0.65];
            ah.frame = CGRectMake(0, y, BW, 16); y += 20;
            [box addSubview:ah];

            NSArray *al = @[@"4:3", @"5:4", @"16:9", @"21:9"];
            double av[] = {4.0/3.0, 5.0/4.0, 16.0/9.0, 21.0/9.0};
            CGFloat aw = (BW - 30) / 4.0;
            for (NSUInteger i = 0; i < al.count; i++) {
                UIButton *b = [self btn:al[i] h:34];
                b.frame = CGRectMake(15 + aw * i, y, aw - 4, 34);
                b.titleLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                              weight:UIFontWeightBold];
                b.accessibilityValue = @(av[i]);
                [b addTarget:self action:@selector(aspPick:)
                    forControlEvents:UIControlEventTouchUpInside];
                [box addSubview:b];
            }
            y += 42;

            UILabel *eh = [self lbl:@"ENGINE FLAG (UEngine+0x7C)" size:11];
            eh.textColor = [UIColor colorWithWhite:1 alpha:0.65];
            eh.frame = CGRectMake(0, y, BW, 16); y += 20;
            [box addSubview:eh];

            g_engLabel = [self lbl:[NSString stringWithFormat:@"read: %d",
                                                                readEngineAspect()]
                              size:10];
            g_engLabel.textColor = [UIColor colorWithRed:0.4 green:0.9 blue:0.5 alpha:1.0];
            g_engLabel.frame = CGRectMake(0, y, BW, 14); y += 18;
            [box addSubview:g_engLabel];

            NSArray *en = @[@"OFF", @"YFOV 0", @"XFOV 1", @"MJR 2"];
            NSArray *ev = @[@-1, @0, @1, @2];
            CGFloat ew = (BW - 30) / 4.0;
            for (NSUInteger i = 0; i < en.count; i++) {
                UIButton *b = [self btn:en[i] h:30];
                b.frame = CGRectMake(15 + ew * i, y, ew - 4, 30);
                b.titleLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                              weight:UIFontWeightBold];
                b.accessibilityValue = ev[i];
                [b addTarget:self action:@selector(engPick:)
                    forControlEvents:UIControlEventTouchUpInside];
                [box addSubview:b];
            }
            y += 38;

            UIButton *db = [self btn:@"DIAG  (console)" h:30];
            db.frame = CGRectMake(15, y, BW - 30, 30);
            db.titleLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                          weight:UIFontWeightBold];
            [db addTarget:self action:@selector(diag:)
                  forControlEvents:UIControlEventTouchUpInside];
            [box addSubview:db];
            y += 36;

            UILabel *h2 = [self lbl:@"3-finger double-tap = close" size:10];
            h2.textColor = [UIColor colorWithWhite:1 alpha:0.5];
            h2.frame = CGRectMake(0, BH - 22, BW, 16);

            [box addSubview:title];
            [box addSubview:h2];

            UIView *host = [[UIView alloc] initWithFrame:scr];
            [host addSubview:box];
            box.center = CGPointMake(CGRectGetMidX(scr), CGRectGetMidY(scr));
            [host addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(hide)]];

            g_win.rootViewController = [[UIViewController alloc] init];
            g_win.rootViewController.view = host;
            [g_win makeKeyAndVisible];
        } @catch (id e) {
            fprintf(stderr, "[Stretch] menu fail: %s\n", [[e description] UTF8String]);
            [self hide];
        }
    });
}

+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        @try { g_win.hidden = YES; g_win.rootViewController = nil; } @catch (id e) {}
        g_win = nil; g_status = nil; g_engLabel = nil;
    });
}

+ (void)toggle:(id)s { if (g_win) [self hide]; else [self show]; }

@end

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
        } @catch (id e) {}
    });
}

__attribute__((constructor))
static void init_stretch(void) {
    @autoreleasepool {
        fprintf(stderr, "[Stretch] v8 init\n");

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                Class sc = [UIScreen mainScreen].class;
                Method mb = class_getInstanceMethod(sc, @selector(bounds));
                if (mb) {
                    orig_bounds = (CGRect(*)(id, SEL))method_getImplementation(mb);
                    method_setImplementation(mb, (IMP)hook_bounds);
                    fprintf(stderr, "[Stretch] bounds hook OK\n");
                }
            } @catch (id e) {
                fprintf(stderr, "[Stretch] bounds hook fail\n");
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            g_base = findGameBase();
            fprintf(stderr, "[Stretch] base=%p engine=%p\n",
                    (void *)g_base, genginePtrSafe());

            g_spoofOn = 1;
            engineAspectSet(1);
            forceRereadBounds();

            fprintf(stderr, "[Stretch] default = A+B\n");
        });

        dispatch_async(dispatch_get_main_queue(), ^{ installGesture(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ installGesture(); });
    }
}