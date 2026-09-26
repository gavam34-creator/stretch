#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import "dobby.h"

// ---------------------------------------------------------------------------
// ВАЖНО: оффсет 0x032D3AC0 — НЕ FSceneViewport::ResizeViewport (проверено
// в Ghidra: это менеджер рендер-таргетов, пробрасывающий размер в дочерние
// вьюпорты). Хук с ИЗМЕНЕНИЕМ аргументов по этому адресу роняет игру.
// Поэтому APPLY_STRETCH=0 по умолчанию: хук только ЛОГИРУЕТ, аргументы не
// трогает — игра не падает. Для растяжки нужен ВЕРНЫЙ офсет + APPLY_STRETCH=1.
// ---------------------------------------------------------------------------
#define RESIZE_OFFSET 0x032D3AC0   // кандидат (НЕ ResizeViewport) — только лог!
#define BASE_VADDR    0x100000000   // __TEXT.vmaddr (image base, iOS arm64)

#define APPLY_STRETCH  0            // 0 = только лог (безопасно), 1 = растяжка

// Целевой aspect — ШИРОКАЯ растяжка. Натив iPhone 14 Pro Max = 19.5:9 (2.167).
// Ставь БОЛЬШЕ 2.167, чтобы обзор по горизонтали стал шире:
//   20:9 = 2.222 | 21:9 = 2.333 (по умолчанию) | 24:9 = 2.667 | 32:9 = 3.556
#define TARGET_ASPECT  (7.0 / 3.0)

static double targetAspect = TARGET_ASPECT;
static BOOL stretchEnabled = YES;
static int debugCalls = 0;
#define MAX_DEBUG_CALLS 40

static void (*orig_ResizeViewport)(void *self, uint32_t sizeX, uint32_t sizeY);

// Защита: трогаем аргументы только если они похожи на размер экрана.
static int looksLikeScreenSize(uint32_t x, uint32_t y) {
    return (x >= 200 && x <= 8000) && (y >= 200 && y <= 4000);
}

static void hook_ResizeViewport(void *self, uint32_t sizeX, uint32_t sizeY) {
    if (orig_ResizeViewport == NULL) return;

#if APPLY_STRETCH
    if (stretchEnabled && sizeY > 0 && looksLikeScreenSize(sizeX, sizeY)) {
        uint32_t newX = (uint32_t)(sizeY * targetAspect);
        newX = (newX + 4) & ~7u;   // выровнять по 8
        if (debugCalls < MAX_DEBUG_CALLS) {
            fprintf(stderr, "[Stretch] RV in=(%u,%u) -> out=(%u,%u)\n", sizeX, sizeY, newX, sizeY);
            debugCalls++;
        }
        if (newX > 0 && newX != sizeX) {
            orig_ResizeViewport(self, newX, sizeY);
            return;
        }
    }
#else
    // Безопасный режим: только лог, аргументы НЕ меняем (иначе краш).
    if (debugCalls < MAX_DEBUG_CALLS && looksLikeScreenSize(sizeX, sizeY)) {
        fprintf(stderr, "[Stretch][log-only] this=%p sizeX=%u sizeY=%u\n",
                (void *)self, sizeX, sizeY);
        debugCalls++;
    }
#endif
    orig_ResizeViewport(self, sizeX, sizeY);
}

// ---- helpers: найти бинарь по имени, вычислить vaddr, проверить RX ----
static int findShadowTrackerImage(void) {
    int n = _dyld_image_count();
    for (int i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "ShadowTrackerExtra")) return i;
    }
    return 0;  // fallback: main executable
}

static uintptr_t textVaddrOf(const struct mach_header_64 *mh) {
    if (!mh) return 0;
    const uint8_t *cmd = (const uint8_t *)mh + sizeof(struct mach_header_64);
    for (int i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmdsize == 0) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strncmp(sg->segname, "__TEXT", 6) == 0) return (uintptr_t)sg->vmaddr;
        }
        cmd += lc->cmdsize;
    }
    return 0;
}

static int isExecutableAt(const struct mach_header_64 *mh, uintptr_t vaddr) {
    if (!mh) return 0;
    const uint8_t *cmd = (const uint8_t *)mh + sizeof(struct mach_header_64);
    for (int i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmdsize == 0) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            uintptr_t lo = (uintptr_t)sg->vmaddr, hi = lo + sg->vmsize;
            if (vaddr >= lo && vaddr < hi) {
                return (sg->initprot & VM_PROT_EXECUTE) != 0;
            }
        }
        cmd += lc->cmdsize;
    }
    return 0;
}

__attribute__((constructor))
static void init_hook(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        int idx = findShadowTrackerImage();
        const char *imgName = _dyld_get_image_name(idx);
        const struct mach_header_64 *mh =
            (const struct mach_header_64 *)_dyld_get_image_header(idx);
        intptr_t slide = _dyld_get_image_vmaddr_slide(idx);
        uintptr_t textVaddr = textVaddrOf(mh);

        uintptr_t targetVaddr = textVaddr + RESIZE_OFFSET;  // __TEXT fileoff==0
        uintptr_t hookAddr = targetVaddr + (uintptr_t)slide;

        fprintf(stderr, "[Stretch] image[%d]=%s slide=0x%lx textVaddr=0x%lx\n",
                idx, imgName ? imgName : "?", (long)slide, (long)textVaddr);
        fprintf(stderr, "[Stretch] target vaddr=0x%lx runtime=0x%lx\n",
                (long)targetVaddr, (long)hookAddr);
        fprintf(stderr, "[Stretch] base match(BASE_VADDR=0x%lx)=%d  exec=%d\n",
                (long)BASE_VADDR, (int)(textVaddr == BASE_VADDR),
                isExecutableAt(mh, targetVaddr));

        if (!isExecutableAt(mh, targetVaddr)) {
            fprintf(stderr, "[Stretch] TARGET NOT EXECUTABLE — wrong offset?\n");
            return;
        }

        if (DobbyHook((void *)hookAddr,
                      (void *)hook_ResizeViewport,
                      (void **)&orig_ResizeViewport) != 0) {
            fprintf(stderr, "[Stretch] DobbyHook FAILED\n");
        } else {
            fprintf(stderr, "[Stretch] hook installed OK (aspect=%.3f)\n", targetAspect);
        }
    });
}
