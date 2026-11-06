#pragma once

typedef unsigned char UINT8;
typedef unsigned short UINT16;
typedef unsigned int UINT32;
typedef unsigned long long UINT64;
typedef long long INT64;
typedef UINT64 UINTN;
typedef UINT8 BOOLEAN;
typedef unsigned short CHAR16;
typedef void VOID;

typedef UINTN EFI_STATUS;
typedef VOID *EFI_HANDLE;
typedef VOID *EFI_EVENT;
typedef UINTN EFI_TPL;
typedef UINT64 EFI_PHYSICAL_ADDRESS;

#define TRUE 1
#define FALSE 0
#define NULL ((VOID *)0)
#define EFIAPI

#define EFI_ERROR_CODE(n) (0x8000000000000000ULL | (n))
#define EFI_ERROR(status) ((INT64)(status) < 0)
#define EFI_SUCCESS 0
#define EFI_LOAD_ERROR EFI_ERROR_CODE(1)
#define EFI_INVALID_PARAMETER EFI_ERROR_CODE(2)
#define EFI_UNSUPPORTED EFI_ERROR_CODE(3)
#define EFI_BUFFER_TOO_SMALL EFI_ERROR_CODE(5)
#define EFI_OUT_OF_RESOURCES EFI_ERROR_CODE(9)
#define EFI_NOT_FOUND EFI_ERROR_CODE(14)
#define EFI_ALREADY_STARTED EFI_ERROR_CODE(20)

typedef struct {
  UINT32 Data1;
  UINT16 Data2;
  UINT16 Data3;
  UINT8 Data4[8];
} EFI_GUID;

typedef struct {
  UINT64 Signature;
  UINT32 Revision;
  UINT32 HeaderSize;
  UINT32 CRC32;
  UINT32 Reserved;
} EFI_TABLE_HEADER;

typedef struct {
  UINT8 Type;
  UINT8 SubType;
  UINT8 Length[2];
} EFI_DEVICE_PATH_PROTOCOL;

#define MEDIA_DEVICE_PATH 0x04
#define MEDIA_FILEPATH_DP 0x04
#define END_DEVICE_PATH_TYPE 0x7f
#define END_ENTIRE_DEVICE_PATH_SUBTYPE 0xff

#define EVT_TIMER 0x80000000
#define EVT_NOTIFY_SIGNAL 0x00000200
#define TPL_CALLBACK 8

enum { AllocateAnyPages = 0 };
enum { EfiReservedMemoryType = 0, EfiBootServicesData = 4 };
enum { TimerCancel = 0, TimerPeriodic = 1 };
enum { ByRegisterNotify = 1, ByProtocol = 2 };
enum { EFI_NATIVE_INTERFACE = 0 };

typedef VOID(EFIAPI *EFI_EVENT_NOTIFY)(EFI_EVENT event, VOID *context);

typedef struct {
  EFI_TABLE_HEADER Hdr;
  VOID *RaiseTPL;
  VOID *RestoreTPL;
  EFI_STATUS(EFIAPI *AllocatePages)(UINT32 type, UINT32 memoryType, UINTN pages, EFI_PHYSICAL_ADDRESS *memory);
  EFI_STATUS(EFIAPI *FreePages)(EFI_PHYSICAL_ADDRESS memory, UINTN pages);
  VOID *GetMemoryMap;
  EFI_STATUS(EFIAPI *AllocatePool)(UINT32 poolType, UINTN size, VOID **buffer);
  EFI_STATUS(EFIAPI *FreePool)(VOID *buffer);
  EFI_STATUS(EFIAPI *CreateEvent)(UINT32 type, EFI_TPL notifyTpl, EFI_EVENT_NOTIFY notify, VOID *context, EFI_EVENT *event);
  EFI_STATUS(EFIAPI *SetTimer)(EFI_EVENT event, UINT32 type, UINT64 triggerTime);
  VOID *WaitForEvent;
  VOID *SignalEvent;
  EFI_STATUS(EFIAPI *CloseEvent)(EFI_EVENT event);
  VOID *CheckEvent;
  EFI_STATUS(EFIAPI *InstallProtocolInterface)(EFI_HANDLE *handle, EFI_GUID *protocol, UINT32 interfaceType, VOID *interface);
  VOID *ReinstallProtocolInterface;
  VOID *UninstallProtocolInterface;
  EFI_STATUS(EFIAPI *HandleProtocol)(EFI_HANDLE handle, EFI_GUID *protocol, VOID **interface);
  VOID *Reserved;
  EFI_STATUS(EFIAPI *RegisterProtocolNotify)(EFI_GUID *protocol, EFI_EVENT event, VOID **registration);
  VOID *LocateHandle;
  VOID *LocateDevicePath;
  VOID *InstallConfigurationTable;
  EFI_STATUS(EFIAPI *LoadImage)(BOOLEAN bootPolicy, EFI_HANDLE parent, EFI_DEVICE_PATH_PROTOCOL *path, VOID *source,
                                UINTN sourceSize, EFI_HANDLE *image);
  EFI_STATUS(EFIAPI *StartImage)(EFI_HANDLE image, UINTN *exitDataSize, CHAR16 **exitData);
  VOID *Exit;
  VOID *UnloadImage;
  VOID *ExitBootServices;
  VOID *GetNextMonotonicCount;
  VOID *Stall;
  VOID *SetWatchdogTimer;
  VOID *ConnectController;
  VOID *DisconnectController;
  VOID *OpenProtocol;
  VOID *CloseProtocol;
  VOID *OpenProtocolInformation;
  VOID *ProtocolsPerHandle;
  EFI_STATUS(EFIAPI *LocateHandleBuffer)(UINT32 searchType, EFI_GUID *protocol, VOID *searchKey, UINTN *count,
                                         EFI_HANDLE **buffer);
  EFI_STATUS(EFIAPI *LocateProtocol)(EFI_GUID *protocol, VOID *registration, VOID **interface);
  VOID *InstallMultipleProtocolInterfaces;
  VOID *UninstallMultipleProtocolInterfaces;
  VOID *CalculateCrc32;
  VOID *CopyMem;
  VOID *SetMem;
  EFI_STATUS(EFIAPI *CreateEventEx)(UINT32 type, EFI_TPL notifyTpl, EFI_EVENT_NOTIFY notify, const VOID *context,
                                    const EFI_GUID *group, EFI_EVENT *event);
} EFI_BOOT_SERVICES;

#define EFI_VARIABLE_NON_VOLATILE 0x1
#define EFI_VARIABLE_BOOTSERVICE_ACCESS 0x2
#define EFI_VARIABLE_RUNTIME_ACCESS 0x4
#define LOAD_OPTION_ACTIVE 0x1

typedef struct {
  EFI_TABLE_HEADER Hdr;
  VOID *GetTime;
  VOID *SetTime;
  VOID *GetWakeupTime;
  VOID *SetWakeupTime;
  VOID *SetVirtualAddressMap;
  VOID *ConvertPointer;
  EFI_STATUS(EFIAPI *GetVariable)(CHAR16 *name, EFI_GUID *vendor, UINT32 *attributes, UINTN *size, VOID *data);
  VOID *GetNextVariableName;
  EFI_STATUS(EFIAPI *SetVariable)(CHAR16 *name, EFI_GUID *vendor, UINT32 attributes, UINTN size, VOID *data);
} EFI_RUNTIME_SERVICES;

typedef struct {
  EFI_TABLE_HEADER Hdr;
  CHAR16 *FirmwareVendor;
  UINT32 FirmwareRevision;
  EFI_HANDLE ConsoleInHandle;
  VOID *ConIn;
  EFI_HANDLE ConsoleOutHandle;
  VOID *ConOut;
  EFI_HANDLE StandardErrorHandle;
  VOID *StdErr;
  EFI_RUNTIME_SERVICES *RuntimeServices;
  EFI_BOOT_SERVICES *BootServices;
  UINTN NumberOfTableEntries;
  VOID *ConfigurationTable;
} EFI_SYSTEM_TABLE;

typedef struct {
  UINT32 Revision;
  EFI_HANDLE ParentHandle;
  EFI_SYSTEM_TABLE *SystemTable;
  EFI_HANDLE DeviceHandle;
  EFI_DEVICE_PATH_PROTOCOL *FilePath;
  VOID *Reserved;
  UINT32 LoadOptionsSize;
  VOID *LoadOptions;
  VOID *ImageBase;
  UINT64 ImageSize;
  UINT32 ImageCodeType;
  UINT32 ImageDataType;
  VOID *Unload;
} EFI_LOADED_IMAGE_PROTOCOL;

enum {
  PixelRedGreenBlueReserved8BitPerColor = 0,
  PixelBlueGreenRedReserved8BitPerColor = 1,
  PixelBitMask = 2,
  PixelBltOnly = 3,
};

enum { EfiBltVideoFill = 0, EfiBltVideoToBltBuffer = 1, EfiBltBufferToVideo = 2, EfiBltVideoToVideo = 3 };

typedef struct {
  UINT32 RedMask;
  UINT32 GreenMask;
  UINT32 BlueMask;
  UINT32 ReservedMask;
} EFI_PIXEL_BITMASK;

typedef struct {
  UINT32 Version;
  UINT32 HorizontalResolution;
  UINT32 VerticalResolution;
  UINT32 PixelFormat;
  EFI_PIXEL_BITMASK PixelInformation;
  UINT32 PixelsPerScanLine;
} EFI_GRAPHICS_OUTPUT_MODE_INFORMATION;

typedef struct {
  UINT32 MaxMode;
  UINT32 Mode;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;
  UINTN SizeOfInfo;
  EFI_PHYSICAL_ADDRESS FrameBufferBase;
  UINTN FrameBufferSize;
} EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE;

typedef struct {
  UINT8 Blue;
  UINT8 Green;
  UINT8 Red;
  UINT8 Reserved;
} EFI_GRAPHICS_OUTPUT_BLT_PIXEL;

typedef struct EFI_GRAPHICS_OUTPUT_PROTOCOL EFI_GRAPHICS_OUTPUT_PROTOCOL;

typedef EFI_STATUS(EFIAPI *EFI_GOP_QUERY_MODE)(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop, UINT32 mode, UINTN *size,
                                                EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **info);
typedef EFI_STATUS(EFIAPI *EFI_GOP_SET_MODE)(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop, UINT32 mode);
typedef EFI_STATUS(EFIAPI *EFI_GOP_BLT)(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop, EFI_GRAPHICS_OUTPUT_BLT_PIXEL *buffer,
                                         UINT32 operation, UINTN sourceX, UINTN sourceY, UINTN destinationX,
                                         UINTN destinationY, UINTN width, UINTN height, UINTN delta);

struct EFI_GRAPHICS_OUTPUT_PROTOCOL {
  EFI_GOP_QUERY_MODE QueryMode;
  EFI_GOP_SET_MODE SetMode;
  EFI_GOP_BLT Blt;
  EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode;
};

#define EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID {0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}}
#define EFI_DEVICE_PATH_PROTOCOL_GUID {0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
#define EFI_LOADED_IMAGE_PROTOCOL_GUID {0x5b1b31a1, 0x9562, 0x11d2, {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
#define EFI_GLOBAL_VARIABLE_GUID {0x8be4df61, 0x93ca, 0x11d2, {0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c}}
#define EFI_EVENT_GROUP_EXIT_BOOT_SERVICES {0x27abf055, 0xb1b8, 0x4c26, {0x80, 0x48, 0x74, 0x8f, 0x37, 0xba, 0xa2, 0xdf}}

static inline VOID *CopyBytes(VOID *to, const VOID *from, UINTN count) {
  UINT8 *t = to;
  const UINT8 *f = from;
  while (count--) *t++ = *f++;
  return to;
}

static inline UINT8 *AppendBytes(UINT8 *to, const VOID *from, UINTN count) {
  CopyBytes(to, from, count);
  return to + count;
}

// clang emits calls to memcpy and memset for struct copies and array zeroing even when freestanding.
VOID *memcpy(VOID *to, const VOID *from, UINTN count) { return CopyBytes(to, from, count); }

VOID *memset(VOID *to, int value, UINTN count) {
  UINT8 *t = to;
  while (count--) *t++ = (UINT8)value;
  return to;
}

static inline UINTN DevicePathNodeLength(const EFI_DEVICE_PATH_PROTOCOL *node) {
  return node->Length[0] | ((UINTN)node->Length[1] << 8);
}

static inline UINTN StringBytes(const CHAR16 *string) {
  UINTN length = 0;
  while (string[length]) length++;
  return (length + 1) * sizeof(CHAR16);
}
