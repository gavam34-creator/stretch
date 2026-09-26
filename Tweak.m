#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <substrate.h>

// Найденный офсет (vaddr)
#define RESIZE_VADDR 0x1032D3AC0
#define BASE_VADDR   0x100000000

static CGFloat targetAspect = 4.0 / 3.0;
static BOOL stretchEnabled = YES;

// Оригинальная функция
static void (*orig_ResizeViewport)(void *self, uint32_t sizeX, uint32_t sizeY);

// Наш хук
static void hook_ResizeViewport(void *self, uint32_t sizeX, uint32_t sizeY) {
    if (stretchEnabled && sizeY > 0) {
        // Подменяем ширину под нужный аспект
        uint32_t newX = (uint32_t)(sizeY * targetAspect);
        return orig_ResizeViewport(self, newX, sizeY);
    }
    return orig_ResizeViewport(self, sizeX, sizeY);
}

__attribute__((constructor))
static void init_hook(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Вычисляем реальный адрес с учётом ASLR
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        uintptr_t realAddr = (uintptr_t)(RESIZE_VADDR + slide);

        MSHookFunction((void *)realAddr, (void *)hook_ResizeViewport, (void **)&orig_ResizeViewport);
    });
}