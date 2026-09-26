#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import "dobby.h"

// =============================================================================
//  WORKUP STRETCH — конфигурация. Впиши офсеты, пересобери, готово.
//
//  ВАЖНО: вписывай FILE-OFFSET (как в отчётах) или VADDR? Мы используем
//  VADDR (полный адрес 0x1_______). Если отчёт даёт file-offset — прибавь
//  0x100000000 (image base iOS arm64), или поставь USE_FILE_OFFSET 1.
// =============================================================================

// --- ОФСЕТЫ: впиши сюда (0 = выключено) ------------------------------------
#define OFFSET_RESIZE    0x00000000   // FSceneViewport::ResizeViewport (VADDR)
#define OFFSET_LAYOUT    0x00000000   // UGameViewportClient::LayoutPlayers (VADDR)
#define USE_FILE_OFFSET  0            // 1 если офсеты из отчёта — file-offset

// --- ЦЕЛЕВОЙ ASPECT ----------------------------------------------------------
// 4:3 = 1.333 (классика ПК, сжатая на широкий экран — «растяжка»)
// 16:9 = 1.778 | 1.0 = натив (выключить)
#define TARGET_ASPECT    (4.0 / 3.0)

// --- ЧТО ВКЛЮЧИТЬ ------------------------------------------------------------
#define ENABLE_GAME_HOOKS 1    // хук функций игры по офсетам (нужны офсеты!)
#define ENABLE_UISPOOF    0    // спуффинг UIScreen (letterbox-эффект, без оффсетов)

static double targetAspect = TARGET_ASPECT;
static int debugCalls = 0;
#define MAX_DEBUG_CALLS 40

// =============================================================================
//  ХУКИ ФУНКЦИЙ ИГРЫ (нужны офсеты)
// =============================================================================

static uint32_t stretchWidth(uint32_t sizeY) {
    if (sizeY == 0) return 0;
    uint32_t nx = (uint32_t)(sizeY * targetAspect);
    nx = (nx + 3) & ~3u;                 // выровнять по 4
    if (nx == 0) nx = 4;
    return nx;
}

static int looksLikeScreenSize(uint32_t x, uint32_t y) {
    return (x >= 200 && x <= 8000) && (y >= 200 && y <= 4000);
}

#if ENABLE_GAME_HOOKS
// ResizeViewport(this, uint32 SizeX, uint32 SizeY) -> void
static void (*orig_Resize)(void *self, uint32_t sizeX, uint32_t sizeY);
static void hook_Resize(void *self, uint32_t sizeX, uint32_t sizeY) {
    if (!orig_Resize) return;
    if (targetAspect > 1.0001 && looksLikeScreenSize(sizeX, sizeY)) {
        uint32_t nx = stretchWidth(sizeY);
        if (debugCalls < MAX_DEBUG_CALLS) {
            fprintf(stderr, "[Stretch] Resize in=(%u,%u) -> out=(%u,%u)\n", sizeX, sizeY, nx, sizeY);
            debugCalls++;
        }
        if (nx > 0 && nx != sizeX) { orig_Resize(self, nx, sizeY); return; }
    }
    orig_Resize(self, sizeX, sizeY);
}

// LayoutPlayers(this) -> void  (подпись может отличаться — корректируй!)
typedef void (*layout_fn)(void *self);
static layout_fn orig_Layout;
static void hook_Layout(void *self) {
    if (debugCalls < MAX_DEBUG_CALLS) {
        fprintf(stderr, "[Stretch] LayoutPlayers called\n"); debugCalls++;
    }
    if (orig_Layout) orig_Layout(self);
}
#endif

// =============================================================================
//  СПУФФИНГ UISCREEN (без оффсетов, даёт letterbox)
// =============================================================================
static CGRect (*orig_bounds)(id, SEL);
static CGRect (*orig_nativeBounds)(id, SEL);
static CGRect spoof(CGRect r) {
    if (targetAspect <= 1.0001) return r;
    CGFloat w = r.size.width, h = r.size.height;
    if (w <= 0 || h <= 0 || w <= h) return r;
    CGFloat nw = round(h * targetAspect);
    if (nw < 64 || nw > w * 2.0f) return r;
    return CGRectMake(r.origin.x + (w - nw) * 0.5f, r.origin.y, nw, h);
}
static CGRect hook_bounds(id s, SEL c) { return spoof(orig_bounds ? orig_bounds(s,c) : CGRectZero); }
static CGRect hook_nativeBounds(id s, SEL c) { return spoof(orig_nativeBounds ? orig_nativeBounds(s,c) : CGRectZero); }

// =============================================================================
//  ХЕЛПЕРЫ: найти бинарь по имени, проверить что адрес — исполняемый код
// =============================================================================
static int findImage(const char *want) {
    int n = _dyld_image_count();
    for (int i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, want)) return i;
    }
    return -1;
}
static uintptr_t textVaddrOf(const struct mach_header_64 *mh) {
    if (!mh) return 0;
    const uint8_t *c = (const uint8_t*)mh + sizeof(struct mach_header_64);
    for (int i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command*)c;
        if (lc->cmdsize == 0) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64*)lc;
            if (strncmp(sg->segname, "__TEXT", 6) == 0) return (uintptr_t)sg->vmaddr;
        }
        c += lc->cmdsize;
    }
    return 0;
}
static int isExec(const struct mach_header_64 *mh, uintptr_t va) {
    if (!mh) return 0;
    const uint8_t *c = (const uint8_t*)mh + sizeof(struct mach_header_64);
    for (int i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command*)c;
        if (lc->cmdsize == 0) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64*)lc;
            uintptr_t lo = (uintptr_t)sg->vmaddr, hi = lo + sg->vmsize;
            if (va >= lo && va < hi) return (sg->initprot & VM_PROT_EXECUTE) != 0;
        }
        c += lc->cmdsize;
    }
    return 0;
}

// Хук функции по офсету. off — VADDR (или file-offset если USE_FILE_OFFSET).
static int hookByOffset(const char *label, uint32_t off, void *hook, void **orig) {
    if (off == 0) { fprintf(stderr, "[Stretch] %s: offset=0 (disabled)\n", label); return 0; }
    int idx = findImage("ShadowTrackerExtra");
    if (idx < 0) { fprintf(stderr, "[Stretch] %s: image not found\n", label); return 0; }
    const struct mach_header_64 *mh = (const struct mach_header_64*)_dyld_get_image_header(idx);
    intptr_t slide = _dyld_get_image_vmaddr_slide(idx);
    uintptr_t text = textVaddrOf(mh);
    uintptr_t fileoff = USE_FILE_OFFSET ? (uintptr_t)off : (uintptr_t)off - 0x100000000ULL;
    uintptr_t va = text + fileoff;
    uintptr_t addr = va + (uintptr_t)slide;
    int exec = isExec(mh, va);
    fprintf(stderr, "[Stretch] %s: vaddr=0x%lx runtime=0x%lx exec=%d\n", label, (long)va, (long)addr, exec);
    if (!exec) { fprintf(stderr, "[Stretch] %s: NOT EXECUTABLE — wrong offset?\n", label); return 0; }
    if (DobbyHook((void*)addr, hook, orig) != 0) { fprintf(stderr, "[Stretch] %s: DobbyHook FAILED\n", label); return 0; }
    fprintf(stderr, "[Stretch] %s: hooked OK\n", label);
    return 1;
}

// =============================================================================
__attribute__((constructor))
static void init_stretch(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            fprintf(stderr, "[Stretch] init, aspect=%.3f\n", targetAspect);

#if ENABLE_GAME_HOOKS
            hookByOffset("Resize", OFFSET_RESIZE, (void*)hook_Resize, (void**)&orig_Resize);
            hookByOffset("Layout", OFFSET_LAYOUT, (void*)hook_Layout, (void**)&orig_Layout);
#else
            fprintf(stderr, "[Stretch] game hooks disabled\n");
#endif

#if ENABLE_UISPOOF
            Class cls = [UIScreen mainScreen].class;
            Method mb = class_getInstanceMethod(cls, @selector(bounds));
            if (mb) { orig_bounds = (CGRect(*)(id,SEL))method_getImplementation(mb);
                      method_setImplementation(mb, (IMP)hook_bounds); }
            Method mnb = class_getInstanceMethod(cls, @selector(nativeBounds));
            if (mnb) { orig_nativeBounds = (CGRect(*)(id,SEL))method_getImplementation(mnb);
                       method_setImplementation(mnb, (IMP)hook_nativeBounds); }
            fprintf(stderr, "[Stretch] UIScreen spoof on\n");
#endif
        });
    }
}
