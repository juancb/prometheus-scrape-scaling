// metricgen is a synthetic Prometheus exporter built for ingest benchmarking.
//
// It precomputes the ENTIRE /metrics exposition payload exactly once at startup
// and then serves the identical byte slice on every scrape with a single
// zero-copy-ish w.Write. The point is to make the generator's per-scrape CPU
// cost negligible so that any CPU Prometheus burns is attributable to ingest
// (parse + series lookup + head append + WAL), not to the load generator.
//
// Series uniqueness comes from a single varying integer label `id`. One metric
// name, N unique series:
//
//	synthetic_metric{id="0"} 1
//	synthetic_metric{id="1"} 1
//	...
//
// Values are constant. This understates chunk-compression cost slightly but
// fully exercises the dominant ingest path, which is what we measure.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync/atomic"
	"time"
)

func main() {
	var (
		series  = flag.Int("series", 100000, "number of unique time series to expose")
		listen  = flag.String("listen", ":9100", "listen address")
		name    = flag.String("name", "synthetic_metric", "metric name to emit")
		value   = flag.String("value", "1", "constant value emitted for every series")
		extra   = flag.Int("extra-labels", 0, "number of additional constant labels per series (adds parse cost)")
	)
	flag.Parse()

	if *series < 0 {
		log.Fatalf("series must be >= 0, got %d", *series)
	}

	log.Printf("metricgen: building payload for %d series (metric=%q, extra-labels=%d)...", *series, *name, *extra)
	start := time.Now()
	payload := build(*name, *value, *series, *extra)
	dur := time.Since(start)
	log.Printf("metricgen: payload ready: %d series, %d bytes (%.2f GiB) in %s",
		*series, len(payload), float64(len(payload))/(1<<30), dur.Round(time.Millisecond))

	// Drop the build-time scratch; keep only the final payload.
	runtime.GC()

	var scrapes int64

	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&scrapes, 1)
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		w.Write(payload)
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "ok series=%d bytes=%d scrapes=%d\n", *series, len(payload), atomic.LoadInt64(&scrapes))
	})

	log.Printf("metricgen: listening on %s (GOMAXPROCS=%d)", *listen, runtime.GOMAXPROCS(0))
	srv := &http.Server{
		Addr:         *listen,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // large payloads may take a while to flush; do not cut them off
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("metricgen: server error: %v", err)
		os.Exit(1)
	}
}

// build constructs the full exposition payload as a single []byte.
// It preallocates based on a per-line size estimate to avoid repeated growth.
func build(name, value string, series, extra int) []byte {
	header := "# HELP " + name + " Synthetic gauge for ingest benchmarking.\n" +
		"# TYPE " + name + " gauge\n"

	// Estimate bytes per line: name + {id="<digits>"} + extra labels + " value\n".
	digits := len(strconv.Itoa(series)) + 1
	perExtra := len(`,lblXX="cval"`)
	estLine := len(name) + len(`{id=""}`) + digits + extra*perExtra + 1 + len(value) + 1
	buf := make([]byte, 0, len(header)+series*estLine)

	buf = append(buf, header...)
	for i := 0; i < series; i++ {
		buf = append(buf, name...)
		buf = append(buf, `{id="`...)
		buf = strconv.AppendInt(buf, int64(i), 10)
		buf = append(buf, '"')
		for j := 0; j < extra; j++ {
			buf = append(buf, ',', 'l', 'b', 'l')
			buf = strconv.AppendInt(buf, int64(j), 10)
			buf = append(buf, '=', '"', 'c', 'v', 'a', 'l', '"')
		}
		buf = append(buf, '}', ' ')
		buf = append(buf, value...)
		buf = append(buf, '\n')
	}
	return buf
}
