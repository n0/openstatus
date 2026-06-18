package checker

import (
	"fmt"
	"net"
	neturl "net/url"
	"strings"
	"time"
)

type TCPData struct {
	WorkspaceID string `json:"workspaceId"`
	MonitorID   string `json:"monitorId"`
	Timestamp   int64  `json:"timestamp"`
}

type TCPResponseTiming struct {
	TCPStart int64 `json:"tcpStart"`
	TCPDone  int64 `json:"tcpDone"`
}

type TCPResponse struct {
	Region       string            `json:"region"`
	ErrorMessage string            `json:"errorMessage"`
	JobType      string            `json:"jobType"`
	RequestId    int64             `json:"requestId,omitempty"`
	WorkspaceID  int64             `json:"workspaceId"`
	MonitorID    int64             `json:"monitorId"`
	Timestamp    int64             `json:"timestamp"`
	Latency      int64             `json:"latency"`
	Timing       TCPResponseTiming `json:"timing"`
	Error        uint8             `json:"error,omitempty"`
}

func PingTCP(timeout int, rawURL string) (TCPResponseTiming, error) {
	address, err := tcpAddress(rawURL)
	if err != nil {
		return TCPResponseTiming{}, err
	}

	start := time.Now().UTC().UnixMilli()
	conn, err := net.DialTimeout("tcp", address, time.Duration(timeout)*time.Second)
	stop := time.Now().UTC().UnixMilli()

	if err != nil {
		if e := err.(*net.OpError).Timeout(); e {
			return TCPResponseTiming{}, fmt.Errorf("timeout after %d ms", timeout*1000)
		}
		if strings.Contains(err.Error(), "connection refused") {
			return TCPResponseTiming{}, fmt.Errorf("connection refused")
		}
		return TCPResponseTiming{}, fmt.Errorf("dial error: %w", err)
	}
	defer conn.Close()

	return TCPResponseTiming{TCPStart: start, TCPDone: stop}, nil
}

func tcpAddress(rawURL string) (string, error) {
	if strings.HasPrefix(rawURL, "tcp://") {
		parsed, err := neturl.Parse(rawURL)
		if err != nil {
			return "", fmt.Errorf("invalid tcp url: %w", err)
		}
		if parsed.Host == "" {
			return "", fmt.Errorf("invalid tcp url: missing host")
		}
		return parsed.Host, nil
	}
	return rawURL, nil
}
