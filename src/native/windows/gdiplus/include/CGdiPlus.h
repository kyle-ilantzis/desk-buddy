// The few GDI+ flat API calls the Windows layer makes. Windows' own gdiplus.h is C++
// (it wraps these in namespaces), so Swift can't import it; these are the same
// gdiplus.dll exports, declared in C. Types are opaque: an image is a GpImage*, and a
// bitmap is one too.
#pragma once
#include <windows.h>

typedef struct GpImage GpImage;
typedef struct GpGraphics GpGraphics;
typedef struct GpBrush GpBrush;
typedef struct GpPath GpPath;
typedef struct GpFont GpFont;
typedef struct GpFontFamily GpFontFamily;
typedef struct GpStringFormat GpStringFormat;
typedef int GpStatus; // 0 is Ok

typedef struct {
    UINT32 GdiplusVersion;          // 1
    void *DebugEventCallback;
    BOOL SuppressBackgroundThread;
    BOOL SuppressExternalCodecs;
} CGdipStartupInput;

typedef struct { INT X, Y, Width, Height; } CGdipRect;
typedef struct { float X, Y, Width, Height; } CGdipRectF;

typedef struct {
    UINT Width;
    UINT Height;
    INT Stride;
    INT PixelFormat;
    void *Scan0;
    UINT_PTR Reserved;
} CGdipBitmapData;

enum {
    CGdipPixelFormat32bppPARGB = 0x000E200B,
    CGdipImageLockModeRead = 1,
    CGdipUnitPixel = 2,
    CGdipFontStyleRegular = 0,
    CGdipFontStyleBold = 1,
    CGdipSmoothingModeAntiAlias = 4,
    CGdipInterpolationModeNearestNeighbor = 5,
    CGdipPixelOffsetModeHalf = 4,
    CGdipTextRenderingHintAntiAliasGridFit = 3,
    CGdipCompositingModeSourceOver = 0,
    CGdipCompositingModeSourceCopy = 1,
    CGdipFillModeAlternate = 0,
    CGdipMatrixOrderPrepend = 0,
};

GpStatus WINAPI GdiplusStartup(ULONG_PTR *token, const CGdipStartupInput *input, void *output);
void WINAPI GdiplusShutdown(ULONG_PTR token);

GpStatus WINAPI GdipCreateBitmapFromFile(const WCHAR *filename, GpImage **bitmap);
GpStatus WINAPI GdipCreateBitmapFromScan0(INT width, INT height, INT stride, INT format, BYTE *scan0, GpImage **bitmap);
GpStatus WINAPI GdipGetImageWidth(GpImage *image, UINT *width);
GpStatus WINAPI GdipGetImageHeight(GpImage *image, UINT *height);
GpStatus WINAPI GdipBitmapLockBits(GpImage *bitmap, const CGdipRect *rect, UINT flags, INT format, CGdipBitmapData *data);
GpStatus WINAPI GdipBitmapUnlockBits(GpImage *bitmap, CGdipBitmapData *data);
GpStatus WINAPI GdipSaveImageToFile(GpImage *image, const WCHAR *filename, const CLSID *encoder, const void *params);
GpStatus WINAPI GdipDisposeImage(GpImage *image);

GpStatus WINAPI GdipGetImageGraphicsContext(GpImage *image, GpGraphics **graphics);
GpStatus WINAPI GdipDeleteGraphics(GpGraphics *graphics);
GpStatus WINAPI GdipGraphicsClear(GpGraphics *graphics, DWORD argb);
GpStatus WINAPI GdipSetSmoothingMode(GpGraphics *graphics, INT mode);
GpStatus WINAPI GdipSetInterpolationMode(GpGraphics *graphics, INT mode);
GpStatus WINAPI GdipSetPixelOffsetMode(GpGraphics *graphics, INT mode);
GpStatus WINAPI GdipSetTextRenderingHint(GpGraphics *graphics, INT hint);
GpStatus WINAPI GdipSetCompositingMode(GpGraphics *graphics, INT mode);
GpStatus WINAPI GdipTranslateWorldTransform(GpGraphics *graphics, float dx, float dy, INT order);
GpStatus WINAPI GdipScaleWorldTransform(GpGraphics *graphics, float sx, float sy, INT order);
GpStatus WINAPI GdipResetWorldTransform(GpGraphics *graphics);

GpStatus WINAPI GdipCreateSolidFill(DWORD argb, GpBrush **brush);
GpStatus WINAPI GdipDeleteBrush(GpBrush *brush);
GpStatus WINAPI GdipFillEllipse(GpGraphics *graphics, GpBrush *brush, float x, float y, float width, float height);
GpStatus WINAPI GdipFillRectangle(GpGraphics *graphics, GpBrush *brush, float x, float y, float width, float height);
GpStatus WINAPI GdipCreatePath(INT fillMode, GpPath **path);
GpStatus WINAPI GdipAddPathArc(GpPath *path, float x, float y, float width, float height, float startAngle, float sweepAngle);
GpStatus WINAPI GdipClosePathFigure(GpPath *path);
GpStatus WINAPI GdipFillPath(GpGraphics *graphics, GpBrush *brush, GpPath *path);
GpStatus WINAPI GdipDeletePath(GpPath *path);
GpStatus WINAPI GdipDrawImageRectRectI(GpGraphics *graphics, GpImage *image,
                                       INT dstx, INT dsty, INT dstwidth, INT dstheight,
                                       INT srcx, INT srcy, INT srcwidth, INT srcheight,
                                       INT srcUnit, const void *imageAttributes, void *callback, void *callbackData);

GpStatus WINAPI GdipCreateFontFamilyFromName(const WCHAR *name, void *fontCollection, GpFontFamily **family);
GpStatus WINAPI GdipDeleteFontFamily(GpFontFamily *family);
GpStatus WINAPI GdipCreateFont(const GpFontFamily *family, float emSize, INT style, INT unit, GpFont **font);
GpStatus WINAPI GdipDeleteFont(GpFont *font);
GpStatus WINAPI GdipStringFormatGetGenericTypographic(GpStringFormat **format);
GpStatus WINAPI GdipDrawString(GpGraphics *graphics, const WCHAR *string, INT length, const GpFont *font,
                               const CGdipRectF *layoutRect, const GpStringFormat *format, const GpBrush *brush);
GpStatus WINAPI GdipMeasureString(GpGraphics *graphics, const WCHAR *string, INT length, const GpFont *font,
                                  const CGdipRectF *layoutRect, const GpStringFormat *format, CGdipRectF *boundingBox,
                                  INT *codepointsFitted, INT *linesFilled);
