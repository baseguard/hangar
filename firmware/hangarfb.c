// Backs the firmware's graphics output with a linear framebuffer, which the Windows boot manager draws into directly:
// the driver keeps a buffer of its own, advertises it as the framebuffer and copies the rows that changed to the
// screen 25 times a second, until ExitBootServices hands the machine to Windows' own driver.
// It also stays in the guest: it registers itself in the guest's NVRAM as a DriverXXXX load option in DriverOrder, so
// the firmware loads it on every later boot, after the bootstrap has left the boot path.
#include "efi.h"

#define MAX_WIDTH 1920
#define MAX_HEIGHT 1200
#define BYTES_PER_PIXEL 4
#define MAX_HOOKS 8
#define FLUSH_PERIOD 400000  // 40 ms, in the timer's 100 ns ticks

static EFI_GUID GraphicsOutputGuid = EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID;
static EFI_GUID DevicePathGuid = EFI_DEVICE_PATH_PROTOCOL_GUID;
static EFI_GUID GlobalVariableGuid = EFI_GLOBAL_VARIABLE_GUID;
static EFI_GUID ExitBootServicesGroup = EFI_EVENT_GROUP_EXIT_BOOT_SERVICES;
static EFI_GUID HangarFramebufferGuid = {0x3c1f6a2e, 0x8b47, 0x4d0a, {0x9e, 0x52, 0x71, 0x0b, 0xc4, 0x3a, 0x68, 0xd5}};

static CHAR16 OptionPath[] = L"\\EFI\\Hangar\\hangarfb.efi";
static CHAR16 OptionDescription[] = L"Hangar framebuffer";

static EFI_BOOT_SERVICES *BS;
static EFI_RUNTIME_SERVICES *RT;

static UINT8 *Pixels;
static UINT8 *Shown;
static const UINTN Capacity = (UINTN)MAX_WIDTH * MAX_HEIGHT * BYTES_PER_PIXEL;
static BOOLEAN Flushing;
static volatile BOOLEAN Switching;
static EFI_EVENT FlushTimer;

typedef struct {
  EFI_GRAPHICS_OUTPUT_PROTOCOL *gop;
  EFI_GOP_QUERY_MODE queryMode;
  EFI_GOP_SET_MODE setMode;
  EFI_GOP_BLT blt;
} Hook;

static Hook Hooks[MAX_HOOKS];
static UINTN HookCount;
static Hook *Screen;
static VOID *GopNotifyRegistration;

static Hook *HookFor(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop) {
  for (UINTN i = 0; i < HookCount; i++) {
    if (Hooks[i].gop == gop) return &Hooks[i];
  }
  return NULL;
}

static BOOLEAN WithinLimits(const EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
  return info && info->HorizontalResolution <= MAX_WIDTH && info->VerticalResolution <= MAX_HEIGHT;
}

static BOOLEAN Backed(const EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
  return Pixels && WithinLimits(info);
}

static void DescribeFramebuffer(EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
  info->PixelFormat = PixelBlueGreenRedReserved8BitPerColor;
  info->PixelInformation = (EFI_PIXEL_BITMASK){0, 0, 0, 0};
  info->PixelsPerScanLine = info->HorizontalResolution;
}

static void Advertise(void) {
  for (UINTN i = 0; i < HookCount; i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *mode = Hooks[i].gop->Mode;
    if (!mode || !Backed(mode->Info)) continue;
    DescribeFramebuffer(mode->Info);
    mode->FrameBufferBase = (EFI_PHYSICAL_ADDRESS)(UINTN)Pixels;
    mode->FrameBufferSize = (UINTN)mode->Info->HorizontalResolution * mode->Info->VerticalResolution * BYTES_PER_PIXEL;
  }
}

static BOOLEAN RowsEqual(const UINT8 *a, const UINT8 *b, UINTN bytes) {
  const UINT64 *x = (const UINT64 *)a, *y = (const UINT64 *)b;
  UINTN words = bytes / 8;
  for (UINTN i = 0; i < words; i++) {
    if (x[i] != y[i]) return FALSE;
  }
  for (UINTN i = words * 8; i < bytes; i++) {
    if (a[i] != b[i]) return FALSE;
  }
  return TRUE;
}

static void Present(UINTN firstRow, UINTN rows, UINTN width) {
  Screen->blt(Screen->gop, (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)Pixels, EfiBltBufferToVideo, 0, firstRow, 0, firstRow,
              width, rows, width * BYTES_PER_PIXEL);
}

static VOID EFIAPI Flush(EFI_EVENT event, VOID *context) {
  if (!Flushing || Switching || !Backed(Screen->gop->Mode->Info)) return;

  UINTN width = Screen->gop->Mode->Info->HorizontalResolution;
  UINTN height = Screen->gop->Mode->Info->VerticalResolution;
  UINTN stride = width * BYTES_PER_PIXEL;
  UINTN runStart = 0, runLength = 0;

  for (UINTN row = 0; row < height; row++) {
    UINT8 *now = Pixels + row * stride, *before = Shown + row * stride;
    if (RowsEqual(now, before, stride)) {
      if (runLength) Present(runStart, runLength, width);
      runLength = 0;
      continue;
    }
    CopyBytes(before, now, stride);
    if (!runLength) runStart = row;
    runLength++;
  }
  if (runLength) Present(runStart, runLength, width);
}

static VOID EFIAPI StopFlushing(EFI_EVENT event, VOID *context) {
  Flushing = FALSE;
}

static EFI_STATUS EFIAPI QueryMode(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop, UINT32 number, UINTN *size,
                                   EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **info) {
  Hook *hook = HookFor(gop);
  if (!hook) return EFI_INVALID_PARAMETER;

  EFI_STATUS status = hook->queryMode(gop, number, size, info);
  if (!EFI_ERROR(status) && info && Backed(*info)) DescribeFramebuffer(*info);
  return status;
}

static EFI_STATUS EFIAPI SetMode(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop, UINT32 number) {
  Hook *hook = HookFor(gop);
  if (!hook) return EFI_INVALID_PARAMETER;

  if (Pixels) {
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info;
    UINTN size;
    if (EFI_ERROR(hook->queryMode(gop, number, &size, &info))) return EFI_UNSUPPORTED;
    BOOLEAN backed = Backed(info);
    BS->FreePool(info);
    if (!backed) return EFI_UNSUPPORTED;
  }

  Switching = TRUE;
  EFI_STATUS status = hook->setMode(gop, number);
  if (!EFI_ERROR(status) && Pixels) {
    memset(Pixels, 0, Capacity);
    memset(Shown, 0, Capacity);
    Advertise();
  }
  Switching = FALSE;
  return status;
}

static void MovePixels(UINT32 *to, const UINT32 *from, UINTN count) {
  if (to < from) {
    for (UINTN i = 0; i < count; i++) to[i] = from[i];
  } else {
    while (count--) to[count] = from[count];
  }
}

static EFI_STATUS EFIAPI Blt(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop, EFI_GRAPHICS_OUTPUT_BLT_PIXEL *buffer, UINT32 operation,
                             UINTN sourceX, UINTN sourceY, UINTN destinationX, UINTN destinationY, UINTN width,
                             UINTN height, UINTN delta) {
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = gop->Mode->Info;
  if (!Backed(info)) {
    return Screen->blt(gop, buffer, operation, sourceX, sourceY, destinationX, destinationY, width, height, delta);
  }
  if (operation > EfiBltVideoToVideo || (!buffer && operation != EfiBltVideoToVideo)) return EFI_INVALID_PARAMETER;

  UINTN screenWidth = info->HorizontalResolution, screenHeight = info->VerticalResolution;
  BOOLEAN readsScreen = operation == EfiBltVideoToBltBuffer || operation == EfiBltVideoToVideo;
  BOOLEAN writesScreen = operation != EfiBltVideoToBltBuffer;
  if (readsScreen && (sourceX + width > screenWidth || sourceY + height > screenHeight)) return EFI_INVALID_PARAMETER;
  if (writesScreen && (destinationX + width > screenWidth || destinationY + height > screenHeight)) {
    return EFI_INVALID_PARAMETER;
  }
  if (!delta) delta = width * sizeof(EFI_GRAPHICS_OUTPUT_BLT_PIXEL);

  UINT32 *screen = (UINT32 *)Pixels;
  for (UINTN i = 0; i < height; i++) {
    UINTN y = operation == EfiBltVideoToVideo && destinationY > sourceY ? height - 1 - i : i;
    switch (operation) {
    case EfiBltVideoFill: {
      UINT32 *to = screen + (destinationY + y) * screenWidth + destinationX;
      for (UINTN x = 0; x < width; x++) to[x] = *(UINT32 *)buffer;
      break;
    }
    case EfiBltBufferToVideo:
      MovePixels(screen + (destinationY + y) * screenWidth + destinationX,
                 (UINT32 *)((UINT8 *)buffer + (sourceY + y) * delta) + sourceX, width);
      break;
    case EfiBltVideoToBltBuffer:
      MovePixels((UINT32 *)((UINT8 *)buffer + (destinationY + y) * delta) + destinationX,
                 screen + (sourceY + y) * screenWidth + sourceX, width);
      break;
    case EfiBltVideoToVideo:
      MovePixels(screen + (destinationY + y) * screenWidth + destinationX,
                 screen + (sourceY + y) * screenWidth + sourceX, width);
      break;
    }
  }
  return EFI_SUCCESS;
}

static BOOLEAN FitMode(Hook *hook) {
  EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *mode = hook->gop->Mode;
  if (WithinLimits(mode->Info)) return TRUE;

  UINT32 best = mode->MaxMode;
  UINTN bestArea = 0;
  for (UINT32 number = 0; number < mode->MaxMode; number++) {
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info;
    UINTN size;
    if (EFI_ERROR(hook->queryMode(hook->gop, number, &size, &info))) continue;
    UINTN area = (UINTN)info->HorizontalResolution * info->VerticalResolution;
    if (WithinLimits(info) && area > bestArea) {
      best = number;
      bestArea = area;
    }
    BS->FreePool(info);
  }
  return best < mode->MaxMode && !EFI_ERROR(hook->setMode(hook->gop, best)) && WithinLimits(mode->Info);
}

// Reserved memory, so Windows doesn't hand the pages out as RAM while its boot screens still draw into them.
static BOOLEAN AllocateFramebuffer(void) {
  EFI_PHYSICAL_ADDRESS address;
  if (EFI_ERROR(BS->AllocatePages(AllocateAnyPages, EfiReservedMemoryType, (Capacity + 4095) / 4096, &address))) {
    return FALSE;
  }
  if (EFI_ERROR(BS->AllocatePool(EfiBootServicesData, Capacity, (VOID **)&Shown))) {
    BS->FreePages(address, (Capacity + 4095) / 4096);
    return FALSE;
  }
  Pixels = (UINT8 *)(UINTN)address;
  memset(Pixels, 0, Capacity);
  memset(Shown, 0, Capacity);
  return TRUE;
}

// The first output with a device path is the screen. Outputs without one get the same hooks and the same framebuffer,
// so Windows sees one picture whichever output it draws through.
static void Adopt(EFI_HANDLE handle) {
  EFI_GRAPHICS_OUTPUT_PROTOCOL *gop;
  if (EFI_ERROR(BS->HandleProtocol(handle, &GraphicsOutputGuid, (VOID **)&gop)) || !gop || !gop->Mode) return;
  if (HookFor(gop) || HookCount == MAX_HOOKS) return;

  Hook *hook = &Hooks[HookCount++];
  *hook = (Hook){gop, gop->QueryMode, gop->SetMode, gop->Blt};
  gop->QueryMode = QueryMode;
  gop->SetMode = SetMode;

  VOID *devicePath;
  if (!Screen && !EFI_ERROR(BS->HandleProtocol(handle, &DevicePathGuid, &devicePath)) && FitMode(hook) &&
      AllocateFramebuffer()) {
    Screen = hook;
    gop->Blt = Blt;
    Flushing = TRUE;
    BS->SetTimer(FlushTimer, TimerPeriodic, FLUSH_PERIOD);
  }
  Advertise();
}

static VOID EFIAPI AdoptNewGops(EFI_EVENT event, VOID *context) {
  UINTN count;
  EFI_HANDLE *handles;
  while (!EFI_ERROR(BS->LocateHandleBuffer(ByRegisterNotify, NULL, GopNotifyRegistration, &count, &handles))) {
    for (UINTN i = 0; i < count; i++) Adopt(handles[i]);
    BS->FreePool(handles);
  }
}

static void OptionName(CHAR16 name[11], UINT16 number) {
  static const CHAR16 digits[] = L"0123456789ABCDEF";
  CopyBytes(name, L"Driver", 6 * sizeof(CHAR16));
  for (int i = 0; i < 4; i++) name[6 + i] = digits[(number >> (12 - 4 * i)) & 0xf];
  name[10] = 0;
}

static BOOLEAN IsOurOption(UINT16 number) {
  CHAR16 name[11];
  UINT8 option[512];
  UINTN size = sizeof(option);
  OptionName(name, number);
  if (EFI_ERROR(RT->GetVariable(name, &GlobalVariableGuid, NULL, &size, option))) return FALSE;

  UINTN pathBytes = sizeof(OptionPath) - sizeof(CHAR16);
  for (UINTN offset = 0; offset + pathBytes <= size; offset += 2) {
    BOOLEAN match = TRUE;
    for (UINTN i = 0; i < pathBytes && match; i++) match = option[offset + i] == ((UINT8 *)OptionPath)[i];
    if (match) return TRUE;
  }
  return FALSE;
}

// Registers the driver as a DriverXXXX load option, so the firmware loads it from NVRAM on every later boot, when
// the Windows boot manager starts directly and the bootstrap is no longer in the path.
static void RegisterLoadOption(void) {
  UINT16 order[128];
  UINTN orderSize = sizeof(order);
  EFI_STATUS status = RT->GetVariable(L"DriverOrder", &GlobalVariableGuid, NULL, &orderSize, order);
  if (status == EFI_NOT_FOUND) {
    orderSize = 0;
  } else if (EFI_ERROR(status)) {
    return;
  }
  UINTN count = orderSize / sizeof(UINT16);
  if (count == sizeof(order) / sizeof(UINT16)) return;
  for (UINTN i = 0; i < count; i++) {
    if (IsOurOption(order[i])) return;
  }

  CHAR16 name[11];
  UINT32 number = 0;
  for (; number <= 0xffff; number++) {
    UINTN size = 0;
    OptionName(name, (UINT16)number);
    if (RT->GetVariable(name, &GlobalVariableGuid, NULL, &size, NULL) == EFI_NOT_FOUND) break;
  }
  if (number > 0xffff) return;

  UINT8 option[4 + 2 + sizeof(OptionDescription) + sizeof(EFI_DEVICE_PATH_PROTOCOL) + sizeof(OptionPath) +
               sizeof(EFI_DEVICE_PATH_PROTOCOL)];
  UINT32 attributes = LOAD_OPTION_ACTIVE;
  UINT16 fileNodeLength = sizeof(EFI_DEVICE_PATH_PROTOCOL) + sizeof(OptionPath);
  UINT16 pathLength = fileNodeLength + sizeof(EFI_DEVICE_PATH_PROTOCOL);
  EFI_DEVICE_PATH_PROTOCOL fileNode = {MEDIA_DEVICE_PATH, MEDIA_FILEPATH_DP, {fileNodeLength & 0xff, fileNodeLength >> 8}};
  EFI_DEVICE_PATH_PROTOCOL endNode = {END_DEVICE_PATH_TYPE, END_ENTIRE_DEVICE_PATH_SUBTYPE, {sizeof(endNode), 0}};

  UINT8 *p = option;
  p = AppendBytes(p, &attributes, sizeof(attributes));
  p = AppendBytes(p, &pathLength, sizeof(pathLength));
  p = AppendBytes(p, OptionDescription, sizeof(OptionDescription));
  p = AppendBytes(p, &fileNode, sizeof(fileNode));
  p = AppendBytes(p, OptionPath, sizeof(OptionPath));
  AppendBytes(p, &endNode, sizeof(endNode));

  UINT32 variableAttributes = EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS;
  if (EFI_ERROR(RT->SetVariable(name, &GlobalVariableGuid, variableAttributes, sizeof(option), option))) return;
  order[count] = (UINT16)number;
  RT->SetVariable(L"DriverOrder", &GlobalVariableGuid, variableAttributes, (count + 1) * sizeof(UINT16), order);
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *systemTable) {
  BS = systemTable->BootServices;
  RT = systemTable->RuntimeServices;

  RegisterLoadOption();

  VOID *resident;
  if (!EFI_ERROR(BS->LocateProtocol(&HangarFramebufferGuid, NULL, &resident))) return EFI_ALREADY_STARTED;

  EFI_STATUS status = BS->CreateEvent(EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, Flush, NULL, &FlushTimer);
  if (EFI_ERROR(status)) return status;
  EFI_EVENT exitBootServices;
  status = BS->CreateEventEx(EVT_NOTIFY_SIGNAL, TPL_CALLBACK, StopFlushing, NULL, &ExitBootServicesGroup,
                             &exitBootServices);
  if (EFI_ERROR(status)) {
    BS->CloseEvent(FlushTimer);
    return status;
  }

  EFI_EVENT gopInstalled;
  status = BS->CreateEvent(EVT_NOTIFY_SIGNAL, TPL_CALLBACK, AdoptNewGops, NULL, &gopInstalled);
  if (EFI_ERROR(status)) {
    BS->CloseEvent(exitBootServices);
    BS->CloseEvent(FlushTimer);
    return status;
  }
  BS->RegisterProtocolNotify(&GraphicsOutputGuid, gopInstalled, &GopNotifyRegistration);

  UINTN count;
  EFI_HANDLE *handles;
  if (!EFI_ERROR(BS->LocateHandleBuffer(ByProtocol, &GraphicsOutputGuid, NULL, &count, &handles))) {
    for (UINTN i = 0; i < count; i++) Adopt(handles[i]);
    BS->FreePool(handles);
  }

  EFI_HANDLE marker = NULL;
  BS->InstallProtocolInterface(&marker, &HangarFramebufferGuid, EFI_NATIVE_INTERFACE, NULL);
  return EFI_SUCCESS;
}
