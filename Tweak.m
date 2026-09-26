#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

// Dobby — встроенный hook-движок, не требует substrate
extern void *DobbyHook(void *address, void *replace, void **origin);

// Офсет из Ghidra (file-offset от базы 0x100000000)
#define RESIZE_OFFSET 0x032D3AC0
#define BASE_VADDR    0x100000000

static CGFloat targetAspect = 4.0 / 3.0;
static BOOL stretchEnabled = YES;

static void (*orig_ResizeViewport)(void *self, uint32_t sizeX, uint32_t sizeY);

static void hook_ResizeViewport(void *self, uint32_t sizeX, uint32_t sizeY) {
    if (stretchEnabled && sizeY > 0) {
        uint32_t newX = (uint32_t)(sizeY * targetAspect);
        return orig_ResizeViewport(self, newX, sizeY);
    }
    return orig_ResizeViewport(self, sizeX, sizeY);
}

__attribute__((constructor))
static void init_hook(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        uintptr_t realAddr = (uintptr_t)(slide + RESIZE_OFFSET + BASE_VADDR);

        DobbyHook((void *)realAddr,
                  (void *)hook_ResizeViewport,
                  (void **)&orig_ResizeViewport);
    });
}
