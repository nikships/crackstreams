//go:build !windows

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/nikships/crackstreams/windows/internal/server"
	"github.com/nikships/crackstreams/windows/web"
)

func main() {
	noOpen := flag.Bool("no-open", false, "do not automatically open browser")
	flag.Parse()

	srv, err := server.New(server.Config{
		Assets: web.Assets,
	})
	if err != nil {
		log.Fatalf("Crackstreams failed to start: %v", err)
	}
	srv.Start()

	url := srv.LaunchURL()
	fmt.Printf("Crackstreams running at %s\n", url)

	if !*noOpen && runtime.GOOS == "darwin" {
		_ = exec.Command("open", url).Start()
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Close(ctx)
}
