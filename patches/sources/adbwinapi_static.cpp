/* AdbWinApi.dll loads AdbWinUsbApi.dll to get InstantiateWinUsbInterface.
 * Linked into the executable instead (builder/overlay/adbwinapi.bp), this is
 * that routine, and patch-source.sh points adb_api.cpp's hook straight at it. */

#include "stdafx.h"
// The API half's stdafx.h is the one found from here; the WinUSB half's adds this.
#include <winusb.h>
#include "adb_winusb_interface.h"

extern "C" AdbInterfaceObject* __cdecl AdbWinUsbApiInstantiateWinUsbInterface(
    const wchar_t* interface_name) {
  if (NULL == interface_name) {
    return NULL;
  }
  try {
    return new AdbWinUsbInterfaceObject(interface_name);
  } catch (...) {
    // We expect only OOM exceptions here.
    SetLastError(ERROR_OUTOFMEMORY);
    return NULL;
  }
}
