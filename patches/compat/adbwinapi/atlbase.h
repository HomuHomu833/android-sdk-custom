/* The ATL that AdbWinApi and AdbWinUsbApi use, for mingw (which has none).
 * Their CAtlDllModuleT DLL glue is replaced instead: builder/overlay/
 * adbwinapi.bp links them into adb and fastboot rather than building DLLs. */
#pragma once

#include <windows.h>

// ATL's debug-only assertion; release builds compile it out, as here.
#ifndef ATLASSERT
#define ATLASSERT(expr) ((void)0)
#endif

namespace ATL {

class CComAutoCriticalSection {
 public:
  CComAutoCriticalSection() { InitializeCriticalSection(&cs_); }
  ~CComAutoCriticalSection() { DeleteCriticalSection(&cs_); }
  CComAutoCriticalSection(const CComAutoCriticalSection&) = delete;
  CComAutoCriticalSection& operator=(const CComAutoCriticalSection&) = delete;

  HRESULT Lock() {
    EnterCriticalSection(&cs_);
    return S_OK;
  }
  HRESULT Unlock() {
    LeaveCriticalSection(&cs_);
    return S_OK;
  }

 private:
  CRITICAL_SECTION cs_;
};

}  // namespace ATL
