package main

// v2 item 7 (final numbering): POST /action one-click maintenance actions
// (same auth as /exec).
//
//   cleanup - clears Temp / update-download / CBS logs / recycle bin
//             contents on every volume that carries a Windows install
//             (fixed whitelist; pagefile/hiberfil/Prefetch untouched)
//   fixboot - locates the ESP and rebuilds the boot files with bcdboot
//
// (Dropped by user decision 2026-11-09: the diagnose-report archive, the
// drivers-backup / drivers-restore actions, and fixboot's BCD backup step.
// diagnose keeps its original behaviour: report only to the RAM-disk
// ai-report.txt.)

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

var procGetVolumeInformationW = kernel32.NewProc("GetVolumeInformationW")

// ---------- small helpers ----------

func peSysRoot() string {
	sd := os.Getenv("SystemDrive")
	if sd == "" {
		sd = "X:"
	}
	return sd + "\\"
}

func hasPath(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func isDirPath(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func oneLine(s string) string {
	s = strings.ReplaceAll(strings.TrimSpace(s), "\r\n", " | ")
	s = strings.ReplaceAll(s, "\n", " | ")
	if len(s) > 400 {
		s = s[:400] + "..."
	}
	return s
}

func runOutErr(path string, args ...string) (string, error) {
	cmd := exec.Command(path, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func volumeInfo(root string) (label, fsName string) {
	p, err := syscall.UTF16PtrFromString(root)
	if err != nil {
		return "", ""
	}
	labelBuf := make([]uint16, 256)
	fsBuf := make([]uint16, 64)
	r1, _, _ := procGetVolumeInformationW.Call(uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&labelBuf[0])), uintptr(len(labelBuf)),
		0, 0, 0,
		uintptr(unsafe.Pointer(&fsBuf[0])), uintptr(len(fsBuf)))
	if r1 == 0 {
		return "", ""
	}
	return syscall.UTF16ToString(labelBuf), syscall.UTF16ToString(fsBuf)
}

func isVentoyVolume(root string) bool {
	if isDirPath(filepath.Join(root, "Ventoy")) || hasPath(filepath.Join(root, "ventoy.json")) {
		return true
	}
	label, _ := volumeInfo(root)
	return strings.HasPrefix(strings.ToUpper(label), "VENTOY") || strings.EqualFold(label, "VTOYEFI")
}

// ---------- /action ----------

func normalizeVolumeRoot(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	v = strings.TrimSuffix(v, "\\")
	if len(v) == 1 {
		v += ":"
	}
	return v + "\\"
}

func windowsVolumes() []string {
	sys := peSysRoot()
	var vols []string
	for _, r := range driveRoots() {
		if strings.EqualFold(r, sys) {
			continue
		}
		if isDirPath(filepath.Join(r, "Windows")) {
			vols = append(vols, r)
		}
	}
	return vols
}

func firstWindowsVolume() string {
	if vols := windowsVolumes(); len(vols) > 0 {
		return vols[0]
	}
	return ""
}

func dirSizeCount(root string) (int64, int) {
	var size int64
	files := 0
	_ = filepath.Walk(root, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			size += info.Size()
			files++
		}
		return nil
	})
	return size, files
}

type cleanTarget struct {
	Path         string `json:"path"`
	SizeBefore   int64  `json:"size_before"`
	SizeAfter    int64  `json:"size_after"`
	FilesRemoved int    `json:"files_removed"`
	DryRun       bool   `json:"dry_run"`
	Note         string `json:"note,omitempty"`
}

// clearContents deletes everything inside dir (dir itself is kept).
// When onlyExts is non-empty, only files with those extensions are deleted
// (used for CBS logs: .log/.cab only, everything else stays).
func clearContents(dir string, dryRun bool, onlyExts map[string]bool) cleanTarget {
	t := cleanTarget{Path: dir, DryRun: dryRun}
	if !isDirPath(dir) {
		t.Note = "not present"
		return t
	}
	before, _ := dirSizeCount(dir)
	t.SizeBefore = before
	if dryRun {
		t.SizeAfter = before
		t.Note = "dry-run: nothing deleted"
		return t
	}
	removed := 0
	if len(onlyExts) > 0 {
		_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
			if err == nil && !info.IsDir() && onlyExts[strings.ToLower(filepath.Ext(p))] {
				if err := os.Remove(p); err == nil {
					removed++
				}
			}
			return nil
		})
	} else {
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if err := os.RemoveAll(filepath.Join(dir, e.Name())); err == nil {
				removed++
			}
		}
	}
	after, _ := dirSizeCount(dir)
	t.SizeAfter = after
	t.FilesRemoved = removed
	return t
}

func actionCleanup(dryRun bool) map[string]any {
	res := map[string]any{"action": "cleanup", "dry_run": dryRun}
	vols := windowsVolumes()
	var volResults []any
	var totalFreed int64
	for _, vol := range vols {
		var targets []cleanTarget
		targets = append(targets, clearContents(filepath.Join(vol, "Windows", "Temp"), dryRun, nil))
		targets = append(targets, clearContents(filepath.Join(vol, "Windows", "SoftwareDistribution", "Download"), dryRun, nil))
		targets = append(targets, clearContents(filepath.Join(vol, "Windows", "Logs", "CBS"), dryRun,
			map[string]bool{".log": true, ".cab": true}))
		targets = append(targets, clearContents(filepath.Join(vol, "$Recycle.Bin"), dryRun, nil))
		usersDir := filepath.Join(vol, "Users")
		if entries, err := os.ReadDir(usersDir); err == nil {
			for _, e := range entries {
				if e.IsDir() {
					targets = append(targets, clearContents(
						filepath.Join(usersDir, e.Name(), "AppData", "Local", "Temp"), dryRun, nil))
				}
			}
		}
		var freed int64
		for _, t := range targets {
			freed += t.SizeBefore - t.SizeAfter
		}
		totalFreed += freed
		volResults = append(volResults, map[string]any{
			"volume": vol, "targets": targets, "freed_bytes": freed,
		})
	}
	res["volumes"] = volResults
	res["total_freed_bytes"] = totalFreed
	if len(vols) == 0 {
		res["note"] = "no volume with a Windows installation found"
	}
	res["summary"] = fmt.Sprintf("cleanup dry_run=%v on %d volume(s), freed %d bytes", dryRun, len(vols), totalFreed)
	return res
}

// findESP locates the EFI System Partition: prefer a lettered FAT volume
// with \EFI\Microsoft; fall back to \EFI generally, then to mounting
// letter-less volumes at S: via mountvol and probing for \EFI.
func findESP() (string, []string) {
	steps := []string{}
	for _, wantMS := range []bool{true, false} {
		for _, r := range driveRoots() {
			if isVentoyVolume(r) {
				continue
			}
			_, fs := volumeInfo(r)
			if !strings.EqualFold(fs, "FAT32") && !strings.EqualFold(fs, "FAT") {
				continue
			}
			if wantMS && isDirPath(filepath.Join(r, "EFI", "Microsoft")) {
				steps = append(steps, "ESP found at "+r+" (EFI\\Microsoft present)")
				return r, steps
			}
			if !wantMS && isDirPath(filepath.Join(r, "EFI")) {
				steps = append(steps, "ESP found at "+r+" (EFI directory present)")
				return r, steps
			}
		}
	}
	out, err := runOutErr("mountvol")
	if err != nil {
		steps = append(steps, "mountvol unavailable: "+err.Error())
		return "", steps
	}
	var cands []string
	cur := ""
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, `\\?\Volume{`) {
			cur = line
			continue
		}
		if strings.Contains(line, "NO MOUNT POINTS") && cur != "" {
			cands = append(cands, cur)
		}
	}
	for _, guid := range cands {
		_, _ = runOutErr("mountvol", `S:`, "/D")
		o, err := runOutErr("mountvol", `S:`, guid)
		if err != nil {
			steps = append(steps, "mount "+guid+" at S: failed: "+oneLine(o))
			continue
		}
		if isDirPath(`S:\EFI`) {
			steps = append(steps, "ESP mounted at S: from "+guid)
			return `S:\`, steps
		}
		steps = append(steps, "mounted "+guid+" at S:: no EFI directory, unmounted")
		_, _ = runOutErr("mountvol", `S:`, "/D")
	}
	return "", steps
}

func actionFixboot(volume string) map[string]any {
	res := map[string]any{"action": "fixboot"}
	steps := []string{}
	vol := normalizeVolumeRoot(volume)
	if vol == "" {
		vol = firstWindowsVolume()
	}
	if vol == "" {
		res["error"] = "no volume with a Windows installation found"
		res["steps"] = steps
		res["summary"] = "error: no windows volume"
		return res
	}
	res["volume"] = vol
	if !isDirPath(filepath.Join(vol, "Windows")) {
		res["error"] = vol + " has no Windows directory"
		res["steps"] = steps
		res["summary"] = "error: volume has no Windows directory"
		return res
	}
	steps = append(steps, "target windows volume: "+vol)
	esp, espSteps := findESP()
	steps = append(steps, espSteps...)
	if esp == "" {
		res["error"] = "ESP not found"
		res["steps"] = steps
		res["summary"] = "error: ESP not found"
		return res
	}
	res["esp"] = esp
	tool := findTool("bcdboot")
	if tool == "" {
		res["error"] = "bcdboot not found on PATH or in any Windows volume's System32"
		res["steps"] = steps
		res["summary"] = "error: bcdboot missing"
		return res
	}
	steps = append(steps, "bcdboot: "+tool)
	out, err := runOutErr(tool, filepath.Join(vol, "Windows"), "/s", strings.TrimSuffix(esp, "\\"), "/f", "ALL")
	steps = append(steps, "bcdboot output: "+oneLine(out))
	res["steps"] = steps
	if err != nil {
		res["error"] = "bcdboot failed: " + err.Error()
		res["summary"] = "error: bcdboot failed"
		return res
	}
	res["ok"] = true
	res["summary"] = "fixboot ok: " + vol + " -> ESP " + esp
	return res
}

func registerActionEndpoint(mux *http.ServeMux, guard func(http.HandlerFunc) http.HandlerFunc) {
	mux.HandleFunc("/action", guard(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, 405, map[string]any{"error": "POST required"})
			return
		}
		var req struct {
			Action string `json:"action"`
			DryRun bool   `json:"dry_run"`
			Volume string `json:"volume"`
		}
		b, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err := json.Unmarshal(b, &req); err != nil {
			writeJSON(w, 400, map[string]any{"error": "bad json: " + err.Error()})
			return
		}
		var res map[string]any
		switch req.Action {
		case "cleanup":
			res = actionCleanup(req.DryRun)
		case "fixboot":
			res = actionFixboot(req.Volume)
		default:
			writeJSON(w, 400, map[string]any{"error": "unknown action: " + req.Action +
				" (supported: cleanup, fixboot)"})
			return
		}
		writeJSON(w, 200, res)
	}))
}
