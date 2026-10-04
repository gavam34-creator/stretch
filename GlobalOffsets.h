// =============================================================================
//  GLOBAL OFFSETS — сюда вставляешь офсеты под PUBG Mobile Global 4.6.1.2
//  Заглушки: значения -1 = "не задан". Если офсет -1, твик его не трогает.
// =============================================================================

#ifndef GLOBAL_OFFSETS_H
#define GLOBAL_OFFSETS_H

// Имя образа процесса для Global.
// У VN — "ShadowTrackerExtra". У Global — тоже "ShadowTrackerExtra"
// (проверь через `_dyld_get_image_name`, если не сработает).
#define GLOBAL_IMAGE_NAME   "ShadowTrackerExtra"

// Офсет слота GEngine в образе игры.
// VN: 0xA8A8A0. Global: НЕИЗВЕСТНО — вставь правильный.
#define G_GENGINE_OFF       0xA8A8A0UL

// Офсет флага FOV в UEngine.
// VN: 0x7C. Global: НЕИЗВЕСТНО — вставь правильный.
#define UENG_ASPECT_OFF     0x7C

// Офсет ViewportClient в UEngine.
#define UENG_VPCL_OFF       0x58

// Red Body (из сообщения Sahil): 6617E14 = 00F0271E
// Это не офсет UEngine, это отдельный патч. Используется в патчере ниже.
#define RED_BODY_OFFSET     0x6617E14UL
#define RED_BODY_VALUE      0x00F0271EUL

#endif // GLOBAL_OFFSETS_H