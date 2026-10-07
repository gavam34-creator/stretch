// =============================================================================
//  GLOBAL OFFSETS
//  PUBG Mobile Global 4.6.1.2
//
//  ПРАВИЛО: офсет = 0 -> твик его НЕ трогает и пишет это в консоль.
//  (В предыдущей версии в комментарии было "-1", а код проверял 0 — правим
//   на код: 0 = "не настроен".)
//
//  ТЕКУЩИЕ ЗНАЧЕНИЯ ВЗЯТЫ ИЗ VN-СБОРКИ 4.6 И ДЛЯ GLOBAL НЕ ПОДТВЕРЖДЕНЫ.
//  Первое, что нужно сделать на устройстве: кнопка DIAG в меню.
//  В логе будет:
//    DIAG slot kr=0 engine=0x...      kr!=0 -> слот не читается, G_GENGINE_OFF неверен
//    DIAG looksLikeUEngine=0          объект не UEngine -> G_GENGINE_OFF неверен
//    DIAG OK: +0x7C похож на enum     офсет флага верен
//    DIAG WARN -> автоскан, ищет строку "scan: +0x?? = N"
//  Найденное значение вставляется сюда и пересобирается.
// =============================================================================

#ifndef GLOBAL_OFFSETS_H
#define GLOBAL_OFFSETS_H

// Basename целевого образа (сравнивается ТОЧНО, не подстрокой).
// VN и Global оба используют "ShadowTrackerExtra".
#define GLOBAL_IMAGE_NAME   "ShadowTrackerExtra"

// Слот глобального указателя UEngine* GEngine, отсчёт от базы образа.
// VN 4.6: 0xA8A8A0 (подтверждён: GEngine->Init vtable 0x2D0, ->Start 0x2D8).
// Global 4.6.1.2: НЕ ПОДТВЕРЖДЕНО.
#define G_GENGINE_OFF       0xA8A8A0UL

// UEngine::AspectRatioAxisConstraint, смещение внутри объекта UEngine.
//   0 = MaintainYFOV (поля сверху/снизу), 1 = MaintainXFOV (стритч, полос нет),
//   2 = MajorAxisFOV.
// VN 4.6: 0x7C. Global 4.6.1.2: НЕ ПОДТВЕРЖДЕНО.
#define UENG_ASPECT_OFF     0x7C

// UEngine::ViewportClient — для диагностики (диаграмма шага 4).
// VN 4.6: 0x58.
#define UENG_VPCL_OFF       0x58

// Red Body (сообщение Sahil): 6617E14 = 00F0271E.
// НЕ используется в Tweak.m — это не офсет FOV, а отдельная запись памяти.
// Оставлено только как заметка.
#define RED_BODY_OFFSET     0x6617E14UL
#define RED_BODY_VALUE      0x00F0271EUL

#endif // GLOBAL_OFFSETS_H