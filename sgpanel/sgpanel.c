// SGPanelHost: hosts the ShellGate control panel (an HTA page) in our own
// window, replacing mshta.exe so the taskbar/title icon is this exe's icon.
// The page runs with HTA-equivalent trust via a custom IInternetSecurityManager
// served from the OLE client site, and Local Machine Zone Lockdown disabled
// for this process. The panel file is loaded under a .html name (navigating
// the WebBrowser control to a .hta would hand off to mshta / download).
//
// Usage: SGPanelHost.exe [path-to-panel.html]  (default: ShellGate.html
// next to this exe)

#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <ole2.h>
#include <shellapi.h>
#include <exdisp.h>
#ifndef DISPID_ONQUIT
#define DISPID_ONQUIT 253
#endif
#ifndef DISPID_DOCUMENTCOMPLETE
#define DISPID_DOCUMENTCOMPLETE 259
#endif
#include <mshtmhst.h>
#include <mshtml.h>
#include <urlmon.h>
#include <shlwapi.h>
#include <stdio.h>

static HWND g_hwnd = NULL;
static IWebBrowser2 *g_browser = NULL;
static IOleInPlaceActiveObject *g_activeObj = NULL;
static DWORD g_sinkCookie = 0;

/* ------------------------------------------------------------------ */
/* IInternetSecurityManager: allow everything (HTA-equivalent trust)  */
/* ------------------------------------------------------------------ */
typedef struct {
    IInternetSecurityManager mgr;
    LONG ref;
} SecMgr;

static HRESULT STDMETHODCALLTYPE Sec_QueryInterface(IInternetSecurityManager *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IInternetSecurityManager)) {
        *ppv = This;
        IInternetSecurityManager_AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE Sec_AddRef(IInternetSecurityManager *This) {
    return (ULONG)InterlockedIncrement(&((SecMgr *)This)->ref);
}
static ULONG STDMETHODCALLTYPE Sec_Release(IInternetSecurityManager *This) {
    LONG r = InterlockedDecrement(&((SecMgr *)This)->ref);
    if (r == 0) free(This);
    return (ULONG)r;
}
static HRESULT STDMETHODCALLTYPE Sec_SetSecuritySite(IInternetSecurityManager *This, IInternetSecurityMgrSite *pSite) {
    (void)This; (void)pSite;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Sec_GetSecuritySite(IInternetSecurityManager *This, IInternetSecurityMgrSite **ppSite) {
    (void)This;
    *ppSite = NULL;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE Sec_MapUrlToZone(IInternetSecurityManager *This, LPCWSTR pwszUrl, DWORD *pdwZone, DWORD dwFlags) {
    (void)This; (void)pwszUrl; (void)dwFlags;
    *pdwZone = URLZONE_LOCAL_MACHINE;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Sec_GetSecurityId(IInternetSecurityManager *This, LPCWSTR pwszUrl, BYTE *pbSecurityId, DWORD *pcbSecurityId, ULONG_PTR dwReserved) {
    (void)This; (void)pwszUrl; (void)pbSecurityId; (void)pcbSecurityId; (void)dwReserved;
    return INET_E_DEFAULT_ACTION;
}
static HRESULT STDMETHODCALLTYPE Sec_ProcessUrlAction(IInternetSecurityManager *This, LPCWSTR pwszUrl, DWORD dwAction, BYTE *pPolicy, DWORD cbPolicy, BYTE *pContext, DWORD cbContext, DWORD dwFlags, DWORD dwReserved) {
    (void)This; (void)pwszUrl; (void)dwAction; (void)pContext; (void)cbContext; (void)dwFlags; (void)dwReserved;
    if (cbPolicy >= sizeof(DWORD))
        *(DWORD *)pPolicy = URLPOLICY_ALLOW;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Sec_QueryCustomPolicy(IInternetSecurityManager *This, LPCWSTR pwszUrl, REFGUID guidKey, BYTE **ppPolicy, DWORD *pcbPolicy, BYTE *pContext, DWORD cbContext, DWORD dwReserved) {
    (void)This; (void)pwszUrl; (void)guidKey; (void)pContext; (void)cbContext; (void)dwReserved;
    *ppPolicy = NULL;
    *pcbPolicy = 0;
    return INET_E_DEFAULT_ACTION;
}
static HRESULT STDMETHODCALLTYPE Sec_SetZoneMapping(IInternetSecurityManager *This, DWORD dwZone, LPCWSTR lpszPattern, DWORD dwFlags) {
    (void)This; (void)dwZone; (void)lpszPattern; (void)dwFlags;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE Sec_GetZoneMappings(IInternetSecurityManager *This, DWORD dwZone, IEnumString **ppEnumString, DWORD dwFlags) {
    (void)This; (void)dwZone; (void)dwFlags;
    *ppEnumString = NULL;
    return E_NOTIMPL;
}

static IInternetSecurityManagerVtbl g_secVtbl = {
    Sec_QueryInterface, Sec_AddRef, Sec_Release,
    Sec_SetSecuritySite, Sec_GetSecuritySite, Sec_MapUrlToZone,
    Sec_GetSecurityId, Sec_ProcessUrlAction, Sec_QueryCustomPolicy,
    Sec_SetZoneMapping, Sec_GetZoneMappings
};

static IInternetSecurityManager *SecMgr_Create(void) {
    SecMgr *m = (SecMgr *)malloc(sizeof(SecMgr));
    if (!m) return NULL;
    m->mgr.lpVtbl = &g_secVtbl;
    m->ref = 1;
    return &m->mgr;
}

/* ------------------------------------------------------------------ */
/* IOleInPlaceFrame (minimal)                                          */
/* ------------------------------------------------------------------ */
typedef struct Site Site;
typedef struct {
    IOleInPlaceFrame frame;
    Site *site;
} FrameObj;

static HRESULT STDMETHODCALLTYPE Frame_QueryInterface(IOleInPlaceFrame *This, REFIID riid, void **ppv);
static ULONG STDMETHODCALLTYPE Frame_AddRef(IOleInPlaceFrame *This);
static ULONG STDMETHODCALLTYPE Frame_Release(IOleInPlaceFrame *This);
static HRESULT STDMETHODCALLTYPE Frame_GetWindow(IOleInPlaceFrame *This, HWND *phwnd);
static HRESULT STDMETHODCALLTYPE Frame_ContextSensitiveHelp(IOleInPlaceFrame *This, BOOL fEnterMode);
static HRESULT STDMETHODCALLTYPE Frame_GetBorder(IOleInPlaceFrame *This, LPRECT lprectBorder);
static HRESULT STDMETHODCALLTYPE Frame_RequestBorderSpace(IOleInPlaceFrame *This, LPCBORDERWIDTHS pborderwidths);
static HRESULT STDMETHODCALLTYPE Frame_SetBorderSpace(IOleInPlaceFrame *This, LPCBORDERWIDTHS pborderwidths);
static HRESULT STDMETHODCALLTYPE Frame_SetActiveObject(IOleInPlaceFrame *This, IOleInPlaceActiveObject *pActiveObject, LPCOLESTR pszObjName);
static HRESULT STDMETHODCALLTYPE Frame_InsertMenus(IOleInPlaceFrame *This, HMENU hmenuShared, LPOLEMENUGROUPWIDTHS lpMenuWidths);
static HRESULT STDMETHODCALLTYPE Frame_SetMenu(IOleInPlaceFrame *This, HMENU hmenuShared, HOLEMENU holemenu, HWND hwndActiveObject);
static HRESULT STDMETHODCALLTYPE Frame_RemoveMenus(IOleInPlaceFrame *This, HMENU hmenuShared);
static HRESULT STDMETHODCALLTYPE Frame_SetStatusText(IOleInPlaceFrame *This, LPCOLESTR pszStatusText);
static HRESULT STDMETHODCALLTYPE Frame_EnableModeless(IOleInPlaceFrame *This, BOOL fEnable);
static HRESULT STDMETHODCALLTYPE Frame_TranslateAccelerator(IOleInPlaceFrame *This, LPMSG lpmsg, WORD wID);

static IOleInPlaceFrameVtbl g_frameVtbl = {
    Frame_QueryInterface, Frame_AddRef, Frame_Release,
    Frame_GetWindow, Frame_ContextSensitiveHelp,
    Frame_GetBorder, Frame_RequestBorderSpace, Frame_SetBorderSpace,
    Frame_SetActiveObject,
    Frame_InsertMenus, Frame_SetMenu, Frame_RemoveMenus,
    Frame_SetStatusText, Frame_EnableModeless, Frame_TranslateAccelerator
};

/* ------------------------------------------------------------------ */
/* Client site: IOleClientSite + IOleInPlaceSite + IDocHostUIHandler  */
/*              + IServiceProvider                                     */
/* ------------------------------------------------------------------ */
struct Site {
    IOleClientSite clientSite;
    IOleInPlaceSite inPlaceSite;
    IDocHostUIHandler uiHandler;
    IServiceProvider svcProvider;
    LONG ref;
    HWND hwnd;
    FrameObj frameObj;
    IInternetSecurityManager *secMgr;
};

static Site *Site_FromClient(IOleClientSite *p) { return (Site *)p; }
static Site *Site_FromInPlace(IOleInPlaceSite *p) {
    return (Site *)((char *)p - offsetof(Site, inPlaceSite));
}
static Site *Site_FromUI(IDocHostUIHandler *p) {
    return (Site *)((char *)p - offsetof(Site, uiHandler));
}
static Site *Site_FromSvc(IServiceProvider *p) {
    return (Site *)((char *)p - offsetof(Site, svcProvider));
}

static HRESULT Site_QI(Site *s, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IOleClientSite)) {
        *ppv = &s->clientSite;
    } else if (IsEqualIID(riid, &IID_IOleInPlaceSite) || IsEqualIID(riid, &IID_IOleWindow)) {
        *ppv = &s->inPlaceSite;
    } else if (IsEqualIID(riid, &IID_IDocHostUIHandler)) {
        *ppv = &s->uiHandler;
    } else if (IsEqualIID(riid, &IID_IServiceProvider)) {
        *ppv = &s->svcProvider;
    } else {
        *ppv = NULL;
        return E_NOINTERFACE;
    }
    InterlockedIncrement(&s->ref);
    return S_OK;
}
static ULONG Site_AddRef(Site *s) { return (ULONG)InterlockedIncrement(&s->ref); }
static ULONG Site_Release(Site *s) {
    LONG r = InterlockedDecrement(&s->ref);
    if (r == 0) {
        if (s->secMgr) IInternetSecurityManager_Release(s->secMgr);
        free(s);
    }
    return (ULONG)r;
}

/* --- IOleClientSite --- */
static HRESULT STDMETHODCALLTYPE CS_QueryInterface(IOleClientSite *This, REFIID riid, void **ppv) {
    return Site_QI(Site_FromClient(This), riid, ppv);
}
static ULONG STDMETHODCALLTYPE CS_AddRef(IOleClientSite *This) { return Site_AddRef(Site_FromClient(This)); }
static ULONG STDMETHODCALLTYPE CS_Release(IOleClientSite *This) { return Site_Release(Site_FromClient(This)); }
static HRESULT STDMETHODCALLTYPE CS_SaveObject(IOleClientSite *This) { (void)This; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE CS_GetMoniker(IOleClientSite *This, DWORD dwAssign, DWORD dwWhichMoniker, IMoniker **ppmk) {
    (void)This; (void)dwAssign; (void)dwWhichMoniker;
    *ppmk = NULL;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE CS_GetContainer(IOleClientSite *This, IOleContainer **ppContainer) {
    (void)This;
    *ppContainer = NULL;
    return E_NOINTERFACE;
}
static HRESULT STDMETHODCALLTYPE CS_ShowObject(IOleClientSite *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE CS_OnShowWindow(IOleClientSite *This, BOOL fShow) { (void)This; (void)fShow; return S_OK; }
static HRESULT STDMETHODCALLTYPE CS_RequestNewObjectLayout(IOleClientSite *This) { (void)This; return E_NOTIMPL; }

static IOleClientSiteVtbl g_clientVtbl = {
    CS_QueryInterface, CS_AddRef, CS_Release,
    CS_SaveObject, CS_GetMoniker, CS_GetContainer,
    CS_ShowObject, CS_OnShowWindow, CS_RequestNewObjectLayout
};

/* --- IOleInPlaceSite --- */
static HRESULT STDMETHODCALLTYPE IP_QueryInterface(IOleInPlaceSite *This, REFIID riid, void **ppv) {
    return Site_QI(Site_FromInPlace(This), riid, ppv);
}
static ULONG STDMETHODCALLTYPE IP_AddRef(IOleInPlaceSite *This) { return Site_AddRef(Site_FromInPlace(This)); }
static ULONG STDMETHODCALLTYPE IP_Release(IOleInPlaceSite *This) { return Site_Release(Site_FromInPlace(This)); }
static HRESULT STDMETHODCALLTYPE IP_GetWindow(IOleInPlaceSite *This, HWND *phwnd) {
    *phwnd = Site_FromInPlace(This)->hwnd;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE IP_ContextSensitiveHelp(IOleInPlaceSite *This, BOOL fEnterMode) {
    (void)This; (void)fEnterMode;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE IP_CanInPlaceActivate(IOleInPlaceSite *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE IP_OnInPlaceActivate(IOleInPlaceSite *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE IP_OnUIActivate(IOleInPlaceSite *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE IP_GetWindowContext(IOleInPlaceSite *This, IOleInPlaceFrame **ppFrame, IOleInPlaceUIWindow **ppDoc, LPRECT lprcPosRect, LPRECT lprcClipRect, LPOLEINPLACEFRAMEINFO lpFrameInfo) {
    Site *s = Site_FromInPlace(This);
    *ppFrame = &s->frameObj.frame;
    IOleInPlaceFrame_AddRef(*ppFrame);
    *ppDoc = NULL;
    GetClientRect(s->hwnd, lprcPosRect);
    *lprcClipRect = *lprcPosRect;
    lpFrameInfo->cb = sizeof(OLEINPLACEFRAMEINFO); /* mingw names the field cb (MS: cbStruct) */
    lpFrameInfo->fMDIApp = FALSE;
    lpFrameInfo->hwndFrame = s->hwnd;
    lpFrameInfo->haccel = NULL;
    lpFrameInfo->cAccelEntries = 0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE IP_Scroll(IOleInPlaceSite *This, SIZE scrollExtant) {
    (void)This; (void)scrollExtant;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE IP_OnUIDeactivate(IOleInPlaceSite *This, BOOL fUndoable) {
    (void)This; (void)fUndoable;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE IP_OnInPlaceDeactivate(IOleInPlaceSite *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE IP_DiscardUndoState(IOleInPlaceSite *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE IP_DeactivateAndUndo(IOleInPlaceSite *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE IP_OnPosRectChange(IOleInPlaceSite *This, LPCRECT lprcPosRect) {
    (void)This; (void)lprcPosRect;
    return S_OK;
}

static IOleInPlaceSiteVtbl g_inPlaceVtbl = {
    IP_QueryInterface, IP_AddRef, IP_Release,
    IP_GetWindow, IP_ContextSensitiveHelp,
    IP_CanInPlaceActivate, IP_OnInPlaceActivate, IP_OnUIActivate,
    IP_GetWindowContext, IP_Scroll, IP_OnUIDeactivate,
    IP_OnInPlaceDeactivate, IP_DiscardUndoState, IP_DeactivateAndUndo,
    IP_OnPosRectChange
};

/* --- IOleInPlaceFrame impls --- */
static HRESULT STDMETHODCALLTYPE Frame_QueryInterface(IOleInPlaceFrame *This, REFIID riid, void **ppv) {
    FrameObj *f = (FrameObj *)This;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IOleInPlaceFrame) ||
        IsEqualIID(riid, &IID_IOleInPlaceUIWindow) || IsEqualIID(riid, &IID_IOleWindow)) {
        *ppv = This;
        Frame_AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE Frame_AddRef(IOleInPlaceFrame *This) {
    return Site_AddRef(((FrameObj *)This)->site);
}
static ULONG STDMETHODCALLTYPE Frame_Release(IOleInPlaceFrame *This) {
    return Site_Release(((FrameObj *)This)->site);
}
static HRESULT STDMETHODCALLTYPE Frame_GetWindow(IOleInPlaceFrame *This, HWND *phwnd) {
    *phwnd = ((FrameObj *)This)->site->hwnd;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_ContextSensitiveHelp(IOleInPlaceFrame *This, BOOL fEnterMode) {
    (void)This; (void)fEnterMode;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE Frame_GetBorder(IOleInPlaceFrame *This, LPRECT lprectBorder) {
    GetClientRect(((FrameObj *)This)->site->hwnd, lprectBorder);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_RequestBorderSpace(IOleInPlaceFrame *This, LPCBORDERWIDTHS pborderwidths) {
    (void)This; (void)pborderwidths;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_SetBorderSpace(IOleInPlaceFrame *This, LPCBORDERWIDTHS pborderwidths) {
    (void)This; (void)pborderwidths;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_SetActiveObject(IOleInPlaceFrame *This, IOleInPlaceActiveObject *pActiveObject, LPCOLESTR pszObjName) {
    (void)This; (void)pszObjName;
    if (g_activeObj) { IOleInPlaceActiveObject_Release(g_activeObj); g_activeObj = NULL; }
    if (pActiveObject) {
        g_activeObj = pActiveObject;
        IOleInPlaceActiveObject_AddRef(g_activeObj);
    }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_InsertMenus(IOleInPlaceFrame *This, HMENU hmenuShared, LPOLEMENUGROUPWIDTHS lpMenuWidths) {
    (void)This; (void)hmenuShared;
    if (lpMenuWidths) {
        int i;
        for (i = 0; i < 6; i++) lpMenuWidths->width[i] = 0;
    }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_SetMenu(IOleInPlaceFrame *This, HMENU hmenuShared, HOLEMENU holemenu, HWND hwndActiveObject) {
    (void)This; (void)hmenuShared; (void)holemenu; (void)hwndActiveObject;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_RemoveMenus(IOleInPlaceFrame *This, HMENU hmenuShared) {
    (void)This; (void)hmenuShared;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_SetStatusText(IOleInPlaceFrame *This, LPCOLESTR pszStatusText) {
    (void)This; (void)pszStatusText;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_EnableModeless(IOleInPlaceFrame *This, BOOL fEnable) {
    (void)This; (void)fEnable;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Frame_TranslateAccelerator(IOleInPlaceFrame *This, LPMSG lpmsg, WORD wID) {
    (void)This; (void)lpmsg; (void)wID;
    return S_FALSE;
}

/* --- IDocHostUIHandler --- */
static HRESULT STDMETHODCALLTYPE UI_QueryInterface(IDocHostUIHandler *This, REFIID riid, void **ppv) {
    return Site_QI(Site_FromUI(This), riid, ppv);
}
static ULONG STDMETHODCALLTYPE UI_AddRef(IDocHostUIHandler *This) { return Site_AddRef(Site_FromUI(This)); }
static ULONG STDMETHODCALLTYPE UI_Release(IDocHostUIHandler *This) { return Site_Release(Site_FromUI(This)); }
static HRESULT STDMETHODCALLTYPE UI_ShowContextMenu(IDocHostUIHandler *This, DWORD dwID, POINT *ppt, IUnknown *pcmdtReserved, IDispatch *pdispReserved) {
    (void)This; (void)dwID; (void)ppt; (void)pcmdtReserved; (void)pdispReserved;
    return S_OK; /* suppress the IE context menu */
}
static HRESULT STDMETHODCALLTYPE UI_GetHostInfo(IDocHostUIHandler *This, DOCHOSTUIINFO *pInfo) {
    (void)This;
    if (pInfo) {
        pInfo->cbSize = sizeof(DOCHOSTUIINFO);
        pInfo->dwFlags = DOCHOSTUIFLAG_NO3DBORDER | DOCHOSTUIFLAG_SCROLL_NO |
                         DOCHOSTUIFLAG_THEME | DOCHOSTUIFLAG_DISABLE_HELP_MENU |
                         DOCHOSTUIFLAG_DIALOG;
        pInfo->dwDoubleClick = DOCHOSTUIDBLCLK_DEFAULT;
        pInfo->pchHostCss = NULL;
        pInfo->pchHostNS = NULL;
    }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE UI_ShowUI(IDocHostUIHandler *This, DWORD dwID, IOleInPlaceActiveObject *pActiveObject, IOleCommandTarget *pCommandTarget, IOleInPlaceFrame *pFrame, IOleInPlaceUIWindow *pDoc) {
    (void)This; (void)dwID; (void)pActiveObject; (void)pCommandTarget; (void)pFrame; (void)pDoc;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE UI_HideUI(IDocHostUIHandler *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE UI_UpdateUI(IDocHostUIHandler *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE UI_EnableModeless(IDocHostUIHandler *This, BOOL fEnable) {
    (void)This; (void)fEnable;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE UI_OnDocWindowActivate(IDocHostUIHandler *This, BOOL fActivate) {
    (void)This; (void)fActivate;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE UI_OnFrameWindowActivate(IDocHostUIHandler *This, BOOL fActivate) {
    (void)This; (void)fActivate;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE UI_ResizeBorder(IDocHostUIHandler *This, LPCRECT prcBorder, IOleInPlaceUIWindow *pUIWindow, BOOL fRameWindow) {
    (void)This; (void)prcBorder; (void)pUIWindow; (void)fRameWindow;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE UI_TranslateAccelerator(IDocHostUIHandler *This, LPMSG lpMsg, const GUID *pguidCmdGroup, DWORD nCmdID) {
    (void)This; (void)lpMsg; (void)pguidCmdGroup; (void)nCmdID;
    return S_FALSE;
}
static HRESULT STDMETHODCALLTYPE UI_GetOptionKeyPath(IDocHostUIHandler *This, LPOLESTR *pchKey, DWORD dw) {
    (void)This; (void)dw;
    if (pchKey) *pchKey = NULL;
    return S_FALSE;
}
static HRESULT STDMETHODCALLTYPE UI_GetDropTarget(IDocHostUIHandler *This, IDropTarget *pDropTarget, IDropTarget **ppDropTarget) {
    (void)This; (void)pDropTarget;
    *ppDropTarget = NULL;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE UI_GetExternal(IDocHostUIHandler *This, IDispatch **ppDispatch) {
    (void)This;
    *ppDispatch = NULL;
    return S_FALSE;
}
static HRESULT STDMETHODCALLTYPE UI_TranslateUrl(IDocHostUIHandler *This, DWORD dwTranslate, OLECHAR *pchURLIn, OLECHAR **ppchURLOut) {
    (void)This; (void)dwTranslate; (void)pchURLIn;
    *ppchURLOut = NULL;
    return S_FALSE;
}
static HRESULT STDMETHODCALLTYPE UI_FilterDataObject(IDocHostUIHandler *This, IDataObject *pDO, IDataObject **ppDORet) {
    (void)This; (void)pDO;
    *ppDORet = NULL;
    return S_FALSE;
}

static IDocHostUIHandlerVtbl g_uiVtbl = {
    UI_QueryInterface, UI_AddRef, UI_Release,
    UI_ShowContextMenu, UI_GetHostInfo, UI_ShowUI, UI_HideUI, UI_UpdateUI,
    UI_EnableModeless, UI_OnDocWindowActivate, UI_OnFrameWindowActivate,
    UI_ResizeBorder, UI_TranslateAccelerator, UI_GetOptionKeyPath,
    UI_GetDropTarget, UI_GetExternal, UI_TranslateUrl, UI_FilterDataObject
};

/* --- IServiceProvider --- */
static HRESULT STDMETHODCALLTYPE SP_QueryInterface(IServiceProvider *This, REFIID riid, void **ppv) {
    return Site_QI(Site_FromSvc(This), riid, ppv);
}
static ULONG STDMETHODCALLTYPE SP_AddRef(IServiceProvider *This) { return Site_AddRef(Site_FromSvc(This)); }
static ULONG STDMETHODCALLTYPE SP_Release(IServiceProvider *This) { return Site_Release(Site_FromSvc(This)); }
static HRESULT STDMETHODCALLTYPE SP_QueryService(IServiceProvider *This, REFGUID guidService, REFIID riid, void **ppvObject) {
    Site *s = Site_FromSvc(This);
    if (IsEqualGUID(guidService, &SID_SInternetSecurityManager) ||
        IsEqualIID(riid, &IID_IInternetSecurityManager)) {
        return IInternetSecurityManager_QueryInterface(s->secMgr, riid, ppvObject);
    }
    *ppvObject = NULL;
    return E_NOINTERFACE;
}

static IServiceProviderVtbl g_svcVtbl = {
    SP_QueryInterface, SP_AddRef, SP_Release, SP_QueryService
};

static Site *Site_Create(HWND hwnd) {
    Site *s = (Site *)calloc(1, sizeof(Site));
    if (!s) return NULL;
    s->clientSite.lpVtbl = &g_clientVtbl;
    s->inPlaceSite.lpVtbl = &g_inPlaceVtbl;
    s->uiHandler.lpVtbl = &g_uiVtbl;
    s->svcProvider.lpVtbl = &g_svcVtbl;
    s->frameObj.frame.lpVtbl = &g_frameVtbl;
    s->frameObj.site = s;
    s->ref = 1;
    s->hwnd = hwnd;
    s->secMgr = SecMgr_Create();
    return s;
}

/* ------------------------------------------------------------------ */
/* DWebBrowserEvents2 sink: window.close() -> OnQuit -> close window  */
/* ------------------------------------------------------------------ */
typedef struct {
    IDispatch disp;
    LONG ref;
    HWND hwnd;
} Sink;

static HRESULT STDMETHODCALLTYPE Sink_QueryInterface(IDispatch *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IDispatch) ||
        IsEqualIID(riid, &DIID_DWebBrowserEvents2)) {
        *ppv = This;
        IDispatch_AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE Sink_AddRef(IDispatch *This) {
    return (ULONG)InterlockedIncrement(&((Sink *)This)->ref);
}
static ULONG STDMETHODCALLTYPE Sink_Release(IDispatch *This) {
    LONG r = InterlockedDecrement(&((Sink *)This)->ref);
    if (r == 0) free(This);
    return (ULONG)r;
}
static HRESULT STDMETHODCALLTYPE Sink_GetTypeInfoCount(IDispatch *This, UINT *pctinfo) {
    (void)This;
    *pctinfo = 0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE Sink_GetTypeInfo(IDispatch *This, UINT iTInfo, LCID lcid, ITypeInfo **ppTInfo) {
    (void)This; (void)iTInfo; (void)lcid;
    *ppTInfo = NULL;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE Sink_GetIDsOfNames(IDispatch *This, REFIID riid, LPOLESTR *rgszNames, UINT cNames, LCID lcid, DISPID *rgDispId) {
    (void)This; (void)riid; (void)rgszNames; (void)cNames; (void)lcid; (void)rgDispId;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE Sink_Invoke(IDispatch *This, DISPID dispIdMember, REFIID riid, LCID lcid, WORD wFlags, DISPPARAMS *pDispParams, VARIANT *pVarResult, EXCEPINFO *pExcepInfo, UINT *puArgErr) {
    Sink *sk = (Sink *)This;
    (void)riid; (void)lcid; (void)wFlags; (void)pDispParams; (void)pVarResult; (void)pExcepInfo; (void)puArgErr;
    if (dispIdMember == DISPID_ONQUIT || dispIdMember == 263 /* WindowClosing */) {
        PostMessageW(sk->hwnd, WM_CLOSE, 0, 0);
    } else if (dispIdMember == DISPID_DOCUMENTCOMPLETE) {
        /* adopt the page title as the window title */
        if (g_browser) {
            IDispatch *doc = NULL;
            if (SUCCEEDED(IWebBrowser2_get_Document(g_browser, &doc)) && doc) {
                IHTMLDocument2 *d2 = NULL;
                if (SUCCEEDED(IDispatch_QueryInterface(doc, &IID_IHTMLDocument2, (void **)&d2)) && d2) {
                    BSTR t = NULL;
                    if (SUCCEEDED(IHTMLDocument2_get_title(d2, &t)) && t) {
                        if (SysStringLen(t) > 0) SetWindowTextW(sk->hwnd, t);
                        SysFreeString(t);
                    }
                    IHTMLDocument2_Release(d2);
                }
                IDispatch_Release(doc);
            }
        }
    }
    return S_OK;
}

static IDispatchVtbl g_sinkVtbl = {
    Sink_QueryInterface, Sink_AddRef, Sink_Release,
    Sink_GetTypeInfoCount, Sink_GetTypeInfo, Sink_GetIDsOfNames, Sink_Invoke
};

static Sink *Sink_Create(HWND hwnd) {
    Sink *sk = (Sink *)malloc(sizeof(Sink));
    if (!sk) return NULL;
    sk->disp.lpVtbl = &g_sinkVtbl;
    sk->ref = 1;
    sk->hwnd = hwnd;
    return sk;
}

/* ------------------------------------------------------------------ */
/* Window                                                              */
/* ------------------------------------------------------------------ */
static Site *g_site = NULL;
static Sink *g_sink = NULL;
static IOleObject *g_oleObj = NULL;

static void ResizeBrowser(void) {
    if (g_oleObj && g_hwnd) {
        IOleInPlaceObject *ipo = NULL;
        if (SUCCEEDED(IOleObject_QueryInterface(g_oleObj, &IID_IOleInPlaceObject, (void **)&ipo)) && ipo) {
            RECT rc;
            GetClientRect(g_hwnd, &rc);
            IOleInPlaceObject_SetObjectRects(ipo, &rc, &rc);
            IOleInPlaceObject_Release(ipo);
        }
    }
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_SIZE:
        ResizeBrowser();
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmd, int nShow) {
    (void)hPrev; (void)lpCmd;

    /* Single instance: activate the existing window instead. */
    HANDLE hMutex = CreateMutexW(NULL, TRUE, L"SGPanelHost.SingleInstance");
    if (hMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND existing = FindWindowW(L"SGPanelWndClass", NULL);
        if (existing) {
            ShowWindow(existing, SW_RESTORE);
            SetForegroundWindow(existing);
        }
        return 0;
    }

    /* Panel path: argv[1] or ShellGate.html next to this exe. */
    WCHAR panelPath[MAX_PATH];
    panelPath[0] = 0;
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv && argc > 1 && argv[1][0]) {
        wcsncpy(panelPath, argv[1], MAX_PATH - 1);
        panelPath[MAX_PATH - 1] = 0;
    } else {
        WCHAR exePath[MAX_PATH];
        GetModuleFileNameW(NULL, exePath, MAX_PATH);
        WCHAR *slash = wcsrchr(exePath, L'\\');
        if (slash) *(slash + 1) = 0;
        wcsncpy(panelPath, exePath, MAX_PATH - 1);
        panelPath[MAX_PATH - 1] = 0;
        wcsncat(panelPath, L"ShellGate.html", MAX_PATH - wcslen(panelPath) - 1);
    }
    if (argv) LocalFree(argv);

    HRESULT hr = OleInitialize(NULL);
    if (FAILED(hr)) return 1;

    /* HTA-equivalent trust for local content in this process. */
    CoInternetSetFeatureEnabled(FEATURE_LOCALMACHINE_LOCKDOWN, SET_FEATURE_ON_PROCESS, FALSE);
    CoInternetSetFeatureEnabled(FEATURE_ZONE_ELEVATION, SET_FEATURE_ON_PROCESS, FALSE);

    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hIcon = LoadIconW(hInst, MAKEINTRESOURCEW(1));
    wc.hIconSm = LoadIconW(hInst, MAKEINTRESOURCEW(1));
    wc.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); /* IDC_ARROW */
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"SGPanelWndClass";
    RegisterClassExW(&wc);

    /* 620x800 client area, centered. */
    RECT want = { 0, 0, 620, 800 };
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    AdjustWindowRectEx(&want, style, FALSE, 0);
    int w = want.right - want.left, h = want.bottom - want.top;
    int x = (GetSystemMetrics(SM_CXSCREEN) - w) / 2;
    int y = (GetSystemMetrics(SM_CYSCREEN) - h) / 2;
    if (y < 0) y = 0;

    g_hwnd = CreateWindowExW(0, L"SGPanelWndClass", L"ShellGate",
                             style, x, y, w, h, NULL, NULL, hInst, NULL);
    if (!g_hwnd) { OleUninitialize(); return 1; }

    g_site = Site_Create(g_hwnd);
    if (!g_site) { OleUninitialize(); return 1; }

    hr = CoCreateInstance(&CLSID_WebBrowser, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IOleObject, (void **)&g_oleObj);
    if (FAILED(hr) || !g_oleObj) { OleUninitialize(); return 1; }

    IOleObject_SetClientSite(g_oleObj, &g_site->clientSite);
    IOleObject_SetHostNames(g_oleObj, L"SGPanel", L"ShellGate");

    IPersistStreamInit *psi = NULL;
    if (SUCCEEDED(IOleObject_QueryInterface(g_oleObj, &IID_IPersistStreamInit, (void **)&psi)) && psi) {
        IPersistStreamInit_InitNew(psi);
        IPersistStreamInit_Release(psi);
    }

    hr = IOleObject_QueryInterface(g_oleObj, &IID_IWebBrowser2, (void **)&g_browser);
    if (FAILED(hr) || !g_browser) { OleUninitialize(); return 1; }

    IWebBrowser2_put_RegisterAsBrowser(g_browser, VARIANT_FALSE);
    IWebBrowser2_put_RegisterAsDropTarget(g_browser, VARIANT_FALSE);

    RECT rc;
    GetClientRect(g_hwnd, &rc);
    hr = IOleObject_DoVerb(g_oleObj, OLEIVERB_INPLACEACTIVATE, NULL,
                           &g_site->clientSite, 0, g_hwnd, &rc);
    if (FAILED(hr)) {
        hr = IOleObject_DoVerb(g_oleObj, OLEIVERB_SHOW, NULL,
                               &g_site->clientSite, 0, g_hwnd, &rc);
    }
    ResizeBrowser();
    IWebBrowser2_put_Visible(g_browser, VARIANT_TRUE);

    if (!g_activeObj) {
        /* Fallback for TranslateAccelerator if the frame's SetActiveObject
           was not called during activation. */
        IOleObject_QueryInterface(g_oleObj, &IID_IOleInPlaceActiveObject, (void **)&g_activeObj);
    }

    /* Events: catch window.close() from the page. */
    g_sink = Sink_Create(g_hwnd);
    if (g_sink) {
        IConnectionPointContainer *cpc = NULL;
        if (SUCCEEDED(IWebBrowser2_QueryInterface(g_browser, &IID_IConnectionPointContainer, (void **)&cpc)) && cpc) {
            IConnectionPoint *cp = NULL;
            if (SUCCEEDED(IConnectionPointContainer_FindConnectionPoint(cpc, &DIID_DWebBrowserEvents2, &cp)) && cp) {
                IConnectionPoint_Advise(cp, (IUnknown *)&g_sink->disp, &g_sinkCookie);
                IConnectionPoint_Release(cp);
            }
            IConnectionPointContainer_Release(cpc);
        }
    }

    ShowWindow(g_hwnd, nShow ? nShow : SW_SHOW);
    UpdateWindow(g_hwnd);

    /* Navigate to the panel file. */
    {
        WCHAR url[3 * MAX_PATH];
        url[0] = 0;
        wcsncat(url, L"file:///", 3 * MAX_PATH - 1);
        size_t cur = wcslen(url);
        size_t i;
        for (i = 0; panelPath[i] && cur < 3 * MAX_PATH - 1; i++) {
            url[cur++] = (panelPath[i] == L'\\') ? L'/' : panelPath[i];
        }
        url[cur] = 0;
        BSTR burl = SysAllocString(url);
        if (burl) {
            IWebBrowser2_Navigate(g_browser, burl, NULL, NULL, NULL, NULL);
            SysFreeString(burl);
        }
    }

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (g_activeObj && IOleInPlaceActiveObject_TranslateAccelerator(g_activeObj, &msg) == S_OK)
            continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (g_browser) { IWebBrowser2_Release(g_browser); g_browser = NULL; }
    if (g_activeObj) { IOleInPlaceActiveObject_Release(g_activeObj); g_activeObj = NULL; }
    if (g_oleObj) {
        IOleObject_Close(g_oleObj, OLECLOSE_NOSAVE);
        IOleObject_Release(g_oleObj);
        g_oleObj = NULL;
    }
    if (g_sink) { IDispatch_Release(&g_sink->disp); g_sink = NULL; }
    if (g_site) { Site_Release(g_site); g_site = NULL; }
    if (hMutex) CloseHandle(hMutex);
    OleUninitialize();
    return 0;
}
