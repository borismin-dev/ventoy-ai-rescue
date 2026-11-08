// ai-rescue.exe - AI-Rescue for Windows PE (single static Go binary)
//
// Built for slim WinPE environments (FirPE / HotPE / WePE class): these often
// have NO PowerShell and NO .NET, so this tool is a dependency-free static
// executable. Subcommands:
//
//	ai-rescue.exe diagnose [--llm]   offline rule-based diagnosis (BCD, disks,
//	                                 minidumps, event log, memory, network)
//	ai-rescue.exe agent              HTTP JSON maintenance-agent API on :8734
//	                                 (/health /info /diagnose /exec), same
//	                                 protocol as the Linux rescue-agent
//	ai-rescue.exe ask "question"     ask an OpenAI-compatible LLM
//
// Config (LLM + tunnel hints) is read from rescue-config/agent.conf found in
// the root of any local drive (the Ventoy USB), or from the environment
// (AI_API_BASE / AI_API_KEY / AI_MODEL). No key is baked into the binary.
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"rsc.io/qr"
)

const agentPort = 8734
const agentVersion = "1.0-go"

// ---------- config ----------

func loadConfig() map[string]string {
	cfg := map[string]string{}
	for _, k := range []string{"AI_API_BASE", "AI_API_KEY", "AI_MODEL", "TUNNEL_HOST"} {
		if v := os.Getenv(k); v != "" {
			cfg[k] = v
		}
	}
	// scan drive roots for rescue-config\agent.conf
	for _, root := range driveRoots() {
		p := filepath.Join(root, "rescue-config", "agent.conf")
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
				continue
			}
			kv := strings.SplitN(line, "=", 2)
			cfg[strings.TrimSpace(kv[0])] = strings.Trim(strings.TrimSpace(kv[1]), `"'`)
		}
		fmt.Printf("[ai-rescue] loaded config from %s (keys: %v)\n", p, keysOf(cfg))
		break
	}
	return cfg
}

func keysOf(m map[string]string) []string {
	var ks []string
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}

// ---------- windows helpers (stdlib lazy DLLs) ----------

var (
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	procGetDiskFreeSpaceExW  = kernel32.NewProc("GetDiskFreeSpaceExW")
	procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")
)

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

func driveRoots() []string {
	var roots []string
	for c := 'A'; c <= 'Z'; c++ {
		r := string(c) + ":\\"
		if _, err := os.Stat(r); err == nil {
			roots = append(roots, r)
		}
	}
	return roots
}

func diskFree(root string) (total, free uint64, ok bool) {
	p, err := syscall.UTF16PtrFromString(root)
	if err != nil {
		return 0, 0, false
	}
	var freeAvail, totalBytes, totalFree uint64
	r1, _, _ := procGetDiskFreeSpaceExW.Call(uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&freeAvail)), uintptr(unsafe.Pointer(&totalBytes)),
		uintptr(unsafe.Pointer(&totalFree)))
	if r1 == 0 {
		return 0, 0, false
	}
	return totalBytes, freeAvail, true
}

func memInfo() (total, avail uint64, load uint32, ok bool) {
	var ms memoryStatusEx
	ms.Length = uint32(unsafe.Sizeof(ms))
	r1, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&ms)))
	if r1 == 0 {
		return 0, 0, 0, false
	}
	return ms.TotalPhys, ms.AvailPhys, ms.MemoryLoad, true
}

func runCapture(name string, args ...string) string {
	cmd := exec.Command(name, args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	if err := cmd.Run(); err != nil {
		return fmt.Sprintf("(%s unavailable or failed: %v)", name, err)
	}
	return buf.String()
}

func gb(b uint64) float64 { return float64(b) / (1 << 30) }

// ---------- diagnose ----------

type Finding struct {
	Level  string `json:"level"`
	Title  string `json:"title"`
	Detail string `json:"detail,omitempty"`
	Advice string `json:"advice,omitempty"`
}

func collectDiagnose() (string, []Finding) {
	var findings []Finding
	var sb strings.Builder
	host, _ := os.Hostname()
	sb.WriteString("================================================================\n")
	sb.WriteString("AI-Rescue (Windows) - ai-rescue diagnose report\n")
	sb.WriteString(fmt.Sprintf("Time: %s  Host: %s  Go: %s %s/%s\n", time.Now().Format(time.RFC3339), host, runtime.Version(), runtime.GOOS, runtime.GOARCH))
	sb.WriteString(fmt.Sprintf("SystemDrive=%s  WinDir=%s  ComputerName=%s\n", os.Getenv("SystemDrive"), os.Getenv("windir"), os.Getenv("COMPUTERNAME")))
	sb.WriteString("================================================================\n\n[Volumes]\n")

	for _, root := range driveRoots() {
		total, free, ok := diskFree(root)
		if !ok {
			sb.WriteString(fmt.Sprintf("  %s (unreadable)\n", root))
			continue
		}
		pctFree := 0.0
		if total > 0 {
			pctFree = float64(free) / float64(total) * 100
		}
		sb.WriteString(fmt.Sprintf("  %s total %.1f GiB, free %.1f GiB (%.0f%% free)\n", root, gb(total), gb(free), pctFree))
		if total > 0 && pctFree < 3 {
			findings = append(findings, Finding{"CRITICAL", fmt.Sprintf("Volume %s almost full (%.0f%% free)", root, pctFree), "", "Free space or extend the volume; a full system volume breaks boot/update."})
		} else if total > 0 && pctFree < 10 {
			findings = append(findings, Finding{"WARN", fmt.Sprintf("Volume %s low on space (%.0f%% free)", root, pctFree), "", "Plan cleanup (WinSxS/temp/logs)."})
		}
		// Windows installs & crash dumps per volume
		winDir := filepath.Join(root, "Windows")
		if st, err := os.Stat(winDir); err == nil && st.IsDir() {
			sb.WriteString(fmt.Sprintf("  %s contains a Windows installation\n", root))
			dumpDir := filepath.Join(winDir, "Minidump")
			if entries, err := os.ReadDir(dumpDir); err == nil && len(entries) > 0 {
				var names []string
				for _, e := range entries {
					names = append(names, e.Name())
				}
				findings = append(findings, Finding{"WARN", fmt.Sprintf("%d crash minidump(s) in %s", len(entries), dumpDir), strings.Join(names, ", "), "Frequent recent dumps point at a driver/hardware fault; analyse with WinDbg or ask the LLM with the dump file names + STOP codes from the event log."})
			}
			if _, err := os.Stat(filepath.Join(winDir, "MEMORY.DMP")); err == nil {
				findings = append(findings, Finding{"INFO", "Full MEMORY.DMP present in " + winDir, "", "Large but valuable for WinDbg analysis."})
			}
		}
	}

	if total, avail, load, ok := memInfo(); ok {
		sb.WriteString(fmt.Sprintf("\n[Memory] total %.1f GiB, available %.1f GiB, load %d%%\n", gb(total), gb(avail), load))
		if load > 92 {
			findings = append(findings, Finding{"WARN", "Memory load above 92%", "", "Check for a leaking process; run a RAM test (memtest) if errors persist."})
		}
	}

	sb.WriteString("\n[Network]\n")
	if ifs, err := net.Interfaces(); err == nil {
		for _, ifc := range ifs {
			addrs, _ := ifc.Addrs()
			sb.WriteString(fmt.Sprintf("  %s flags=%s addrs=%v\n", ifc.Name, ifc.Flags.String(), addrs))
		}
	}
	hasRouteIP := false
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addrs {
			if strings.Contains(a.String(), ".") && !strings.HasPrefix(a.String(), "127.") && !strings.HasPrefix(a.String(), "169.254.") {
				hasRouteIP = true
			}
		}
	}
	if !hasRouteIP {
		findings = append(findings, Finding{"WARN", "No usable IPv4 address (DHCP may have failed)", "", "Check cable/NIC driver; in PE run: wpeinit, then ipconfig /renew."})
	}

	sb.WriteString("\n[BCD - bcdedit /enum]\n")
	bcd := runCapture("bcdedit", "/enum", "{bootmgr}")
	sb.WriteString(indent(bcd, 2000))
	if strings.Contains(bcd, "unavailable") {
		sb.WriteString("  (bcdedit not present in this PE - BCD check skipped)\n")
	} else if strings.Contains(strings.ToLower(bcd), "the boot configuration data store could not be opened") ||
		strings.Contains(strings.ToLower(bcd), "could not be opened") {
		findings = append(findings, Finding{"CRITICAL", "BCD store could not be opened", "", "Boot from PE, locate the ESP/BCD, rebuild: bcdboot C:\\Windows /s Z: /f ALL (adjust letters)."})
	}
	bcdAll := runCapture("bcdedit", "/enum", "all")
	if strings.Contains(bcdAll, "Windows Boot Loader") {
		sb.WriteString("  Windows Boot Loader entries found.\n")
	}

	sb.WriteString("\n[Event log - latest System errors (wevtutil)]\n")
	ev := runCapture("wevtutil", "qe", "System", "/c:15", "/rd:true", "/f:text", "/q:*[System[(Level=1 or Level=2)]]")
	sb.WriteString(indent(ev, 2500))
	if strings.Contains(strings.ToLower(ev), "bugcheck") || strings.Contains(ev, "0x0000") {
		findings = append(findings, Finding{"INFO", "Bugcheck/error events present in System log", "", "Correlate STOP codes with minidumps above."})
	}

	sb.WriteString("\n[SMART hint]\n")
	wmic := runCapture("wmic", "diskdrive", "get", "model,status", "/format:list")
	if strings.Contains(wmic, "unavailable") {
		sb.WriteString("  wmic not present in this PE (common in slim WinPE). Use the Linux AI-Rescue-PE smartctl, or a vendor tool, for SMART.\n")
	} else {
		sb.WriteString(indent(wmic, 1200))
		if strings.Contains(wmic, "Status=Pred Fail") {
			findings = append(findings, Finding{"CRITICAL", "SMART predicts failure on a disk (wmic)", "", "Back up immediately, replace the disk."})
		}
	}

	if len(findings) == 0 {
		findings = append(findings, Finding{"OK", "No issues matched by the rule engine", "", "For deeper checks: chkdsk (read-only first), DISM /Online /Cleanup-Image /ScanHealth on the offline image, RAM test."})
	}
	sb.WriteString("\n[Findings - rule engine]\n")
	for _, f := range findings {
		sb.WriteString(fmt.Sprintf("- [%s] %s\n", f.Level, f.Title))
		if f.Detail != "" {
			sb.WriteString("    evidence: " + f.Detail + "\n")
		}
		if f.Advice != "" {
			sb.WriteString("    advice: " + f.Advice + "\n")
		}
	}
	sb.WriteString("\nBoot-failure checklist:\n")
	sb.WriteString(" 1. 0xc000000e / BCD errors -> rebuild BCD with bcdboot from PE\n")
	sb.WriteString(" 2. INACCESSIBLE_BOOT_DEVICE -> storage driver / disk mode (AHCI<->RAID) mismatch\n")
	sb.WriteString(" 3. Repeated BSOD -> check minidumps + RAM + disk SMART\n")
	sb.WriteString(" 4. Data loss -> STOP writing; image the disk first (ddrescue on Linux PE), then recover from the image\n")
	return sb.String(), findings
}

func indent(s string, max int) string {
	if len(s) > max {
		s = s[:max] + "\n...(truncated)\n"
	}
	var out []string
	for _, l := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		out = append(out, "  "+l)
	}
	return strings.Join(out, "\n") + "\n"
}

// ---------- LLM ----------

func llmAsk(cfg map[string]string, prompt string) string {
	base := cfg["AI_API_BASE"]
	if base == "" {
		base = "https://api.openai.com/v1"
	}
	key := cfg["AI_API_KEY"]
	model := cfg["AI_MODEL"]
	if model == "" {
		model = "gpt-4o-mini"
	}
	if key == "" {
		return "[ai-rescue] No AI_API_KEY configured. Put rescue-config\\agent.conf in the root of the USB (AI_API_BASE/AI_API_KEY/AI_MODEL) or set the environment variables. Offline `diagnose` works without a key."
	}
	payload, _ := json.Marshal(map[string]any{
		"model": model,
		"messages": []map[string]string{
			{"role": "system", "content": "You are a Windows system-rescue debugging assistant inside a WinPE. Be concrete, give commands, warn before destructive steps."},
			{"role": "user", "content": prompt},
		},
	})
	req, err := http.NewRequest("POST", strings.TrimRight(base, "/")+"/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return "[ai-rescue] request build failed: " + err.Error()
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+key)
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "[ai-rescue] LLM request failed: " + err.Error()
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var data struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &data); err != nil || len(data.Choices) == 0 {
		return "[ai-rescue] unexpected LLM response: " + string(body[:min(500, len(body))])
	}
	return data.Choices[0].Message.Content
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ---------- agent ----------

var (
	agentToken string
	agentCfg   map[string]string
)

func genToken() string {
	b := make([]byte, 18)
	_, _ = rand.Read(b)
	const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	for i := range b {
		b[i] = alpha[int(b[i])%len(alpha)]
	}
	return string(b)
}

func authed(r *http.Request) bool {
	given := r.Header.Get("X-Rescue-Token")
	if given == "" {
		if a := r.Header.Get("Authorization"); strings.HasPrefix(a, "Bearer ") {
			given = strings.TrimSpace(strings.TrimPrefix(a, "Bearer "))
		}
	}
	if given == "" {
		given = r.URL.Query().Get("token")
	}
	return given != "" && subtle.ConstantTimeCompare([]byte(given), []byte(agentToken)) == 1
}

func writeJSON(w http.ResponseWriter, code int, obj any) {
	body, _ := json.Marshal(obj)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

func agentInfo() map[string]any {
	host, _ := os.Hostname()
	var ips []string
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addrs {
			ips = append(ips, a.String())
		}
	}
	_, llm := agentCfg["AI_API_KEY"]
	return map[string]any{
		"hostname": host, "agent_version": agentVersion, "os": "windows-pe",
		"go": runtime.Version(), "time": time.Now().Format(time.RFC3339),
		"ipv4": ips, "llm_configured": llm, "api_port": agentPort,
		"note": "WinPE has no native sshd in slim builds; this HTTP API is the primary remote channel.",
	}
}

func runAgent() {
	agentCfg = loadConfig()
	agentToken = genToken()
	// token also dropped on the RAM disk for the local operator/scripts
	tokenPaths := []string{}
	if sd := os.Getenv("SystemDrive"); sd != "" {
		tokenPaths = append(tokenPaths, filepath.Join(sd+"\\", "rescue-token.txt"))
	}
	tokenPaths = append(tokenPaths, filepath.Join(os.TempDir(), "rescue-token.txt"))
	for _, p := range tokenPaths {
		_ = os.WriteFile(p, []byte(agentToken+"\n"), 0600)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"status": "ok", "service": "rescue-agent", "version": agentVersion, "os": "windows-pe", "time": time.Now().Format(time.RFC3339)})
	})
	guard := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if !authed(r) {
				writeJSON(w, 401, map[string]any{"error": "unauthorized", "hint": "X-Rescue-Token header / Bearer / ?token= ; token is printed on the console at agent start"})
				return
			}
			h(w, r)
		}
	}
	mux.HandleFunc("/info", guard(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, agentInfo())
	}))
	mux.HandleFunc("/diagnose", guard(func(w http.ResponseWriter, r *http.Request) {
		report, findings := collectDiagnose()
		llmUsed := false
		if strings.Contains(r.URL.RawQuery, "llm=1") {
			report += "\n[LLM analysis]\n" + llmAsk(agentCfg, "Diagnose this Windows rescue report:\n"+report)
			llmUsed = agentCfg["AI_API_KEY"] != ""
		}
		_ = os.WriteFile(filepath.Join(os.TempDir(), "ai-report.txt"), []byte(report), 0644)
		writeJSON(w, 200, map[string]any{"exitCode": 0, "report": report, "findings": findings, "llm_used": llmUsed})
	}))
	mux.HandleFunc("/exec", guard(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Cmd     string `json:"cmd"`
			Timeout int    `json:"timeout"`
		}
		b, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		_ = json.Unmarshal(b, &body)
		if body.Cmd == "" {
			writeJSON(w, 400, map[string]any{"error": "cmd is required"})
			return
		}
		to := body.Timeout
		if to <= 0 || to > 600 {
			to = 120
		}
		done := make(chan struct{})
		var outBuf bytes.Buffer
		cmd := exec.Command("cmd.exe", "/c", body.Cmd)
		cmd.Stdout = &outBuf
		cmd.Stderr = &outBuf
		err := cmd.Start()
		if err == nil {
			go func() { _ = cmd.Wait(); close(done) }()
			select {
			case <-done:
			case <-time.After(time.Duration(to) * time.Second):
				_ = cmd.Process.Kill()
				outBuf.WriteString("\n(timeout - killed)")
			}
		}
		code := 0
		if cmd.ProcessState != nil {
			code = cmd.ProcessState.ExitCode()
		}
		if err != nil {
			code = -1
			outBuf.WriteString("start error: " + err.Error())
		}
		writeJSON(w, 200, map[string]any{"cmd": body.Cmd, "exitCode": code, "stdout": tail(outBuf.String(), 65536), "stderr": ""})
	}))

	printBanner()
	fmt.Printf("[ai-rescue] agent listening on 0.0.0.0:%d\n", agentPort)
	srv := &http.Server{Addr: fmt.Sprintf("0.0.0.0:%d", agentPort), Handler: mux}
	if err := srv.ListenAndServe(); err != nil {
		fmt.Println("[ai-rescue] server error:", err)
		os.Exit(1)
	}
}

func tail(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

func localIPv4() []string {
	var ips []string
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && !ipn.IP.IsLoopback() {
				ips = append(ips, ipn.IP.String())
			}
		}
	}
	return ips
}

func printBanner() {
	ips := localIPv4()
	url := fmt.Sprintf("http://ai-rescue.local:%d/?token=%s", agentPort, agentToken)
	var ipLine string
	if len(ips) > 0 {
		ipLine = strings.Join(ips, ", ")
		url = fmt.Sprintf("http://%s:%d/?token=%s", ips[0], agentPort, agentToken)
	} else {
		ipLine = "(no IPv4 yet - check wpeinit / DHCP)"
	}
	fmt.Println()
	fmt.Println("================================================================")
	fmt.Println("   AI-Rescue (Windows PE) - maintenance agent ready")
	fmt.Println("================================================================")
	fmt.Printf("  Interfaces  : %s\n", ipLine)
	fmt.Printf("  Agent API   : http://<this-machine>:%d  (/health /info /diagnose /exec)\n", agentPort)
	fmt.Println("  mDNS        : ai-rescue.local may not resolve from slim WinPE; prefer the IP URL below")
	fmt.Printf("  TOKEN       : %s\n", agentToken)
	fmt.Println("  SSH         : not available in slim WinPE (no sshd) - HTTP API is the channel")
	fmt.Printf("  Tunnel      : %s\n", map[bool]string{true: "TUNNEL_HOST configured in agent.conf (use an external ssh client if present)", false: "off (LAN only)"}[agentCfg["TUNNEL_HOST"] != ""])
	fmt.Println("----------------------------------------------------------------")
	fmt.Println("  Scan to connect (or copy the URL):")
	code, err := qr.Encode(url, qr.M)
	if err == nil {
		// render modules as ASCII blocks via code.Black(x,y) (quiet zone added)
		size := code.Size
		border := 2
		var sb strings.Builder
		for y := -border; y < size+border; y++ {
			for x := -border; x < size+border; x++ {
				if x >= 0 && y >= 0 && y < size && x < size && code.Black(x, y) {
					sb.WriteString("██")
				} else {
					sb.WriteString("  ")
				}
			}
			sb.WriteString("\n")
		}
		fmt.Print(sb.String())
	} else {
		fmt.Println("  (QR generation failed:", err, ")")
	}
	fmt.Println(" ", url)
	fmt.Println("================================================================")
	fmt.Println("RESCUE-TOKEN:", agentToken)
}

// ---------- main ----------

func main() {
	if len(os.Args) < 2 {
		fmt.Println("ai-rescue.exe - AI rescue toolkit for Windows PE (no PowerShell/.NET needed)")
		fmt.Println("  ai-rescue.exe diagnose [--llm]   offline diagnosis, report to console + ai-report.txt")
		fmt.Println("  ai-rescue.exe agent              start the maintenance-agent API on :8734")
		fmt.Println("  ai-rescue.exe ask \"question\"     ask the configured LLM")
		return
	}
	cfg := loadConfig()
	switch os.Args[1] {
	case "diagnose":
		report, _ := collectDiagnose()
		fmt.Println(report)
		out := filepath.Join(os.TempDir(), "ai-report.txt")
		if err := os.WriteFile(out, []byte(report), 0644); err == nil {
			fmt.Println("[ai-rescue] report written to", out)
		}
		for _, a := range os.Args[2:] {
			if a == "--llm" {
				fmt.Println("\n[LLM analysis]")
				fmt.Println(llmAsk(cfg, "Diagnose this Windows rescue report and give prioritised fix steps:\n"+report))
			}
		}
	case "agent":
		runAgent()
	case "ask":
		q := strings.Join(os.Args[2:], " ")
		if q == "" {
			q = "How do I check disk health in WinPE?"
		}
		fmt.Println(llmAsk(cfg, q))
	default:
		fmt.Println("unknown subcommand:", os.Args[1])
		os.Exit(2)
	}
}
