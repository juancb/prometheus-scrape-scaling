// metricgen is a synthetic Prometheus exporter built for ingest benchmarking.
//
// It precomputes the ENTIRE /metrics exposition payload and serves the identical
// byte slice on every scrape with a single write. The point is to make the
// exporter's per-scrape CPU cost negligible so that any CPU Prometheus burns is
// attributable to ingest (parse + series lookup + head append + WAL), not to the
// load generator.
//
// Series uniqueness within one exporter comes from a single varying integer label
// `id`. Across exporters, Prometheus stamps a distinct `instance` label (host:port)
// so series stay globally unique; total head series = (#targets) x (series each).
//
//	synthetic_metric{id="0"} 1
//	synthetic_metric{id="1"} 1
//	...
//
// The payload can be rebuilt at runtime via GET /resize?series=N (atomic swap),
// which lets a benchmark grow a target's cardinality without restarting it.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

var (
	mName  string
	mValue string
	mExtra int

	payload     atomic.Pointer[[]byte] // current exposition bytes, swapped atomically
	seriesCount atomic.Int64
	buildMu     sync.Mutex // serialize rebuilds
	scrapes     atomic.Int64
)

func main() {
	var (
		series = flag.Int("series", 100000, "initial number of unique time series to expose")
		listen = flag.String("listen", ":9100", "listen address")
		name   = flag.String("name", "synthetic_metric", "metric name to emit")
		value  = flag.String("value", "1", "constant value emitted for every series")
		extra  = flag.Int("extra-labels", 0, "number of additional constant labels per series")
	)
	flag.Parse()
	mName, mValue, mExtra = *name, *value, *extra

	rebuild(*series)
	log.Printf("metricgen: initial payload ready: %d series, %d bytes", *series, len(*payload.Load()))

	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		scrapes.Add(1)
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		if p := payload.Load(); p != nil {
			w.Write(*p)
		}
	})
	// GET /resize?series=N — rebuild the payload to N series and swap it in.
	http.HandleFunc("/resize", func(w http.ResponseWriter, r *http.Request) {
		n, err := strconv.Atoi(r.URL.Query().Get("series"))
		if err != nil || n < 0 {
			http.Error(w, "bad series", http.StatusBadRequest)
			return
		}
		start := time.Now()
		rebuild(n)
		fmt.Fprintf(w, "ok series=%d bytes=%d built_in=%s\n", n, len(*payload.Load()), time.Since(start).Round(time.Millisecond))
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "ok series=%d bytes=%d scrapes=%d\n", seriesCount.Load(), len(*payload.Load()), scrapes.Load())
	})

	log.Printf("metricgen: listening on %s (GOMAXPROCS=%d)", *listen, runtime.GOMAXPROCS(0))
	srv := &http.Server{Addr: *listen, ReadTimeout: 10 * time.Second, WriteTimeout: 0}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("metricgen: server error: %v", err)
	}
}

// rebuild constructs a fresh payload for n series and atomically swaps it in.
func rebuild(n int) {
	buildMu.Lock()
	defer buildMu.Unlock()
	buf := build(mName, mValue, n, mExtra)
	payload.Store(&buf)
	seriesCount.Store(int64(n))
	runtime.GC() // release the previous payload's backing array promptly
}

// build assembles the full exposition payload as a single []byte, preallocating
// from a per-line size estimate to avoid repeated growth.
func build(name, value string, series, extra int) []byte {
	header := "# HELP " + name + " Synthetic gauge for ingest benchmarking.\n" +
		"# TYPE " + name + " gauge\n"
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
