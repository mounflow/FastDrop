package transfer

import (
	"context"
	"errors"
	"sync"
	"time"
)

// Scheduler enforces the spec's concurrency budget (§14):
//   - 3 chunks per file (MaxConcurrentChunks)
//   - 2 files at once (MaxConcurrentFiles)
//   - 6 total HTTP requests (MaxGlobalHTTP)
//
// It exposes a simple Acquire/Release semaphore API that the API layer
// uses when serving chunk PUTs.
type Scheduler struct {
	mu                  sync.Mutex
	cond                *sync.Cond
	fileChunks          map[string]int // fileID -> in-flight chunk count
	files               int            // in-flight file count
	global              int            // in-flight HTTP requests
	maxChunksPerFile    int
	maxFiles            int
	maxGlobal           int
}

func NewScheduler(maxChunksPerFile, maxFiles, maxGlobal int) *Scheduler {
	if maxChunksPerFile <= 0 {
		maxChunksPerFile = 3
	}
	if maxFiles <= 0 {
		maxFiles = 2
	}
	if maxGlobal <= 0 {
		maxGlobal = 6
	}
	s := &Scheduler{
		fileChunks:       make(map[string]int),
		maxChunksPerFile: maxChunksPerFile,
		maxFiles:         maxFiles,
		maxGlobal:        maxGlobal,
	}
	s.cond = sync.NewCond(&s.mu)
	return s
}

// Acquire blocks until a chunk slot is available for fileID, then reserves
// it. Cancel via ctx.
func (s *Scheduler) Acquire(ctx context.Context, fileID string) error {
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			s.mu.Lock()
			s.cond.Broadcast()
			s.mu.Unlock()
		case <-done:
		}
	}()
	defer close(done)

	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		// Reserve if all three budgets permit.
		hasFile := s.fileChunks[fileID] > 0
		chunkOK := s.fileChunks[fileID] < s.maxChunksPerFile
		fileOK := hasFile || len(s.fileChunks) < s.maxFiles
		globalOK := s.global < s.maxGlobal
		if chunkOK && fileOK && globalOK {
			s.fileChunks[fileID]++
			if s.fileChunks[fileID] == 1 {
				s.files++
			}
			s.global++
			return nil
		}
		s.cond.Wait()
	}
}

// Release returns a chunk slot to the pool.
func (s *Scheduler) Release(fileID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fileChunks[fileID] == 0 {
		return
	}
	s.fileChunks[fileID]--
	s.global--
	if s.fileChunks[fileID] == 0 {
		delete(s.fileChunks, fileID)
		s.files--
	}
	s.cond.Broadcast()
}

// InFlight returns current load snapshot for observability.
func (s *Scheduler) InFlight() (files, chunks, global int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.files, s.aggregateChunks(), s.global
}

func (s *Scheduler) aggregateChunks() int {
	n := 0
	for _, v := range s.fileChunks {
		n += v
	}
	return n
}

// RetryStrategy computes exponential backoff per §15:
// 500ms, 1s, 2s, 4s, 8s for attempts 1..5.
type RetryStrategy struct {
	MaxAttempts int
	Backoffs    []time.Duration
}

func DefaultRetryStrategy() RetryStrategy {
	return RetryStrategy{
		MaxAttempts: 5,
		Backoffs:    []time.Duration{500 * time.Millisecond, 1 * time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second},
	}
}

// BackoffFor returns the wait for the (1-based) attempt, or ErrNoMoreRetries.
func (r RetryStrategy) BackoffFor(attempt int) (time.Duration, error) {
	if attempt < 1 || attempt > r.MaxAttempts {
		return 0, ErrNoMoreRetries
	}
	return r.Backoffs[attempt-1], nil
}

var ErrNoMoreRetries = errors.New("no more retries available")

// SpeedWindow is a 3-second sliding-window speed estimator (§13).
// Call Add(bytes) on each chunk completion; Speed() returns bytes/sec.
type SpeedWindow struct {
	mu      sync.Mutex
	samples []sample
	window  time.Duration
}

type sample struct {
	at    time.Time
	bytes int64
}

func NewSpeedWindow() *SpeedWindow {
	return &SpeedWindow{window: 3 * time.Second}
}

// Add records bytes transferred at the given instant.
func (s *SpeedWindow) Add(now time.Time, n int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.samples = append(s.samples, sample{at: now, bytes: n})
	s.evict(now)
}

// Speed returns bytes per second over the last 3 seconds, or 0 if no data.
// Spec §13: speed = (bytes added in window) / window_seconds.
func (s *SpeedWindow) Speed(now time.Time) float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.evict(now)
	var total int64
	for _, sm := range s.samples {
		total += sm.bytes
	}
	if total == 0 {
		return 0
	}
	return float64(total) / s.window.Seconds()
}

func (s *SpeedWindow) evict(now time.Time) {
	cutoff := now.Add(-s.window)
	idx := 0
	for ; idx < len(s.samples); idx++ {
		if s.samples[idx].at.After(cutoff) {
			break
		}
	}
	if idx > 0 {
		s.samples = append([]sample(nil), s.samples[idx:]...)
	}
}

// Throttle is a token-bucket / minimum-interval throttle for progress
// push cadence (§13: WS push at most every 200-500ms).
type Throttle struct {
	minInterval time.Duration
	last        time.Time
	mu          sync.Mutex
}

func NewThrottle(minInterval time.Duration) *Throttle {
	return &Throttle{minInterval: minInterval}
}

// Allow returns true at most once per minInterval.
func (t *Throttle) Allow(now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if now.Sub(t.last) >= t.minInterval {
		t.last = now
		return true
	}
	return false
}
