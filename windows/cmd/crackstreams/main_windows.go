//go:build windows

package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/nikships/crackstreams/windows/internal/server"
	"github.com/nikships/crackstreams/windows/web"
	"github.com/wailsapp/go-webview2/pkg/edge"
	"github.com/wailsapp/go-webview2/webviewloader"
	"golang.org/x/sys/windows"
)

var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	dwmapi   = windows.NewLazySystemDLL("dwmapi.dll")

	procLoadImageW              = user32.NewProc("LoadImageW")
	procLoadCursorW             = user32.NewProc("LoadCursorW")
	procGetSystemMetrics        = user32.NewProc("GetSystemMetrics")
	procRegisterClassExW        = user32.NewProc("RegisterClassExW")
	procCreateWindowExW         = user32.NewProc("CreateWindowExW")
	procDestroyWindow           = user32.NewProc("DestroyWindow")
	procShowWindow              = user32.NewProc("ShowWindow")
	procUpdateWindow            = user32.NewProc("UpdateWindow")
	procSetFocus                = user32.NewProc("SetFocus")
	procGetMessageW             = user32.NewProc("GetMessageW")
	procTranslateMessage        = user32.NewProc("TranslateMessage")
	procDispatchMessageW        = user32.NewProc("DispatchMessageW")
	procDefWindowProcW          = user32.NewProc("DefWindowProcW")
	procPostQuitMessage         = user32.NewProc("PostQuitMessage")
	procPostMessageW            = user32.NewProc("PostMessageW")
	procGetWindowLongPtrW       = user32.NewProc("GetWindowLongPtrW")
	procSetWindowLongPtrW       = user32.NewProc("SetWindowLongPtrW")
	procSetWindowPos            = user32.NewProc("SetWindowPos")
	procGetWindowPlacement      = user32.NewProc("GetWindowPlacement")
	procSetWindowPlacement      = user32.NewProc("SetWindowPlacement")
	procMonitorFromWindow       = user32.NewProc("MonitorFromWindow")
	procGetMonitorInfoW         = user32.NewProc("GetMonitorInfoW")
	procGetDpiForWindow         = user32.NewProc("GetDpiForWindow")
	procMessageBoxW             = user32.NewProc("MessageBoxW")
	procSetForegroundWindow     = user32.NewProc("SetForegroundWindow")

	procCreateSolidBrush        = gdi32.NewProc("CreateSolidBrush")
	procDwmSetWindowAttribute   = dwmapi.NewProc("DwmSetWindowAttribute")
)

const (
	wsOverlappedWindow = 0x00CF0000
	wsClipChildren     = 0x02000000

	swShow             = 5
	smCxScreen         = 0
	smCyScreen         = 1
	smCxIcon           = 11
	smCyIcon           = 12
	smCxSmIcon         = 49
	smCySmIcon         = 50

	imageIcon          = 1
	lrDefaultSize      = 0x00000040
	lrShared           = 0x00008000
	idcArrow           = 32512
	idiApplication     = 32512

	wmDestroy          = 0x0002
	wmMove             = 0x0003
	wmSize             = 0x0005
	wmActivate         = 0x0006
	wmClose            = 0x0010
	wmQuit             = 0x0012
	wmGetMinMaxInfo    = 0x0024
	wmMoving           = 0x0216
	wmDpiChanged       = 0x02E0
	wmAppInvoke        = 0x8001

	waInactive         = 0
	gwlStyle           = ^uintptr(15) // -16 (GWL_STYLE)

	swpNoSize          = 0x0001
	swpNoMove          = 0x0002
	swpNoZOrder        = 0x0004
	swpFrameChanged    = 0x0020
	swpNoOwnerZOrder   = 0x0200

	monitorDefaultNearest = 0x00000002

	dwmwaUseImmersiveDarkMode = 20
	dwmwaCaptionColor         = 35

	mbIconError        = 0x00000010
	mbOK               = 0x00000000
)

type point struct {
	x, y int32
}

type rect struct {
	left, top, right, bottom int32
}

type minMaxInfo struct {
	ptReserved     point
	ptMaxSize      point
	ptMaxPosition  point
	ptMinTrackSize point
	ptMaxTrackSize point
}

type monitorInfo struct {
	cbSize    uint32
	rcMonitor rect
	rcWork    rect
	dwFlags   uint32
}

type windowPlacement struct {
	length           uint32
	flags            uint32
	showCmd          uint32
	ptMinPosition    point
	ptMaxPosition    point
	rcNormalPosition rect
}

type wndClassExW struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     windows.Handle
	hIcon         windows.Handle
	hCursor       windows.Handle
	hbrBackground windows.Handle
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       windows.Handle
}

type winMsg struct {
	hwnd     windows.Handle
	message  uint32
	wParam   uintptr
	lParam   uintptr
	time     uint32
	pt       point
	lPrivate uint32
}

type winHost struct {
	hwnd           uintptr
	chromium       *edge.Chromium
	nativeActive   atomic.Bool
	fullscreen     atomic.Bool
	savedStyle     uintptr
	savedPlacement windowPlacement

	queueMu sync.Mutex
	queue   []func()
}

var activeHost *winHost

func (h *winHost) HasNativeWindow() bool {
	return h.nativeActive.Load()
}

func (h *winHost) IsFullscreen() bool {
	return h.fullscreen.Load()
}

func (h *winHost) invokeUI(fn func()) {
	h.queueMu.Lock()
	h.queue = append(h.queue, fn)
	h.queueMu.Unlock()
	if h.hwnd != 0 {
		_, _, _ = procPostMessageW.Call(h.hwnd, wmAppInvoke, 0, 0)
	}
}

func (h *winHost) drainQueue() {
	h.queueMu.Lock()
	tasks := make([]func(), len(h.queue))
	copy(tasks, h.queue)
	h.queue = h.queue[:0]
	h.queueMu.Unlock()
	for _, fn := range tasks {
		fn()
	}
}

func (h *winHost) SetFullscreen(mode string) bool {
	if !h.HasNativeWindow() {
		return false
	}
	done := make(chan bool, 1)
	h.invokeUI(func() {
		done <- h.applyFullscreenOnUIThread(mode)
	})
	select {
	case res := <-done:
		return res
	case <-time.After(2 * time.Second):
		return h.IsFullscreen()
	}
}

func (h *winHost) applyFullscreenOnUIThread(mode string) bool {
	if h.hwnd == 0 {
		return false
	}
	currentlyFull := h.fullscreen.Load()
	wantFull := currentlyFull
	switch mode {
	case "enter":
		wantFull = true
	case "exit":
		wantFull = false
	default:
		wantFull = !currentlyFull
	}
	if wantFull == currentlyFull {
		return currentlyFull
	}

	if wantFull {
		style, _, _ := procGetWindowLongPtrW.Call(h.hwnd, gwlStyle)
		h.savedStyle = style
		h.savedPlacement = windowPlacement{length: uint32(unsafe.Sizeof(windowPlacement{}))}
		_, _, _ = procGetWindowPlacement.Call(h.hwnd, uintptr(unsafe.Pointer(&h.savedPlacement)))

		mon, _, _ := procMonitorFromWindow.Call(h.hwnd, monitorDefaultNearest)
		mi := monitorInfo{cbSize: uint32(unsafe.Sizeof(monitorInfo{}))}
		r, _, _ := procGetMonitorInfoW.Call(mon, uintptr(unsafe.Pointer(&mi)))
		if r != 0 {
			newStyle := style &^ uintptr(wsOverlappedWindow)
			_, _, _ = procSetWindowLongPtrW.Call(h.hwnd, gwlStyle, newStyle)
			w := uintptr(mi.rcMonitor.right - mi.rcMonitor.left)
			ht := uintptr(mi.rcMonitor.bottom - mi.rcMonitor.top)
			_, _, _ = procSetWindowPos.Call(
				h.hwnd,
				0, // HWND_TOP
				uintptr(mi.rcMonitor.left),
				uintptr(mi.rcMonitor.top),
				w,
				ht,
				swpNoOwnerZOrder|swpFrameChanged,
			)
			h.fullscreen.Store(true)
		}
	} else {
		_, _, _ = procSetWindowLongPtrW.Call(h.hwnd, gwlStyle, h.savedStyle)
		if h.savedPlacement.length != 0 {
			_, _, _ = procSetWindowPlacement.Call(h.hwnd, uintptr(unsafe.Pointer(&h.savedPlacement)))
		}
		_, _, _ = procSetWindowPos.Call(
			h.hwnd,
			0,
			0, 0, 0, 0,
			swpNoMove|swpNoSize|swpNoZOrder|swpNoOwnerZOrder|swpFrameChanged,
		)
		h.fullscreen.Store(false)
	}

	if h.chromium != nil {
		h.chromium.Resize()
	}
	return h.fullscreen.Load()
}

func (h *winHost) CreateShortcuts() error {
	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	exePath, err = filepath.Abs(exePath)
	if err != nil {
		return err
	}

	// Copy the portable .exe to %LOCALAPPDATA%\Programs\Crackstreams\Crackstreams.exe so
	// Desktop & Start Menu shortcuts keep working even if the user deletes Downloads.
	targetExe := exePath
	if localAppData := os.Getenv("LOCALAPPDATA"); localAppData != "" {
		installDir := filepath.Join(localAppData, "Programs", "Crackstreams")
		installedExe := filepath.Join(installDir, "Crackstreams.exe")
		if !strings.EqualFold(filepath.Clean(exePath), filepath.Clean(installedExe)) {
			if err := os.MkdirAll(installDir, 0755); err == nil {
				if err := copyFileAtomic(exePath, installedExe); err == nil {
					targetExe = installedExe
				}
			}
		} else {
			targetExe = installedExe
		}
	}

	workDir := filepath.Dir(targetExe)
	escapedExe := strings.ReplaceAll(targetExe, "'", "''")
	escapedDir := strings.ReplaceAll(workDir, "'", "''")

	psScript := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$ws = New-Object -ComObject WScript.Shell
$paths = @(
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Crackstreams.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'Crackstreams.lnk')
)
foreach ($p in $paths) {
  $s = $ws.CreateShortcut($p)
  $s.TargetPath = '%s'
  $s.WorkingDirectory = '%s'
  $s.IconLocation = '%s,0'
  $s.Description = 'Crackstreams - 4-Pane Live Sports Player'
  $s.Save()
}
`, escapedExe, escapedDir, escapedExe)

	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", psScript)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("shortcut creation failed: %v (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func copyFileAtomic(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func wndProc(hwnd, msg, wParam, lParam uintptr) uintptr {
	h := activeHost
	if h != nil && h.hwnd == hwnd {
		switch msg {
		case wmAppInvoke:
			h.drainQueue()
			return 0
		case wmMove, wmMoving:
			if h.chromium != nil {
				_ = h.chromium.NotifyParentWindowPositionChanged()
			}
		case wmSize:
			if h.chromium != nil {
				h.chromium.Resize()
			}
			return 0
		case wmDpiChanged:
			if lParam != 0 {
				suggested := (*rect)(unsafe.Pointer(lParam))
				_, _, _ = procSetWindowPos.Call(
					hwnd,
					0,
					uintptr(suggested.left),
					uintptr(suggested.top),
					uintptr(suggested.right-suggested.left),
					uintptr(suggested.bottom-suggested.top),
					swpNoZOrder|swpNoOwnerZOrder,
				)
				if h.chromium != nil {
					h.chromium.Resize()
				}
			}
			return 0
		case wmActivate:
			if wParam != waInactive && h.chromium != nil {
				h.chromium.Focus()
			}
		case wmGetMinMaxInfo:
			mmi := (*minMaxInfo)(unsafe.Pointer(lParam))
			scale := windowScale(hwnd)
			mmi.ptMinTrackSize.x = int32(float64(820) * scale)
			mmi.ptMinTrackSize.y = int32(float64(540) * scale)
			return 0
		case wmClose:
			if h.chromium != nil {
				h.chromium.ShuttingDown()
			}
			_, _, _ = procDestroyWindow.Call(hwnd)
			return 0
		case wmDestroy:
			h.nativeActive.Store(false)
			_, _, _ = procPostQuitMessage.Call(0)
			return 0
		}
	}
	ret, _, _ := procDefWindowProcW.Call(hwnd, msg, wParam, lParam)
	return ret
}

func windowScale(hwnd uintptr) float64 {
	if err := procGetDpiForWindow.Find(); err == nil && hwnd != 0 {
		dpi, _, _ := procGetDpiForWindow.Call(hwnd)
		if dpi >= 96 && dpi <= 480 {
			return float64(dpi) / 96.0
		}
	}
	return 1.0
}

func applyDarkChrome(hwnd uintptr) {
	if err := procDwmSetWindowAttribute.Find(); err != nil {
		return
	}
	dark := int32(1)
	_, _, _ = procDwmSetWindowAttribute.Call(hwnd, dwmwaUseImmersiveDarkMode, uintptr(unsafe.Pointer(&dark)), 4)
	// Fallback attribute 19 for older Windows 10 builds
	_, _, _ = procDwmSetWindowAttribute.Call(hwnd, 19, uintptr(unsafe.Pointer(&dark)), 4)
	// Seamless #0a0c12 caption color on Windows 11 (COLORREF 0x00BBGGRR)
	caption := uint32(0x00120C0A)
	_, _, _ = procDwmSetWindowAttribute.Call(hwnd, dwmwaCaptionColor, uintptr(unsafe.Pointer(&caption)), 4)
}

func loadAppIcons(hInstance windows.Handle) (windows.Handle, windows.Handle) {
	cxBig, _, _ := procGetSystemMetrics.Call(smCxIcon)
	cyBig, _, _ := procGetSystemMetrics.Call(smCyIcon)
	cxSm, _, _ := procGetSystemMetrics.Call(smCxSmIcon)
	cySm, _, _ := procGetSystemMetrics.Call(smCySmIcon)

	// Icon resource ID 1 embedded via rsrc_windows_*.syso
	big, _, _ := procLoadImageW.Call(uintptr(hInstance), 1, imageIcon, cxBig, cyBig, 0)
	sm, _, _ := procLoadImageW.Call(uintptr(hInstance), 1, imageIcon, cxSm, cySm, 0)
	if big == 0 {
		big, _, _ = procLoadImageW.Call(0, idiApplication, imageIcon, 0, 0, lrDefaultSize|lrShared)
	}
	if sm == 0 {
		sm = big
	}
	return windows.Handle(big), windows.Handle(sm)
}

func showErrorBox(message string) {
	title, _ := windows.UTF16PtrFromString("Crackstreams")
	body, _ := windows.UTF16PtrFromString(message)
	_, _, _ = procMessageBoxW.Call(0, uintptr(unsafe.Pointer(body)), uintptr(unsafe.Pointer(title)), mbOK|mbIconError)
}

func findAppBrowser() string {
	var candidates []string
	for _, envName := range []string{"ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA"} {
		base := os.Getenv(envName)
		if base == "" {
			continue
		}
		candidates = append(candidates,
			filepath.Join(base, "Microsoft", "Edge", "Application", "msedge.exe"),
			filepath.Join(base, "Google", "Chrome", "Application", "chrome.exe"),
			filepath.Join(base, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
		)
	}
	for _, p := range candidates {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

func runBrowserFallback(srv *server.Server, dataRoot string) {
	launchURL := srv.LaunchURL()
	browserExe := findAppBrowser()
	if browserExe != "" {
		profileDir := filepath.Join(dataRoot, "BrowserAppProfile")
		_ = os.MkdirAll(profileDir, 0755)
		cmd := exec.Command(
			browserExe,
			"--app="+launchURL,
			"--new-window",
			"--window-size=1280,780",
			"--user-data-dir="+profileDir,
			"--autoplay-policy=no-user-gesture-required",
			"--no-first-run",
			"--no-default-browser-check",
		)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		_ = cmd.Start()
	} else {
		cmd := exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", launchURL)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		_ = cmd.Start()
	}

	srv.WaitForBrowserSession(60*time.Second, 25*time.Second)
}

func main() {
	runtime.LockOSThread()

	host := &winHost{}
	activeHost = host

	for _, arg := range os.Args[1:] {
		if arg == "--install-shortcuts" {
			_ = host.CreateShortcuts()
			return
		}
	}

	dataRoot := filepath.Join(os.TempDir(), "Crackstreams")
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		dataRoot = filepath.Join(local, "Crackstreams")
	}
	wv2DataPath := filepath.Join(dataRoot, "WebView2")
	_ = os.MkdirAll(wv2DataPath, 0755)

	srv, err := server.New(server.Config{
		Assets:  web.Assets,
		WinCtrl: host,
	})
	if err != nil {
		showErrorBox(fmt.Sprintf("Crackstreams could not start its local video relay:\n\n%v", err))
		return
	}
	srv.Start()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Close(ctx)
	}()

	// Verify WebView2 Evergreen Runtime is available before creating the embedded host;
	// if missing on an older Windows 10 installation, fall back seamlessly to app-mode browser.
	wvVersion, wvErr := webviewloader.GetAvailableCoreWebView2BrowserVersionString("")
	if wvErr != nil || wvVersion == "" {
		runBrowserFallback(srv, dataRoot)
		return
	}

	var hInstance windows.Handle
	_ = windows.GetModuleHandleEx(0, nil, &hInstance)

	iconBig, iconSm := loadAppIcons(hInstance)
	cursor, _, _ := procLoadCursorW.Call(0, idcArrow)
	darkBrush, _, _ := procCreateSolidBrush.Call(0x00120C0A)

	className, _ := windows.UTF16PtrFromString("CrackstreamsMainWindow")
	wc := wndClassExW{
		cbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
		lpfnWndProc:   windows.NewCallback(wndProc),
		hInstance:     hInstance,
		hIcon:         iconBig,
		hIconSm:       iconSm,
		hCursor:       windows.Handle(cursor),
		hbrBackground: windows.Handle(darkBrush),
		lpszClassName: className,
	}
	_, _, _ = procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	screenW, _, _ := procGetSystemMetrics.Call(smCxScreen)
	screenH, _, _ := procGetSystemMetrics.Call(smCyScreen)
	winW := int(screenW) * 78 / 100
	winH := int(screenH) * 80 / 100
	if winW < 1040 {
		winW = 1040
	}
	if winW > 1640 {
		winW = 1640
	}
	if winH < 660 {
		winH = 660
	}
	if winH > 980 {
		winH = 980
	}
	posX := (int(screenW) - winW) / 2
	posY := (int(screenH) - winH) / 2
	if posX < 0 {
		posX = 40
	}
	if posY < 0 {
		posY = 40
	}

	title, _ := windows.UTF16PtrFromString("Crackstreams")
	hwnd, _, _ := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(title)),
		wsOverlappedWindow|wsClipChildren,
		uintptr(posX),
		uintptr(posY),
		uintptr(winW),
		uintptr(winH),
		0,
		0,
		uintptr(hInstance),
		0,
	)
	if hwnd == 0 {
		runBrowserFallback(srv, dataRoot)
		return
	}

	host.hwnd = hwnd
	host.nativeActive.Store(true)
	applyDarkChrome(hwnd)

	chromium := edge.NewChromium()
	chromium.DataPath = wv2DataPath
	chromium.AdditionalBrowserArgs = []string{
		"--autoplay-policy=no-user-gesture-required",
		"--disable-features=msWebOOUI,msPdfOOUI",
	}
	chromium.SetPermission(edge.CoreWebView2PermissionKindClipboardRead, edge.CoreWebView2PermissionStateAllow)
	chromium.ContainsFullScreenElementChangedCallback = func(sender *edge.ICoreWebView2, _ *edge.ICoreWebView2ContainsFullScreenElementChangedEventArgs) {
		if contains, err := sender.GetContainsFullScreenElement(); err == nil {
			if contains {
				host.applyFullscreenOnUIThread("enter")
			} else {
				host.applyFullscreenOnUIThread("exit")
			}
		}
	}
	chromium.AcceleratorKeyCallback = func(vkey uint) bool {
		// Suppress browser-only F3/F5/F7 keys while letting F11 and app shortcuts reach JS.
		switch vkey {
		case 0x72, 0x74, 0x76: // VK_F3, VK_F5, VK_F7
			return true
		default:
			return false
		}
	}

	var embedFailed atomic.Bool
	chromium.SetErrorCallback(func(_ error) {
		embedFailed.Store(true)
	})

	_, _, _ = procShowWindow.Call(hwnd, swShow)
	_, _, _ = procUpdateWindow.Call(hwnd)
	_, _, _ = procSetForegroundWindow.Call(hwnd)
	_, _, _ = procSetFocus.Call(hwnd)

	if !chromium.Embed(hwnd) || embedFailed.Load() {
		host.nativeActive.Store(false)
		_, _, _ = procDestroyWindow.Call(hwnd)
		runBrowserFallback(srv, dataRoot)
		return
	}

	host.chromium = chromium
	chromium.SetBackgroundColour(10, 12, 18, 255)

	if settings, err := chromium.GetSettings(); err == nil && settings != nil {
		_ = settings.PutIsStatusBarEnabled(false)
		_ = settings.PutAreDefaultContextMenusEnabled(false)
		_ = settings.PutAreDevToolsEnabled(false)
		_ = settings.PutIsZoomControlEnabled(false)
		settings.Release()
	}

	chromium.Resize()
	chromium.Navigate(srv.LaunchURL())

	var msg winMsg
	for {
		ret, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(ret) <= 0 {
			break
		}
		if msg.message == wmQuit {
			break
		}
		_, _, _ = procTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		_, _, _ = procDispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
	}
}
