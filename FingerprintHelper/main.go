// olaz-fingerprint-helper performs Olaz's network requests with the official Zalo PC client's
// TLS / HTTP-2 fingerprint (Chromium 108, Electron 22.3.9), so that VNG's servers cannot
// distinguish Olaz's connections from the official client's by their shape.
//
// Olaz spawns this helper and speaks a line-based protocol over a unix domain socket (see
// protocol.go). Everything the renderer and the media loader request goes through here; if the
// helper is unavailable, Olaz falls back to URLSession.
//
// Upstream requests are made with tls-client's Chrome_108 profile (utls ClientHello + a
// patched http2 stack with Chrome's SETTINGS/priority behaviour, connection pooling per origin).
// WebSockets dial through utls with the same ClientHello spec.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
)

const (
	helperVersion = 1
	profileName   = "chrome_108"
)

func main() {
	socketPath := flag.String("socket", "", "unix socket path to listen on")
	flag.Parse()
	if *socketPath == "" {
		fmt.Fprintln(os.Stderr, "usage: olaz-fingerprint-helper -socket <path>")
		os.Exit(2)
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	_ = os.Remove(*socketPath)
	listener, err := net.Listen("unix", *socketPath)
	if err != nil {
		log.Fatalf("listen %s: %v", *socketPath, err)
	}
	// Only Olaz's own user may talk to it.
	_ = os.Chmod(*socketPath, 0o700)

	// Die with the parent (Olaz terminates us explicitly, this is the backstop) and on signals.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigs
		listener.Close()
		os.Remove(*socketPath)
		os.Exit(0)
	}()

	log.Printf("fingerprint-helper v%d (%s) listening on %s", helperVersion, profileName, *socketPath)
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			return
		}
		go handleConn(conn)
	}
}
