package main

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
)

type Script struct {
	Name      string
	Path      string
	NeedAdmin bool
}

var adminKeywords = []string{
	"hklm:", "hkey_local_machine",
	"hkcr:", "hkey_classes_root",
	"registry::hkey_classes_root", "registry::hkey_local_machine",
	"set-service", "stop-service", "start-service",
	"new-psdrive -name hkcr",
	"takeown", "icacls",
	"powercfg",
	"net start", "net stop",
	"bcdedit", "dism", "sfc /scannow",
}

func main() {
	exePath, _ := os.Executable()
	dir := filepath.Dir(exePath)
	scripts := scanScripts(dir)

	a := app.New()
	a.SetIcon(appIcon)
	w := a.NewWindow("Windows 脚本管理器")
	w.SetIcon(appIcon)
	w.Resize(fyne.NewSize(500, 520))

	var items []fyne.CanvasObject
	for _, s := range scripts {
		s := s
		label := s.Name
		if s.NeedAdmin {
			label += "（需要管理员权限）"
		}
		btn := widget.NewButton(label, func() {
			runScript(s)
		})
		items = append(items, btn)
	}

	if len(items) == 0 {
		items = append(items, widget.NewLabel("未找到 .ps1 脚本"))
	}

	content := container.NewVBox(items...)
	w.SetContent(container.NewVScroll(content))
	w.ShowAndRun()
}

func scanScripts(dir string) []Script {
	var scripts []Script
	entries, err := os.ReadDir(dir)
	if err != nil {
		return scripts
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(strings.ToLower(e.Name()), ".ps1") {
			continue
		}
		fullPath := filepath.Join(dir, e.Name())
		scripts = append(scripts, Script{
			Name:      strings.TrimSuffix(e.Name(), ".ps1"),
			Path:      fullPath,
			NeedAdmin: detectAdmin(fullPath),
		})
	}
	return scripts
}

func detectAdmin(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.ToLower(scanner.Text())
		for _, kw := range adminKeywords {
			if strings.Contains(line, kw) {
				return true
			}
		}
	}
	return false
}

func runScript(s Script) {
	if s.NeedAdmin {
		runAsAdmin(s.Path)
	} else {
		cmd := exec.Command("powershell", "-ExecutionPolicy", "Bypass", "-File", s.Path)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		cmd.Start()
	}
}

func runAsAdmin(scriptPath string) {
	verb, _ := syscall.UTF16PtrFromString("runas")
	exe, _ := syscall.UTF16PtrFromString("powershell")
	args, _ := syscall.UTF16PtrFromString(`-ExecutionPolicy Bypass -File "` + scriptPath + `"`)

	shell32 := syscall.NewLazyDLL("shell32.dll")
	shellExecute := shell32.NewProc("ShellExecuteW")
	shellExecute.Call(0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(exe)),
		uintptr(unsafe.Pointer(args)),
		0, 1)
}
