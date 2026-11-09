// Smoke client for the fingerprint helper: HELLO, one REQ, prints the response.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
)

func main() {
	socket := os.Args[1]
	url := os.Args[2]
	conn, err := net.Dial("unix", socket)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	read := bufio.NewReader(conn)

	fmt.Fprint(conn, "HELLO\n")
	hello, _ := read.ReadString('\n')
	fmt.Println("hello:", strings.TrimSpace(hello))

	spec := map[string]any{
		"method": "GET", "url": url,
		"headers":   [][2]string{{"User-Agent", "ZaloPC-darwin-23v694"}, {"Accept", "application/json, text/plain, */*"}},
		"timeoutMs": 20000, "stream": false, "follow": true, "idleMs": 15000,
	}
	encoded, _ := json.Marshal(spec)
	fmt.Fprintf(conn, "REQ 1 %s\n", encoded)

	for {
		line, err := read.ReadString('\n')
		if err != nil {
			log.Fatal("read:", err)
		}
		line = strings.TrimRight(line, "\n")
		parts := strings.SplitN(line, " ", 3)
		switch parts[0] {
		case "RES", "ERR":
			var body []byte
			if len(parts) == 3 {
				var parsed struct {
					Status  int    `json:"status"`
					URL     string `json:"url"`
					BodyB64 string `json:"bodyB64"`
					Error   string `json:"error"`
				}
				json.Unmarshal([]byte(parts[2]), &parsed)
				fmt.Println("status:", parsed.Status, "url:", parsed.URL, "error:", parsed.Error)
				if parsed.BodyB64 != "" {
					decoded, _ := base64.StdEncoding.DecodeString(parsed.BodyB64)
					body = decoded
					if len(body) > 3000 {
						body = body[:3000]
					}
					fmt.Printf("body: %s\n", body)
				}
			}
			return
		case "CHUNK":
			length, _ := strconv.Atoi(parts[2])
			io.CopyN(io.Discard, read, int64(length))
		case "RESHEAD", "END":
			fmt.Println(line)
		default:
			fmt.Println(line)
		}
	}
}
