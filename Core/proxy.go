package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/elazarl/goproxy"
)

// 本文件实现设备内的拦截代理。
//
// 设计约束（与「不占用系统 VPN」的产品定位一致）：
//   - 不使用 Network Extension，免费开发者账号也能跑；
//   - 只监听 127.0.0.1，覆盖范围由用户手动配置的 Wi-Fi HTTP 代理决定；
//   - 只对白名单域名做 TLS 中间人，其余流量一律透传，不做抓包；
//   - 除 WLOC 响应外不读取、不落盘任何请求内容。

const proxyListenPort = 8888

// caCommonName / caOrganization 是根证书的主题信息。
// 用户在「设置 → 通用 → 关于本机 → 证书信任设置」里看到的就是这两个字段，
// 换名字的时候只改这里即可，其他文件通过常量引用。
const (
	caCommonName   = "Floc Root CA"
	caOrganization = "Floc"
	leafCommonName = "Floc Local Trust Probe"
)

// spoofState 保存当前生效的改写配置，由 Swift 侧通过 C 接口更新。
type spoofState struct {
	mu            sync.Mutex
	latitude      float64
	longitude     float64
	enabled       bool
	accuracy      int
	motionEnabled bool
	verifyToken   string
	caCertificate *tls.Certificate
}

var state = &spoofState{}

// ---------------------------------------------------------------------------
// 运行日志
// ---------------------------------------------------------------------------

const maxLogEntries = 200

var (
	logMu      sync.Mutex
	logEntries []string
)

// logEvent 记录一条带时间戳的运行日志，环形保留最近 200 条。
func logEvent(message string) {
	line := time.Now().Format("15:04:05.000") + "  " + message
	logMu.Lock()
	logEntries = append(logEntries, line)
	if len(logEntries) > maxLogEntries {
		logEntries = logEntries[len(logEntries)-maxLogEntries:]
	}
	logMu.Unlock()
}

// drainLogs 取出并清空积压日志，供 Swift 侧轮询拉取。
func drainLogs() string {
	logMu.Lock()
	defer logMu.Unlock()
	if len(logEntries) == 0 {
		return ""
	}
	out := strings.Join(logEntries, "\n")
	logEntries = nil
	return out
}

// ---------------------------------------------------------------------------
// 状态访问
// ---------------------------------------------------------------------------

func setSpoofConfig(lat, lon float64, enabled bool, accuracy int, motionEnabled bool) {
	state.mu.Lock()
	state.latitude = lat
	state.longitude = lon
	state.enabled = enabled
	state.accuracy = accuracy
	state.motionEnabled = motionEnabled
	state.mu.Unlock()
	logEvent(fmt.Sprintf("改写配置更新 enabled=%t accuracy=%d motion=%t", enabled, accuracy, motionEnabled))
}

func currentSpoofConfig() (lat, lon float64, enabled bool, accuracy int, motionEnabled bool) {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.latitude, state.longitude, state.enabled, state.accuracy, state.motionEnabled
}

func setVerifyToken(token string) {
	state.mu.Lock()
	state.verifyToken = token
	state.mu.Unlock()
}

func matchesVerifyToken(token string) bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.verifyToken != "" && state.verifyToken == token
}

func setCACertificate(cert *tls.Certificate) {
	state.mu.Lock()
	state.caCertificate = cert
	state.mu.Unlock()
}

func currentCACertificate() *tls.Certificate {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.caCertificate
}

// ---------------------------------------------------------------------------
// 域名白名单
// ---------------------------------------------------------------------------

// mitmHosts 是允许做 TLS 中间人的主机集合。
//
// 前四个是 Apple / 高德的位置服务端点；最后一个由用户手动配置的
// Wi-Fi 代理在探测网络连通性时访问，用于验证代理链路是否真的生效。
var mitmHosts = map[string]bool{
	"gs-loc.apple.com":    true,
	"gs-loc-cn.apple.com": true,
	"gsp-ssl.ls.apple.com": true,
	"bluedot.is.autonavi.com": true,
	"bluedot.is.autonavi.com.gds.alibabadns.com": true,
}

// isLocationHost 判断主机名是否属于需要改写的定位服务。
func isLocationHost(host string) bool {
	host = normalizeHost(host)
	switch host {
	case "gs-loc.apple.com", "gs-loc-cn.apple.com",
		"gsp-ssl.ls.apple.com", "bluedot.is.autonavi.com",
		"bluedot.is.autonavi.com.gds.alibabadns.com":
		return true
	}
	return false
}

// normalizeHost 去掉端口、统一小写、去掉尾部点号。
func normalizeHost(host string) string {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if strings.Contains(host, ":") {
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
	}
	return host
}

// isProxyProbeHost 判断是否是「代理连通性验证」用的主机。
func isProxyProbeHost(host string) bool {
	host = normalizeHost(host)
	return host == "baidu.com" || host == "www.baidu.com" || strings.HasSuffix(host, ".baidu.com")
}

// ---------------------------------------------------------------------------
// 代理构建
// ---------------------------------------------------------------------------

// newProxyServer 组装 goproxy 实例。
func newProxyServer(caCert *tls.Certificate) *goproxy.ProxyHttpServer {
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = false

	proxy.NonproxyHandler = http.HandlerFunc(handleDirectVisit)

	if caCert != nil {
		mitmAction := &goproxy.ConnectAction{
			Action:    goproxy.ConnectMitm,
			TLSConfig: goproxy.TLSConfigFromCA(caCert),
		}
		proxy.OnRequest().HandleConnectFunc(func(host string, ctx *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
			if isLocationHost(host) {
				logEvent("CONNECT " + host + " → 中间人")
				return mitmAction, host
			}
			if isProxyProbeHost(host) {
				logEvent("CONNECT " + host + " → 中间人（代理验证）")
				return mitmAction, host
			}
			// 全局代理模式下会有大量无关 HTTPS 流量经过这里。
			// 逐条记录既产生噪声又可能泄露浏览目标，因此只记录定位与验证流量。
			return goproxy.OkConnect, host
		})
	}

	proxy.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		return serveInterceptedRequest(req, ctx)
	})
	proxy.OnResponse().DoFunc(rewriteLocationResponse)
	return proxy
}

// handleDirectVisit 处理「用 Safari 直接访问 127.0.0.1:8888」这类非代理请求。
func handleDirectVisit(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/cert":
		serveCACertificateDownload(w)

	case "/":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><head><meta charset="utf-8">` +
			`<meta http-equiv="refresh" content="0;url=/cert"><title>CA Certificate</title></head>` +
			`<body><p><a href="/cert">下载 CA 证书</a></p></body></html>`))

	case "/coords":
		lat, lon, enabled, accuracy, motionEnabled := currentSpoofConfig()
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		fmt.Fprintf(w, `{"enabled":%t,"lat":%.6f,"lon":%.6f,"accuracy":%d,"motionSimulationEnabled":%t}`,
			enabled, lat, lon, accuracy, motionEnabled)

	case "/proxy.mobileconfig", "/proxy.mobileconfig/":
		w.Header().Set("Content-Type", "application/x-apple-aspen-config")
		w.Header().Set("Content-Disposition", "attachment; filename=Floc-Proxy.mobileconfig")
		_, _ = w.Write([]byte(buildProxyMobileConfig()))

	default:
		// 兼容 rendoor.cert 这类自定义主机名，用于一步弹出证书安装。
		if normalizeHost(r.Host) == "rendoor.cert" {
			if r.URL.Path == "/cert" {
				serveCACertificateDownload(w)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<!DOCTYPE html><html><head><meta charset="utf-8">` +
				`<meta http-equiv="refresh" content="2;url=/cert"><title>Preparing Certificate</title></head>` +
				`<body><p>正在准备 CA 证书，如未自动跳转请点击 <a href="/cert">这里</a>。</p></body></html>`))
			return
		}
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("这是一个定位拦截代理。请用 Safari 访问 " +
			"http://127.0.0.1:8888/proxy.mobileconfig 配置代理，或访问 http://127.0.0.1:8888/cert 安装证书。"))
	}
}

// serveCACertificateDownload 输出根证书，供 iOS 安装描述文件使用。
func serveCACertificateDownload(w http.ResponseWriter) {
	caCert := currentCACertificate()
	if caCert == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("CA 证书尚未生成"))
		return
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCert.Certificate[0]})
	w.Header().Set("Content-Type", "application/x-x509-ca-cert")
	w.Header().Set("Content-Disposition", "attachment; filename=Floc-CA.crt")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(certPEM)
}

// serveInterceptedRequest 在请求阶段处理本地伪造的响应。
func serveInterceptedRequest(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	host := normalizeHost(req.Host)

	// 代理链路验证：把 https://www.baidu.com/paopao-verify-<token> 拦下来，
	// 回显 token。App 侧用它确认 Wi-Fi 代理是否真的走到了本机。
	if isProxyProbeHost(host) && strings.HasPrefix(req.URL.Path, "/location-verify-") {
		token := strings.TrimPrefix(req.URL.Path, "/location-verify-")
		logEvent("收到代理验证请求")
		if matchesVerifyToken(token) {
			resp := goproxy.NewResponse(req, "text/plain", http.StatusOK, token)
			resp.Header.Set("Cache-Control", "no-store")
			return req, resp
		}
	}

	if host != "rendoor.cert" && host != "www.rendoor.cert" {
		return req, nil
	}

	caCert := currentCACertificate()
	if caCert == nil {
		return req, nil
	}

	if req.URL.Path == "/cert" {
		certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCert.Certificate[0]})
		resp := goproxy.NewResponse(req, "application/x-x509-ca-cert", http.StatusOK, string(certPEM))
		resp.Header.Set("Content-Disposition", `attachment; filename=Floc-CA.crt`)
		resp.Header.Set("Cache-Control", "no-store")
		return req, resp
	}

	html := `<!DOCTYPE html><html><head><meta charset="utf-8">` +
		`<meta http-equiv="refresh" content="2;url=/cert"><title>Preparing Certificate</title></head>` +
		`<body><p>正在准备 CA 证书，如未自动跳转请点击 <a href="/cert">这里</a>。</p></body></html>`
	return req, goproxy.NewResponse(req, "text/html; charset=utf-8", http.StatusOK, html)
}

// rewriteLocationResponse 在响应阶段改写 WLOC 坐标。
func rewriteLocationResponse(resp *http.Response, ctx *goproxy.ProxyCtx) *http.Response {
	if resp == nil || resp.Request == nil {
		return resp
	}
	if !isLocationHost(resp.Request.Host) ||
		resp.Request.URL.Path != "/clls/wloc" ||
		resp.Request.Method != http.MethodPost {
		return resp
	}

	lat, lon, enabled, accuracy, motionEnabled := currentSpoofConfig()

	if resp.ContentLength > maxPatchBodyBytes {
		logEvent(fmt.Sprintf("WLOC 响应过大，跳过改写（%d 字节）", resp.ContentLength))
		return resp
	}

	originalBody := resp.Body
	body, err := io.ReadAll(io.LimitReader(originalBody, maxPatchBodyBytes+1))
	if err != nil {
		logEvent("读取 WLOC 响应失败: " + err.Error())
		resp.Body = io.NopCloser(io.MultiReader(bytes.NewReader(body), originalBody))
		return resp
	}
	if int64(len(body)) > maxPatchBodyBytes {
		logEvent("WLOC 响应过大，跳过改写")
		resp.Body = io.NopCloser(io.MultiReader(bytes.NewReader(body), originalBody))
		return resp
	}
	_ = originalBody.Close()

	// 未开启虚拟定位、或响应非 200／为空时原样放行。
	if !enabled || resp.StatusCode != http.StatusOK || len(body) == 0 {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		return resp
	}

	patched, stats, err := rewriteResponseBody(body, wlocTarget{
		Latitude:      lat,
		Longitude:     lon,
		Accuracy:      accuracy,
		MotionEnabled: motionEnabled,
	})
	if err != nil || bytes.Equal(patched, body) {
		if err != nil {
			logEvent("WLOC 改写跳过: " + err.Error())
		}
		resp.Body = io.NopCloser(bytes.NewReader(body))
		return resp
	}

	resp.Body = io.NopCloser(bytes.NewReader(patched))
	resp.ContentLength = int64(len(patched))
	// 改写后长度变了，必须清掉与长度相关和编码相关的头，只保留 Content-Length。
	resp.Header.Del("Content-Encoding")
	resp.Header.Del("Transfer-Encoding")
	resp.Header.Set("Content-Length", strconv.Itoa(len(patched)))
	logEvent(fmt.Sprintf("WLOC 已改写 位置=%d WiFi=%d 基站=%d 跳过=%d 输入=%d 输出=%d",
		stats.Locations, stats.WiFiDevices, stats.CellSections, stats.Skipped, len(body), len(patched)))
	return resp
}

// ---------------------------------------------------------------------------
// 描述文件与代理生命周期
// ---------------------------------------------------------------------------

// buildProxyMobileConfig 生成一份全局 HTTP 代理描述文件。
//
// 注意：iOS 要求配置描述文件经过 MDM 签名才能安装，自签场景下这个文件主要
// 用作模板，实际仍引导用户在 Wi-Fi 设置里手动填写代理。
func buildProxyMobileConfig() string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadDescription</key>
			<string>为 Floc 配置本机 HTTP 代理。</string>
			<key>PayloadDisplayName</key>
			<string>Floc Local Proxy</string>
			<key>PayloadIdentifier</key>
			<string>` + bundlePrefix + `.proxy.payload</string>
			<key>PayloadType</key>
			<string>com.apple.proxy.http.global</string>
			<key>PayloadUUID</key>
			<string>` + randomUUID() + `</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>GlobalHTTPProxy</key>
			<dict>
				<key>ProxyServer</key>
				<string>127.0.0.1</string>
				<key>ProxyServerPort</key>
				<integer>` + strconv.Itoa(proxyListenPort) + `</integer>
				<key>ProxyType</key>
				<string>Manual</string>
			</dict>
		</dict>
	</array>
	<key>PayloadDisplayName</key>
	<string>Floc Local Proxy</string>
	<key>PayloadIdentifier</key>
	<string>` + bundlePrefix + `.proxy</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>` + randomUUID() + `</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>`
}

// randomUUID 生成一个 v4 UUID 字符串。
func randomUUID() string {
	u := randomHex32()
	if len(u) < 32 {
		return u
	}
	return fmt.Sprintf("%s-%s-%s-%s-%s", u[0:8], u[8:12], u[12:16], u[16:20], u[20:32])
}

// startProxy 启动代理服务，返回可传给 stopProxy 的句柄。
func startProxy(certPEM, keyPEM []byte, lat, lon float64, enabled bool, accuracy int, motionEnabled bool) (*http.Server, error) {
	caCert, err := parseCA(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}

	setCACertificate(caCert)
	setSpoofConfig(lat, lon, enabled, accuracy, motionEnabled)

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", proxyListenPort))
	if err != nil {
		return nil, err
	}

	server := &http.Server{Handler: newProxyServer(caCert)}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logEvent("代理服务异常: " + err.Error())
		}
	}()
	logEvent(fmt.Sprintf("代理已启动 127.0.0.1:%d", proxyListenPort))
	return server, nil
}

// stopProxy 优雅关闭代理。
func stopProxy(server *http.Server) error {
	if server == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := server.Shutdown(ctx)
	setCACertificate(nil)
	return err
}
