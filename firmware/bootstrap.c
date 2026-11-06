// The first program the firmware runs from Hangar's Windows install media: it loads the framebuffer driver, then
// starts the Windows boot manager, which WindowsMedia renamed from BOOTAA64.EFI to WINDOWS.EFI to make room for this.
#include "efi.h"

static EFI_GUID LoadedImageGuid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
static EFI_GUID DevicePathGuid = EFI_DEVICE_PATH_PROTOCOL_GUID;

static EFI_BOOT_SERVICES *BS;

static EFI_STATUS LoadFile(EFI_HANDLE parent, EFI_HANDLE volume, CHAR16 *file, EFI_HANDLE *image) {
  EFI_DEVICE_PATH_PROTOCOL *volumePath;
  EFI_STATUS status = BS->HandleProtocol(volume, &DevicePathGuid, (VOID **)&volumePath);
  if (EFI_ERROR(status)) return status;

  UINTN volumeBytes = 0;
  for (EFI_DEVICE_PATH_PROTOCOL *node = volumePath; node->Type != END_DEVICE_PATH_TYPE;) {
    volumeBytes += DevicePathNodeLength(node);
    node = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)volumePath + volumeBytes);
  }

  UINTN fileBytes = StringBytes(file);
  UINT16 fileNodeLength = (UINT16)(sizeof(EFI_DEVICE_PATH_PROTOCOL) + fileBytes);
  EFI_DEVICE_PATH_PROTOCOL fileNode = {MEDIA_DEVICE_PATH, MEDIA_FILEPATH_DP, {fileNodeLength & 0xff, fileNodeLength >> 8}};
  EFI_DEVICE_PATH_PROTOCOL endNode = {END_DEVICE_PATH_TYPE, END_ENTIRE_DEVICE_PATH_SUBTYPE, {sizeof(endNode), 0}};

  UINT8 *path;
  status = BS->AllocatePool(EfiBootServicesData, volumeBytes + fileNodeLength + sizeof(endNode), (VOID **)&path);
  if (EFI_ERROR(status)) return status;
  UINT8 *p = path;
  p = AppendBytes(p, volumePath, volumeBytes);
  p = AppendBytes(p, &fileNode, sizeof(fileNode));
  p = AppendBytes(p, file, fileBytes);
  AppendBytes(p, &endNode, sizeof(endNode));

  status = BS->LoadImage(FALSE, parent, (EFI_DEVICE_PATH_PROTOCOL *)path, NULL, 0, image);
  BS->FreePool(path);
  return status;
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *systemTable) {
  BS = systemTable->BootServices;

  EFI_LOADED_IMAGE_PROTOCOL *self;
  EFI_STATUS status = BS->HandleProtocol(image, &LoadedImageGuid, (VOID **)&self);
  if (EFI_ERROR(status)) return status;

  EFI_HANDLE driver;
  if (!EFI_ERROR(LoadFile(image, self->DeviceHandle, L"\\EFI\\Hangar\\hangarfb.efi", &driver))) {
    BS->StartImage(driver, NULL, NULL);
  }

  EFI_HANDLE bootManager;
  status = LoadFile(image, self->DeviceHandle, L"\\EFI\\BOOT\\WINDOWS.EFI", &bootManager);
  if (EFI_ERROR(status)) return status;
  return BS->StartImage(bootManager, NULL, NULL);
}
