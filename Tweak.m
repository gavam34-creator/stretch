#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach-o/dyld.h>
#import <stdint.h>
#import <stdio.h>
#import "dobby.h"

// Оффсет FSceneViewport::ResizeViewport (file-offset в бинаре ShadowTrackerExtra)
#define RESIZE_OFFSET 0x032D3AC0
#define BASE_VADDR    0x100000000

// Целевое соотношение сторон — ШИРОКАЯ «растяжка», как на Android.
// Нативный iPhone 14 Pro Max = 19.5:9 (~2.167). Чтобы обзор по горизонтали
// стал ШИРЕ нативного, ставь значение БОЛЬШЕ 2.167:
//     20:9 = 2.222
//     21:9 = 2.333   <-- по умолчанию
//     24:9 = 2.667   (ультра-широкий)
//     32:9 = 3.556   (максимум, картинка сильно вытянута)
#define TARGET_ASPECT  (7.0 / 3.0)   // 21:9

static double targetAspect = TARGET_ASPECT;
static BOOL stretchEnabled = YES;

static void (*orig_ResizeViewport)(void *self, uint32_t sizeX, uint32_t sizeY);

static void hook_ResizeViewport(void *self, uint32_t sizeX, uint32_t sizeY) {
    if (orig_ResizeViewport == NULL) return;

    if (stretchEnabled && sizeY > 0) {
        uint32_t newX = (uint32_t)(sizeY * targetAspect);
        // округляем ширину к кратному 8 — некоторые движки требуют выравнивания
        newX = (newX + 4) & ~7u;
        if (newX > 0 && newX != sizeX) {
            orig_ResizeViewport(self, newX, sizeY);
            return;
        }
    }
    orig_ResizeViewport(self, sizeX, sizeY);
}

__attribute__((constructor))
static void init_hook(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // slide = разница между загруженным и предпочтительным адресом main-бинаря
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        uintptr_t realAddr = (uintptr_t)(slide + BASE_VADDR + RESIZE_OFFSET);

        fprintf(stderr, "[Stretch] slide=0x%lx hook@0x%lx\n", (long)slide, (long)realAddr);

        if (DobbyHook((void *)realAddr,
                      (void *)hook_ResizeViewport,
                      (void **)&orig_ResizeViewport) != 0) {
            fprintf(stderr, "[Stretch] DobbyHook FAILED\n");
        } else {
            fprintf(stderr, "[Stretch] hook installed OK\n");
        }
    });
}
